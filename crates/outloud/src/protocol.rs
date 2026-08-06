//! JSON lines protocol for communicating with the Neovim plugin.

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
#[serde(tag = "cmd")]
pub enum Command {
    #[serde(rename = "start_listening")]
    StartListening {
        /// Optional device name to use for this listening session.
        /// If omitted, falls back to config default or system default.
        device: Option<String>,
    },
    #[serde(rename = "stop_listening")]
    StopListening,
    #[serde(rename = "cancel")]
    Cancel,
    #[serde(rename = "shutdown")]
    Shutdown,
    #[serde(rename = "list_devices")]
    ListDevices,
}

/// Backend liveness — always serialized as an object with `status`
/// ("pending", "healthy", or "unhealthy") and optional `error`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BackendHealth {
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl BackendHealth {
    pub fn pending() -> Self {
        Self {
            status: "pending".into(),
            error: None,
        }
    }
    pub fn healthy() -> Self {
        Self {
            status: "healthy".into(),
            error: None,
        }
    }
    pub fn unhealthy(error: impl Into<String>) -> Self {
        Self {
            status: "unhealthy".into(),
            error: Some(error.into()),
        }
    }
}

/// Tracks the last status the daemon emitted so that every `Event::Status`
/// carries a consistent `(state, device, backend)` snapshot.
///
/// State/device transitions go through [`StatusTracker::transition`], which
/// attaches the last-known backend health; health probes go through
/// [`StatusTracker::health_update`], which attaches the current state/device.
/// Without this, the periodic health heartbeat would have to invent a state
/// (clobbering a live recording) and pipeline events would have to invent a
/// health value (masking a dead STT server).
#[derive(Debug, Clone)]
pub struct StatusTracker {
    inner: Arc<Mutex<StatusSnapshot>>,
}

#[derive(Debug)]
struct StatusSnapshot {
    state: State,
    device: Option<String>,
    backend: BackendHealth,
}

impl StatusTracker {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(Mutex::new(StatusSnapshot {
                state: State::Idle,
                device: None,
                backend: BackendHealth::pending(),
            })),
        }
    }

    /// Record a state/device transition and build the status event to emit,
    /// carrying the last-known backend health.
    pub fn transition(&self, state: State, device: Option<String>) -> Event {
        let mut guard = self.inner.lock().unwrap();
        guard.state = state;
        guard.device = device;
        Self::snapshot_event(&guard)
    }

    /// Record a backend health probe result and build the status event to
    /// emit, carrying the current state/device.
    pub fn health_update(&self, backend: BackendHealth) -> Event {
        let mut guard = self.inner.lock().unwrap();
        guard.backend = backend;
        Self::snapshot_event(&guard)
    }

    fn snapshot_event(snapshot: &StatusSnapshot) -> Event {
        Event::Status {
            state: snapshot.state,
            device: snapshot.device.clone(),
            backend: snapshot.backend.clone(),
        }
    }
}

impl Default for StatusTracker {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Debug, Serialize)]
#[serde(tag = "type")]
pub enum Event {
    #[serde(rename = "status")]
    Status {
        state: State,
        device: Option<String>,
        backend: BackendHealth,
    },
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
    #[serde(rename = "devices")]
    Devices {
        devices: Vec<DeviceInfo>,
        default: Option<String>,
    },
}

/// Information about an available input device.
#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct DeviceInfo {
    pub name: String,
    #[serde(rename = "is_default")]
    pub is_default: bool,
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
        assert!(matches!(cmd, Command::StartListening { device: None }));
    }

    #[test]
    fn parse_start_listening_with_device() {
        let cmd = parse_command(r#"{"cmd": "start_listening", "device": "Blue Yeti"}"#).unwrap();
        match cmd {
            Command::StartListening { device } => {
                assert_eq!(device.as_deref(), Some("Blue Yeti"));
            }
            _ => panic!("expected StartListening"),
        }
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
        let line = serialize_event(&Event::Status {
            state: State::Listening,
            device: Some("Blue Yeti".to_string()),
            backend: BackendHealth::healthy(),
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"status","state":"listening","device":"Blue Yeti","backend":{"status":"healthy"}}"#
        );
    }

    #[test]
    fn status_event_serializes_null_device() {
        let line = serialize_event(&Event::Status {
            state: State::Idle,
            device: None,
            backend: BackendHealth::pending(),
        })
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"status","state":"idle","device":null,"backend":{"status":"pending"}}"#
        );
    }

    #[test]
    fn status_tracker_transition_keeps_last_known_backend() {
        let tracker = StatusTracker::new();
        let _ = tracker.health_update(BackendHealth::unhealthy("down"));
        let event = tracker.transition(State::Listening, Some("mic".into()));
        match event {
            Event::Status {
                state,
                device,
                backend,
            } => {
                assert!(matches!(state, State::Listening));
                assert_eq!(device.as_deref(), Some("mic"));
                assert_eq!(backend.status, "unhealthy");
                assert_eq!(backend.error.as_deref(), Some("down"));
            }
            _ => panic!("expected status event"),
        }
    }

    #[test]
    fn status_tracker_health_update_keeps_current_state() {
        let tracker = StatusTracker::new();
        let _ = tracker.transition(State::Listening, Some("mic".into()));
        let event = tracker.health_update(BackendHealth::healthy());
        match event {
            Event::Status {
                state,
                device,
                backend,
            } => {
                // A heartbeat must never clobber a live recording with Idle.
                assert!(matches!(state, State::Listening));
                assert_eq!(device.as_deref(), Some("mic"));
                assert_eq!(backend.status, "healthy");
                assert!(backend.error.is_none());
            }
            _ => panic!("expected status event"),
        }
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
        assert_eq!(serde_json::to_string(&State::Idle).unwrap(), r#""idle""#);
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
