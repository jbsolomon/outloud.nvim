use std::sync::Arc;

use crate::protocol::Event;
use crate::transcribe::SpeechTranscriber;
use streamsafe::{Result, StreamSafeError, Transform};

use super::filter::UtteranceData;

/// Transcribes utterance audio into text via the STT backend.
///
/// All utterances become `Event::Chunk` with an `is_final` flag.
/// Each chunk is transcribed exactly once — no gate,
/// no staleness checks, no sliding window.
///
/// Uses `spawn_blocking` because `SpeechTranscriber::transcribe` is synchronous.
///
/// Sample rate is taken from each `UtteranceData` input (per-utterance),
/// allowing device switching between sessions without restarting the daemon.
pub struct TranscribeTransform {
    transcriber: Arc<dyn SpeechTranscriber>,
    stt_available: bool,
}

impl TranscribeTransform {
    pub fn new(
        transcriber: Arc<dyn SpeechTranscriber>,
        stt_available: bool,
    ) -> Self {
        Self {
            transcriber,
            stt_available,
        }
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
                    Event::Chunk {
                        text: String::new(),
                        duration_ms,
                        is_final: false,
                    }
                };
            }

            match transcriber.transcribe(&input.samples, sample_rate) {
                Ok(r) => Event::Chunk {
                    text: r.text,
                    duration_ms,
                    is_final,
                },
                Err(e) if is_final => Event::Error {
                    message: format!("transcription failed: {e}"),
                },
                Err(_) => Event::Chunk {
                    text: String::new(),
                    duration_ms,
                    is_final: false,
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

    fn chunk_input() -> UtteranceData {
        UtteranceData {
            samples: vec![0.1; 160],
            sample_rate: 16000,
            duration_ms: 10,
            is_final: false,
        }
    }

    fn final_input() -> UtteranceData {
        UtteranceData {
            samples: vec![0.1; 160],
            sample_rate: 16000,
            duration_ms: 10,
            is_final: true,
        }
    }

    #[tokio::test]
    async fn chunk_becomes_chunk_event() {
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), true);

        let event = transform.apply(chunk_input()).await.unwrap();
        assert!(matches!(event, Event::Chunk { text, .. } if text == "hello"));
    }

    #[tokio::test]
    async fn final_becomes_chunk_with_is_final() {
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), true);

        let event = transform.apply(final_input()).await.unwrap();
        assert!(matches!(event, Event::Chunk { text, is_final: true, .. } if text == "hello"));
    }

    #[tokio::test]
    async fn chunk_returns_empty_when_stt_unavailable() {
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), false);

        let event = transform.apply(chunk_input()).await.unwrap();
        assert!(matches!(event, Event::Chunk { text, .. } if text.is_empty()));
    }

    #[tokio::test]
    async fn final_returns_error_when_stt_unavailable() {
        let mut transform = TranscribeTransform::new(Arc::new(StubTranscriber), false);

        let event = transform.apply(final_input()).await.unwrap();
        assert!(matches!(event, Event::Error { .. }));
    }
}
