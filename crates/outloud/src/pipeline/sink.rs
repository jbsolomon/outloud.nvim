use crate::protocol::{Event, State, StatusTracker};
use streamsafe::{Result, Sink, StreamSafeError};

/// Terminal pipeline stage that sends transcript events to the unified
/// event channel, then emits an Idle status.
pub struct EventSink {
    event_tx: tokio::sync::mpsc::Sender<Event>,
    tracker: StatusTracker,
}

impl EventSink {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>, tracker: StatusTracker) -> Self {
        Self { event_tx, tracker }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::BackendHealth;

    #[tokio::test]
    async fn sink_sends_final_chunk_then_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx, StatusTracker::new());

        sink.consume(Event::Chunk {
            text: "hello".into(),
            duration_ms: 100,
            is_final: true,
        })
        .await
        .unwrap();

        // Should receive the final chunk followed by Idle status
        let event1 = event_rx.try_recv().unwrap();
        let event2 = event_rx.try_recv().unwrap();

        assert!(matches!(event1, Event::Chunk { is_final: true, .. }));
        assert!(matches!(
            event2,
            Event::Status {
                state: State::Idle,
                device: None,
                backend: BackendHealth {
                    status: ref _s,
                    error: None
                },
            }
        ));
    }

    #[tokio::test]
    async fn sink_sends_non_final_chunk_without_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx, StatusTracker::new());

        sink.consume(Event::Chunk {
            text: "interim".into(),
            duration_ms: 5000,
            is_final: false,
        })
        .await
        .unwrap();

        // Should receive only the chunk, no Idle status
        let event1 = event_rx.try_recv().unwrap();
        assert!(matches!(event1, Event::Chunk { is_final: false, .. }));

        // Channel should be empty now
        assert!(event_rx.is_empty());
    }

    #[tokio::test]
    async fn sink_sends_error_then_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx, StatusTracker::new());

        sink.consume(Event::Error {
            message: "something broke".into(),
        })
        .await
        .unwrap();

        let event1 = event_rx.try_recv().unwrap();
        let event2 = event_rx.try_recv().unwrap();

        assert!(matches!(event1, Event::Error { .. }));
        assert!(matches!(
            event2,
            Event::Status {
                state: State::Idle,
                device: None,
                ..
            }
        ));
    }

    #[tokio::test]
    async fn sink_channel_closed_returns_err() {
        let (event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(1);
        let mut sink = EventSink::new(event_tx, StatusTracker::new());

        // Drop the receiver to close the channel
        drop(event_rx);

        // Sending should fail
        let result = sink
            .consume(Event::Chunk {
                text: "hello".into(),
                duration_ms: 100,
                is_final: true,
            })
            .await;

        assert!(result.is_err());
    }
}

impl Sink for EventSink {
    type Input = Event;

    async fn consume(&mut self, input: Event) -> Result<()> {
        // Non-final chunks don't end the turn — emit them without the trailing
        // Idle status so the UI stays in its listening/transcribing state.
        let emit_idle = !matches!(&input, Event::Chunk { is_final: false, .. });
        self.event_tx
            .send(input)
            .await
            .map_err(|_| StreamSafeError::ChannelClosed)?;
        if emit_idle {
            self.event_tx
                .send(self.tracker.transition(State::Idle, None))
                .await
                .map_err(|_| StreamSafeError::ChannelClosed)?;
        }
        Ok(())
    }
}
