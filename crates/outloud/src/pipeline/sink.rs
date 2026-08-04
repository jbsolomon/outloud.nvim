use crate::protocol::{Event, State};
use streamsafe::{Result, Sink, StreamSafeError};

/// Terminal pipeline stage that sends transcript events to the unified
/// event channel, then emits an Idle status.
pub struct EventSink {
    event_tx: tokio::sync::mpsc::Sender<Event>,
}

impl EventSink {
    pub fn new(event_tx: tokio::sync::mpsc::Sender<Event>) -> Self {
        Self { event_tx }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn sink_sends_non_partial_then_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx);

        sink.consume(Event::Transcript {
            text: "hello".into(),
            duration_ms: 100,
        })
        .await
        .unwrap();

        // Should receive the transcript followed by Idle status
        let event1 = event_rx.try_recv().unwrap();
        let event2 = event_rx.try_recv().unwrap();

        assert!(matches!(event1, Event::Transcript { .. }));
        assert!(matches!(event2, Event::Status { state: State::Idle }));
    }

    #[tokio::test]
    async fn sink_sends_partial_without_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx);

        sink.consume(Event::Partial {
            text: "interim".into(),
            window_start_ms: 0,
            window_end_ms: 5000,
            seq: 1,
        })
        .await
        .unwrap();

        // Should receive only the partial, no Idle status
        let event1 = event_rx.try_recv().unwrap();
        assert!(matches!(event1, Event::Partial { .. }));

        // Channel should be empty now
        assert!(event_rx.is_empty());
    }

    #[tokio::test]
    async fn sink_sends_error_then_idle() {
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<Event>(16);
        let mut sink = EventSink::new(event_tx);

        sink.consume(Event::Error {
            message: "something broke".into(),
        })
        .await
        .unwrap();

        let event1 = event_rx.try_recv().unwrap();
        let event2 = event_rx.try_recv().unwrap();

        assert!(matches!(event1, Event::Error { .. }));
        assert!(matches!(event2, Event::Status { state: State::Idle }));
    }

    #[tokio::test]
    async fn sink_channel_closed_returns_err() {
        let (event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(1);
        let mut sink = EventSink::new(event_tx);

        // Drop the receiver to close the channel
        drop(event_rx);

        // Sending should fail
        let result = sink
            .consume(Event::Transcript {
                text: "hello".into(),
                duration_ms: 100,
            })
            .await;

        assert!(result.is_err());
    }
}

impl Sink for EventSink {
    type Input = Event;

    async fn consume(&mut self, input: Event) -> Result<()> {
        // Interim partials don't end the turn — emit them without the trailing
        // Idle status so the UI stays in its listening/transcribing state.
        let is_partial = matches!(input, Event::Partial { .. });
        self.event_tx
            .send(input)
            .await
            .map_err(|_| StreamSafeError::ChannelClosed)?;
        if !is_partial {
            self.event_tx
                .send(Event::Status { state: State::Idle })
                .await
                .map_err(|_| StreamSafeError::ChannelClosed)?;
        }
        Ok(())
    }
}
