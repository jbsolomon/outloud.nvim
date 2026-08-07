use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use crate::protocol::Event;
use crate::transcribe::SpeechTranscriber;
use streamsafe::{Result, StreamSafeError, Transform};

use super::filter::UtteranceData;

/// Transcribes utterance audio into text via the STT backend.
///
/// Final utterances become `Event::Transcript`; interim snapshots become
/// `Event::Partial` with sliding window metadata.
///
/// Uses a latest-wins policy: if a partial transcription completes but a newer
/// partial has already started, the stale result is silently discarded.
///
/// Partials are single-in-flight via a gate shared with the audio capture
/// side: the callback claims the gate when emitting a partial and the
/// `GateGuard` here releases it once that partial has been processed, so a
/// slow backend drops newer partials at the source instead of building up a
/// backlog of stale windows.
///
/// Uses `spawn_blocking` because `SpeechTranscriber::transcribe` is synchronous.
///
/// Sample rate is taken from each `UtteranceData` input (per-utterance),
/// allowing device switching between sessions without restarting the daemon.
pub struct TranscribeTransform {
    transcriber: Arc<dyn SpeechTranscriber>,
    stt_available: bool,
    /// Tracks the highest sequence number currently in-flight. Used to discard
    /// stale partial results that complete after a newer partial has started.
    latest_seq: Arc<AtomicU64>,
    /// Single-in-flight partial gate shared with the audio capture side.
    /// Released by `GateGuard` when a partial finishes processing.
    partial_gate: Arc<AtomicBool>,
}

impl TranscribeTransform {
    pub fn new(
        transcriber: Arc<dyn SpeechTranscriber>,
        stt_available: bool,
        partial_gate: Arc<AtomicBool>,
    ) -> Self {
        Self {
            transcriber,
            stt_available,
            latest_seq: Arc::new(AtomicU64::new(0)),
            partial_gate,
        }
    }
}

/// Releases the shared partial-in-flight gate on drop. The audio callback
/// claims the gate (compare-exchange) when it emits a partial; the guard for
/// that partial is created here and dropped when processing finishes —
/// successfully or not — so a slow or failed transcription can never wedge
/// partial emission for the rest of the session.
struct GateGuard(Arc<AtomicBool>);

impl GateGuard {
    fn new(gate: Arc<AtomicBool>) -> Self {
        Self(gate)
    }
}

impl Drop for GateGuard {
    fn drop(&mut self) {
        self.0.store(false, Ordering::Release);
    }
}

impl Transform for TranscribeTransform {
    type Input = UtteranceData;
    type Output = Event;

    async fn apply(&mut self, input: UtteranceData) -> Result<Event> {
        let transcriber = self.transcriber.clone();
        let sample_rate = input.sample_rate;
        let stt_available = self.stt_available;
        let duration_ms = input.duration_ms;
        let is_final = input.is_final;
        let seq = input.seq;
        let window_start_ms = input.window_start_ms;
        let window_end_ms = input.window_end_ms;
        let latest_seq = self.latest_seq.clone();

        // A partial claimed the shared single-in-flight gate at emission
        // time; release it when this item finishes processing, whatever the
        // outcome. Finals never claimed the gate and must not release it —
        // a partial ahead of them in the pipeline owns it.
        let _gate_guard = (!is_final).then(|| GateGuard::new(self.partial_gate.clone()));

        // Record that this sequence is in-flight
        latest_seq.store(seq, Ordering::Relaxed);

        let event = tokio::task::spawn_blocking(move || {
            if !stt_available {
                return if is_final {
                    Event::Error {
                        message: format!(
                            "STT backend unavailable, discarded {duration_ms}ms of audio \
                             (is llama-server reachable?)"
                        ),
                    }
                } else {
                    // Stale partial — return empty, will be filtered
                    Event::Partial {
                        text: String::new(),
                        window_start_ms,
                        window_end_ms,
                        seq,
                    }
                };
            }

            match transcriber.transcribe(&input.samples, sample_rate) {
                Ok(r) if is_final => Event::Transcript {
                    text: r.text,
                    duration_ms,
                },
                Ok(r) => {
                    // Latest-wins: if a newer partial is already in-flight,
                    // discard this stale result
                    let current_latest = latest_seq.load(Ordering::Relaxed);
                    if seq < current_latest {
                        Event::Partial {
                            text: String::new(),
                            window_start_ms,
                            window_end_ms,
                            seq,
                        }
                    } else {
                        Event::Partial {
                            text: r.text,
                            window_start_ms,
                            window_end_ms,
                            seq,
                        }
                    }
                }
                Err(e) if is_final => Event::Error {
                    message: format!("transcription failed: {e}"),
                },
                // Swallow partial errors quietly — the final pass will report.
                Err(_) => Event::Partial {
                    text: String::new(),
                    window_start_ms,
                    window_end_ms,
                    seq,
                },
            }
        })
        .await
        .map_err(StreamSafeError::other)?;

        Ok(event)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::transcribe::TranscribeResult;

    struct StubTranscriber;

    impl SpeechTranscriber for StubTranscriber {
        fn transcribe(
            &self,
            _samples: &[f32],
            _sample_rate: u32,
        ) -> anyhow::Result<TranscribeResult> {
            Ok(TranscribeResult {
                text: "hello".into(),
                duration_ms: 1,
            })
        }

        fn is_ready(&self) -> bool {
            true
        }

        fn name(&self) -> &str {
            "stub"
        }
    }

    fn partial_input(seq: u64) -> UtteranceData {
        UtteranceData {
            samples: vec![0.1; 160],
            sample_rate: 16000,
            duration_ms: 10,
            is_final: false,
            window_start_ms: 0,
            window_end_ms: 10,
            seq,
        }
    }

    #[tokio::test]
    async fn partial_releases_gate_on_completion() {
        let gate = Arc::new(AtomicBool::new(true));
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), true, gate.clone());

        let event = transform.apply(partial_input(1)).await.unwrap();
        assert!(matches!(event, Event::Partial { text, .. } if text == "hello"));
        assert!(!gate.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn partial_releases_gate_when_stt_unavailable() {
        let gate = Arc::new(AtomicBool::new(true));
        let mut transform =
            TranscribeTransform::new(Arc::new(StubTranscriber), false, gate.clone());

        let _ = transform.apply(partial_input(1)).await.unwrap();
        assert!(!gate.load(Ordering::Relaxed));
    }

    #[tokio::test]
    async fn final_does_not_release_gate() {
        // Finals never claimed the gate; a partial ahead of them in the
        // pipeline owns it and releases it when processed.
        let gate = Arc::new(AtomicBool::new(true));
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), true, gate.clone());

        let mut input = partial_input(0);
        input.is_final = true;
        let event = transform.apply(input).await.unwrap();
        assert!(matches!(event, Event::Transcript { .. }));
        assert!(gate.load(Ordering::Relaxed));
    }
}
