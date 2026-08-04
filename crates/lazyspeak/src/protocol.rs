//! JSON lines protocol for communicating with the Neovim plugin.

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd")]
pub enum Command {
    #[serde(rename = "start_listening")]
    StartListening,
    #[serde(rename = "stop_listening")]
    StopListening,
    #[serde(rename = "cancel")]
    Cancel,
    #[serde(rename = "shutdown")]
    Shutdown,
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Event {
    #[serde(rename = "status")]
    Status { state: State },
    #[serde(rename = "vad")]
    Vad { speaking: bool },
    /// An interim, non-final transcript emitted while the user is still
    /// speaking. Provisional — superseded by the final `Transcript`.
    /// Uses a sliding window so each partial is constant-size audio.
    #[serde(rename = "partial")]
    Partial {
        text: String,
        window_start_ms: u64,
        window_end_ms: u64,
        seq: u64,
    },
    #[serde(rename = "transcript")]
    Transcript { text: String, duration_ms: u64 },
    #[serde(rename = "error")]
    Error { message: String },
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Listening,
    Transcribing,
}

/// Read a command from a JSON line.
pub fn parse_command(line: &str) -> anyhow::Result<Command> {
    Ok(serde_json::from_str(line.trim())?)
}

/// Serialize an event to a JSON line.
pub fn serialize_event(event: &Event) -> anyhow::Result<String> {
    Ok(serde_json::to_string(event)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn partial_serializes_with_partial_tag() {
        let line = serialize_event(&Event::Partial {
            text: "hello".into(),
            window_start_ms: 0,
            window_end_ms: 5000,
            seq: 1,
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"partial","text":"hello","window_start_ms":0,"window_end_ms":5000,"seq":1}"#
        );
    }

    #[test]
    fn transcript_carries_duration() {
        let line = serialize_event(&Event::Transcript {
            text: "done".into(),
            duration_ms: 42,
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"transcript","text":"done","duration_ms":42}"#
        );
    }

    // --- Command parsing ---

    #[test]
    fn parse_start_listening() {
        let cmd = parse_command(r#"{"cmd": "start_listening"}"#).unwrap();
        assert!(matches!(cmd, Command::StartListening));
    }

    #[test]
    fn parse_stop_listening() {
        let cmd = parse_command(r#"{"cmd": "stop_listening"}"#).unwrap();
        assert!(matches!(cmd, Command::StopListening));
    }

    #[test]
    fn parse_cancel() {
        let cmd = parse_command(r#"{"cmd": "cancel"}"#).unwrap();
        assert!(matches!(cmd, Command::Cancel));
    }

    #[test]
    fn parse_shutdown() {
        let cmd = parse_command(r#"{"cmd": "shutdown"}"#).unwrap();
        assert!(matches!(cmd, Command::Shutdown));
    }

    #[test]
    fn parse_command_trims_whitespace() {
        let cmd = parse_command("  {\"cmd\": \"cancel\"}  ").unwrap();
        assert!(matches!(cmd, Command::Cancel));
    }

    #[test]
    fn parse_invalid_command_returns_err() {
        assert!(parse_command(r#"{"cmd": "bogus"}"#).is_err());
    }

    #[test]
    fn parse_malformed_json_returns_err() {
        assert!(parse_command("not json at all").is_err());
    }

    #[test]
    fn parse_empty_object_returns_err() {
        assert!(parse_command(r#"{}"#).is_err());
    }

    // --- Event serialization ---

    #[test]
    fn status_event_serializes() {
        let line = serialize_event(&Event::Status { state: State::Listening }).unwrap();
        assert_eq!(line, r#"{"type":"status","state":"listening"}"#);
    }

    #[test]
    fn vad_event_serializes_speaking() {
        let line = serialize_event(&Event::Vad { speaking: true }).unwrap();
        assert_eq!(line, r#"{"type":"vad","speaking":true}"#);
    }

    #[test]
    fn vad_event_serializes_silent() {
        let line = serialize_event(&Event::Vad { speaking: false }).unwrap();
        assert_eq!(line, r#"{"type":"vad","speaking":false}"#);
    }

    #[test]
    fn error_event_serializes() {
        let line = serialize_event(&Event::Error {
            message: "something broke".into(),
        })
        .unwrap();
        assert_eq!(line, r#"{"type":"error","message":"something broke"}"#);
    }

    #[test]
    fn state_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&State::Idle).unwrap(),
            r#""idle""#
        );
        assert_eq!(
            serde_json::to_string(&State::Listening).unwrap(),
            r#""listening""#
        );
        assert_eq!(
            serde_json::to_string(&State::Transcribing).unwrap(),
            r#""transcribing""#
        );
    }

    #[test]
    fn state_deserializes_lowercase() {
        let idle: State = serde_json::from_str(r#""idle""#).unwrap();
        assert!(matches!(idle, State::Idle));

        let listening: State = serde_json::from_str(r#""listening""#).unwrap();
        assert!(matches!(listening, State::Listening));

        let transcribing: State = serde_json::from_str(r#""transcribing""#).unwrap();
        assert!(matches!(transcribing, State::Transcribing));
    }

    // --- Partial event fields ---

    #[test]
    fn partial_with_empty_text() {
        let line = serialize_event(&Event::Partial {
            text: String::new(),
            window_start_ms: 100,
            window_end_ms: 200,
            seq: 5,
        })
        .unwrap();
        assert!(line.contains(r#""text":"""#));
        assert!(line.contains(r#""seq":5"#));
    }

    #[test]
    fn transcript_with_special_characters() {
        let line = serialize_event(&Event::Transcript {
            text: "hello \"world\" \\test".into(),
            duration_ms: 1000,
        })
        .unwrap();
        assert!(line.contains(r#"hello \"world\" \\test"#));
    }
}

