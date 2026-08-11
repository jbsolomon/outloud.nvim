use std::io::{self, BufRead, Write};
use std::sync::Arc;

use anyhow::Result;
use outloud::audio::{AudioCapture, AudioConfig};
use outloud::pipeline::{AudioSource, EventSink, TranscribeTransform, VadFilter};
use outloud::protocol::{
    BackendHealth, Event, State, StatusTracker, parse_command, serialize_event,
};
use outloud::transcribe::SpeechTranscriber;
use streamsafe::PipelineBuilder;
use tokio_util::sync::CancellationToken;

/// Build the transcription backend from environment variables.
///
/// OUTLOUD_STT_BACKEND — backend name: "whisper" (default) or "openai"
/// OUTLOUD_STT_URL — server URL (default depends on backend)
fn build_transcriber() -> Result<Box<dyn SpeechTranscriber>> {
    let backend = std::env::var("OUTLOUD_STT_BACKEND").unwrap_or_else(|_| "whisper".to_string());

    match backend.as_str() {
        #[cfg(feature = "whisper")]
        "whisper" => {
            use outloud::transcribe::whisper::{
                DEFAULT_SERVER_URL, WhisperTranscriber, WhisperTranscriberConfig,
            };
            let server_url =
                std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
            Ok(Box::new(WhisperTranscriber::new(
                WhisperTranscriberConfig { server_url },
            )))
        }
        #[cfg(feature = "openai")]
        "openai" => {
            use outloud::transcribe::http::{
                DEFAULT_SERVER_URL, HttpTranscriber, HttpTranscriberConfig,
            };
            let server_url =
                std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
            Ok(Box::new(HttpTranscriber::new(HttpTranscriberConfig {
                server_url,
            })))
        }
        _ => anyhow::bail!("unknown STT backend: {}", backend),
    }
}

/// Drains the event channel and writes JSON lines to stdout.
async fn stdout_writer(mut event_rx: tokio::sync::mpsc::Receiver<Event>) {
    let result: Result<()> = tokio::task::spawn_blocking(move || {
        let mut stdout = io::stdout().lock();
        while let Some(event) = event_rx.blocking_recv() {
            if let Ok(line) = serialize_event(&event) {
                if writeln!(stdout, "{line}").is_err() {
                    break;
                }
                if stdout.flush().is_err() {
                    break;
                }
            }
        }
        Ok(())
    })
    .await
    .unwrap_or(Ok(()));

    if let Err(e) = result {
        tracing::error!("stdout writer error: {e}");
    }
}

/// Reads stdin commands and controls audio capture + cancellation.
async fn stdin_command_loop(
    audio: Arc<AudioCapture>,
    event_tx: tokio::sync::mpsc::Sender<Event>,
    token: CancellationToken,
    tracker: StatusTracker,
) {
    use outloud::protocol::Command::*;
    use outloud::protocol::DeviceInfo;

    let _ = tokio::task::spawn_blocking(move || {
        let stdin = io::stdin().lock();
        for line in stdin.lines() {
            let line = match line {
                Ok(l) => l,
                Err(_) => break,
            };
            if line.trim().is_empty() {
                continue;
            }

            match parse_command(&line) {
                Ok(cmd) => match cmd {
                    StartListening {
                        device,
                        sample_format,
                    } => {
                        // Open the cpal stream on the requested device, in the
                        // native sample format forwarded by the client (or
                        // probed from the device when omitted).
                        // Audio events flow into the shared channel that the
                        // pipeline is already reading from.
                        match audio.start(device.as_deref(), sample_format.as_deref()) {
                            Ok(()) => {
                                let active = audio.device_name();
                                let _ = event_tx
                                    .blocking_send(tracker.transition(State::Listening, active));
                            }
                            Err(e) => {
                                let _ = event_tx.blocking_send(Event::Error {
                                    message: format!("failed to start capture: {e:?}"),
                                });
                                // Back to Idle; the tracker keeps the last-known
                                // backend health rather than inventing one.
                                let _ =
                                    event_tx.blocking_send(tracker.transition(State::Idle, None));
                            }
                        }
                    }
                    StopListening | Cancel => {
                        audio.stop();
                        let _ = event_tx.blocking_send(tracker.transition(State::Idle, None));
                    }
                    ListDevices => match AudioCapture::list_devices() {
                        Ok(devs) => {
                            let devices: Vec<DeviceInfo> = devs
                                .into_iter()
                                .map(|(name, is_default, sample_format)| DeviceInfo {
                                    name,
                                    is_default,
                                    sample_format,
                                })
                                .collect();
                            let default = devices
                                .iter()
                                .find(|d| d.is_default)
                                .map(|d| d.name.clone());
                            let _ = event_tx.blocking_send(Event::Devices { devices, default });
                        }
                        Err(e) => {
                            let _ = event_tx.blocking_send(Event::Error {
                                message: format!("listing devices failed: {e}"),
                            });
                        }
                    },
                    Shutdown => {
                        token.cancel();
                        break;
                    }
                },
                Err(e) => {
                    let _ = event_tx.blocking_send(Event::Error {
                        message: format!("invalid command: {e}"),
                    });
                }
            }
        }
    })
    .await;
}

