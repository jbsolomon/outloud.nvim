use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;

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
/// Uses `spawn_blocking` because `SpeechTranscriber::transcribe` is synchronous.
pub struct TranscribeTransform {
    transcriber: Arc<dyn SpeechTranscriber>,
    sample_rate: u32,
    stt_available: bool,
    /// Tracks the highest sequence number currently in-flight. Used to discard
    /// stale partial results that complete after a newer partial has started.
    latest_seq: Arc<AtomicU64>,
}

impl TranscribeTransform {
    pub fn new(
        transcriber: Arc<dyn SpeechTranscriber>,
        sample_rate: u32,
        stt_available: bool,
    ) -> Self {
        Self {
            transcriber,
            sample_rate,
            stt_available,
            latest_seq: Arc::new(AtomicU64::new(0)),
        }
    }
}

impl Transform for TranscribeTransform {
    type Input = UtteranceData;
    type Output = Event;

    async fn apply(&mut self, input: UtteranceData) -> Result<Event> {
        let transcriber = self.transcriber.clone();
        let sample_rate = self.sample_rate;
        let stt_available = self.stt_available;
        let duration_ms = input.duration_ms;
        let is_final = input.is_final;
        let seq = input.seq;
        let window_start_ms = input.window_start_ms;
        let window_end_ms = input.window_end_ms;
        let latest_seq = self.latest_seq.clone();

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
                },
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


