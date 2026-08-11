use crate::audio::AudioEvent;
use crate::protocol::Event;
use streamsafe::{FilterTransform, Result};

/// Data extracted from an utterance, passed downstream for transcription.
pub struct UtteranceData {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub duration_ms: u64,
    /// True for the finalized utterance, false for interim chunks.
    pub is_final: bool,
}

/// Filters the audio event stream: emits VAD/error events as side-effects
/// to the event channel and passes only utterances through the pipeline.
pub struct VadFilter {
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

impl VadFilter {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>) -> Self {
        Self { event_tx }
    }
}

impl FilterTransform for VadFilter {
    type Input = AudioEvent;
    type Output = UtteranceData;

    async fn apply(&mut self, input: AudioEvent) -> Result<Option<UtteranceData>> {
        match input {
            AudioEvent::Vad(speaking) => {
                let _ = self.event_tx.send(Event::Vad { speaking }).await;
                Ok(None)
            }
            AudioEvent::Chunk {
                samples,
                sample_rate,
                duration_ms,
                is_final,
            } => Ok(Some(UtteranceData {
                samples,
                sample_rate,
                duration_ms,
                is_final,
            })),
            AudioEvent::Error(msg) => {
                let _ = self.event_tx.send(Event::Error { message: msg }).await;
                Ok(None)
            }
            AudioEvent::DeviceInfo { .. } => {
                // DeviceInfo is handled by the command loop, not the pipeline
                Ok(None)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio::AudioEvent;

    fn make_filter() -> VadFilter {
        let (_event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let _ = event_rx; // suppress unused warning
        VadFilter::new(_event_tx)
    }

    #[tokio::test]
    async fn vad_true_is_suppressed() {
        let mut filter = make_filter();
        let result = filter.apply(AudioEvent::Vad(true)).await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn vad_false_is_suppressed() {
        let mut filter = make_filter();
        let result = filter.apply(AudioEvent::Vad(false)).await.unwrap();
        assert!(result.is_none());
    }

    #[tokio::test]
    async fn chunk_becomes_utterance_data() {
        let mut filter = make_filter();
        let samples = vec![0.1, 0.2];
        let result = filter
            .apply(AudioEvent::Chunk {
                samples: samples.clone(),
                sample_rate: 16000,
                duration_ms: 5000,
                is_final: false,
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.samples, samples);
        assert_eq!(result.sample_rate, 16000);
        assert!(!result.is_final);
        assert_eq!(result.duration_ms, 5000);
    }

    #[tokio::test]
    async fn final_chunk_becomes_utterance_data() {
        let mut filter = make_filter();
        let samples = vec![0.1, 0.2];
        let result = filter
            .apply(AudioEvent::Chunk {
                samples: samples.clone(),
                sample_rate: 16000,
                duration_ms: 5000,
                is_final: true,
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.samples, samples);
        assert!(result.is_final);
    }

    #[tokio::test]
    async fn error_is_suppressed() {
        let mut filter = make_filter();
        let result = filter
            .apply(AudioEvent::Error("test error".into()))
            .await
            .unwrap();
        assert!(result.is_none());
    }
}