#[tokio::main]
async fn main() -> Result<()> {
    // Handle --version flag before initializing anything else
    if std::env::args().any(|arg| arg == "--version" || arg == "-V") {
        println!("{}", env!("CARGO_PKG_VERSION"));
        std::process::exit(0);
    }

    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter("outloud=debug")
        .init();

    // Unified event channel — all events flow through here to stdout.
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(64);

    // Shared status snapshot. Every Status event flows through the tracker so
    // heartbeats, command responses, and pipeline events never contradict
    // each other's state/device/backend fields.
    let tracker = StatusTracker::new();

    // 1. Daemon alive, backend not yet probed.
    let _ = event_tx
        .send(tracker.health_update(BackendHealth::pending()))
        .await;

    // Transcription backend — probe immediately.
    let transcriber: Arc<dyn SpeechTranscriber> = Arc::from(build_transcriber()?);
    let stt_available = transcriber.is_ready();
    let backend_name = transcriber.name().to_string();
    let backend_url = std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| {
        if backend_name == "whisper" {
            "http://127.0.0.1:8000".into()
        } else {
            "http://127.0.0.1:8674".into()
        }
    });

    // 2. Emit the first health result immediately.
    if stt_available {
        tracing::info!("STT backend ready ({backend_name})");
        let _ = event_tx
            .send(tracker.health_update(BackendHealth::healthy()))
            .await;
    } else {
        tracing::warn!(
            "STT backend not ready ({backend_name}) — will emit placeholder transcripts"
        );
        let _ = event_tx
            .send(tracker.health_update(BackendHealth::unhealthy(format!(
                "{backend_name} at {backend_url} is unreachable"
            ))))
            .await;
    }

    // Audio capture — no stream opened yet. The pipeline reads from the shared
    // channel; individual sessions open/close the cpal stream via start()/stop().
    // new() returns (self, receiver) — receiver goes to pipeline, self is shared via Arc.
    let (audio, sync_rx) = AudioCapture::new(AudioConfig::from_env());
    let audio = Arc::new(audio);

    let token = CancellationToken::new();

    // Spawn stdout writer.
    let writer_handle = tokio::spawn(stdout_writer(event_rx));

    // Spawn stdin command handler.
    let stdin_handle = tokio::spawn(stdin_command_loop(
        audio.clone(),
        event_tx.clone(),
        token.clone(),
        tracker.clone(),
    ));

    // Periodic STT health heartbeat — pings the server every 5s and emits
    // Status with the probed backend health. State/device come from the
    // tracker, so a live recording is never clobbered by a stale Idle.
    let heartbeat_handle = tokio::spawn({
        let transcriber = transcriber.clone();
        let event_tx = event_tx.clone();
        let token = token.clone();
        let tracker = tracker.clone();
        async move {
            let mut interval = tokio::time::interval(tokio::time::Duration::from_secs(5));
            loop {
                interval.tick().await;
                if token.is_cancelled() {
                    break;
                }
                let healthy = transcriber.is_ready();
                let backend = if healthy {
                    BackendHealth::healthy()
                } else {
                    BackendHealth::unhealthy("STT server unreachable")
                };
                let _ = event_tx.send(tracker.health_update(backend)).await;
            }
        }
    });

    // Build and run the pipeline. The pipeline is built once and reads from the
    // shared audio event channel. Start/stop commands control the cpal stream.
    let pipeline_result = PipelineBuilder::from(AudioSource::new(sync_rx))
        .filter_pipe(VadFilter::new(event_tx.clone()))
        .pipe(TranscribeTransform::new(
            transcriber,
            stt_available,
        ))
        .into(EventSink::new(event_tx, tracker))
        .run_with_token(token)
        .await;

    // Cleanup.
    audio.stop();
    let _ = stdin_handle.await;
    let _ = writer_handle.await;
    let _ = heartbeat_handle.await;

    pipeline_result.map_err(|e| anyhow::anyhow!("{e}"))
}
