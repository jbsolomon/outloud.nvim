use crate::audio::AudioEvent;
use crate::protocol::{Event, State, StatusTracker};
use streamsafe::{FilterTransform, Result};

/// Data extracted from an utterance, passed downstream for transcription.
pub struct UtteranceData {
    pub samples: Vec<f32>,
    pub sample_rate: u32,
    pub duration_ms: u64,
    /// False for interim (partial) snapshots, true for the finalized utterance.
    pub is_final: bool,
    /// Sliding window metadata for partials (offset from utterance start in ms).
    pub window_start_ms: u64,
    pub window_end_ms: u64,
    /// Monotonic sequence number for partial ordering.
    pub seq: u64,
}

/// Filters the audio event stream: emits VAD/error events as side-effects
/// to the event channel and passes only utterances through the pipeline.
pub struct VadFilter {
    event_tx: tokio::sync::mpsc::Sender<Event>,
    tracker: StatusTracker,
}

impl VadFilter {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>, tracker: StatusTracker) -> Self {
        Self { event_tx, tracker }
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
            AudioEvent::Partial {
                samples,
                sample_rate,
                window_start_ms,
                window_end_ms,
                seq,
            } => Ok(Some(UtteranceData {
                samples,
                sample_rate,
                duration_ms: window_end_ms - window_start_ms,
                is_final: false,
                window_start_ms,
                window_end_ms,
                seq,
            })),
            AudioEvent::Utterance {
                samples,
                sample_rate,
                duration_ms,
            } => {
                let _ = self
                    .event_tx
                    .send(self.tracker.transition(State::Transcribing, None))
                    .await;
                Ok(Some(UtteranceData {
                    samples,
                    sample_rate,
                    duration_ms,
                    is_final: true,
                    window_start_ms: 0,
                    window_end_ms: duration_ms,
                    seq: 0,
                }))
            }
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
        VadFilter::new(_event_tx, StatusTracker::new())
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
    async fn utterance_becomes_utterance_data() {
        let mut filter = make_filter();
        let samples = vec![0.1, 0.2, 0.3];
        let result = filter
            .apply(AudioEvent::Utterance {
                samples: samples.clone(),
                sample_rate: 16000,
                duration_ms: 100,
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.samples, samples);
        assert_eq!(result.sample_rate, 16000);
        assert_eq!(result.duration_ms, 100);
        assert!(result.is_final);
        assert_eq!(result.window_start_ms, 0);
        assert_eq!(result.window_end_ms, 100);
        assert_eq!(result.seq, 0);
    }

    #[tokio::test]
    async fn partial_becomes_utterance_data() {
        let mut filter = make_filter();
        let samples = vec![0.1, 0.2];
        let result = filter
            .apply(AudioEvent::Partial {
                samples: samples.clone(),
                sample_rate: 16000,
                window_start_ms: 500,
                window_end_ms: 5500,
                seq: 3,
            })
            .await
            .unwrap()
            .unwrap();
        assert_eq!(result.samples, samples);
        assert_eq!(result.sample_rate, 16000);
        assert!(!result.is_final);
        assert_eq!(result.window_start_ms, 500);
        assert_eq!(result.window_end_ms, 5500);
        assert_eq!(result.seq, 3);
        assert_eq!(result.duration_ms, 5000); // window_end - window_start
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
