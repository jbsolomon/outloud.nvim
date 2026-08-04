use crate::audio::AudioEvent;
use crate::protocol::{Event, State};
use streamsafe::{FilterTransform, Result};

/// Data extracted from an utterance, passed downstream for transcription.
pub struct UtteranceData {
    pub samples: Vec<f32>,
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
            AudioEvent::Partial {
                samples,
                window_start_ms,
                window_end_ms,
                seq,
            } => Ok(Some(UtteranceData {
                samples,
                duration_ms: window_end_ms - window_start_ms,
                is_final: false,
                window_start_ms,
                window_end_ms,
                seq,
            })),
            AudioEvent::Utterance {
                samples,
                duration_ms,
            } => {
                let _ = self
                    .event_tx
                    .send(Event::Status {
                        state: State::Transcribing,
                    })
                    .await;
                Ok(Some(UtteranceData {
                    samples,
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
        }
    }
}
