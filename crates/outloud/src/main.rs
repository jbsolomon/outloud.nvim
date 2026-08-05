use std::io::{self, BufRead, Write};
use std::sync::Arc;

use anyhow::Result;
use outloud::audio::{AudioCapture, AudioConfig};
use outloud::pipeline::{AudioSource, EventSink, TranscribeTransform, VadFilter};
use outloud::protocol::{Event, State, parse_command, serialize_event};
use outloud::transcribe::SpeechTranscriber;
use streamsafe::PipelineBuilder;
use tokio_util::sync::CancellationToken;

/// Build the transcription backend from environment variables.
///
/// OUTLOUD_STT_BACKEND — backend name: "whisper" (default) or "openai"
/// OUTLOUD_STT_URL — server URL (default depends on backend)
fn build_transcriber() -> Result<Box<dyn SpeechTranscriber>> {
    let backend =
        std::env::var("OUTLOUD_STT_BACKEND").unwrap_or_else(|_| "whisper".to_string());

    match backend.as_str() {
        #[cfg(feature = "whisper")]
        "whisper" => {
            use outloud::transcribe::whisper::{
                DEFAULT_SERVER_URL, WhisperTranscriber, WhisperTranscriberConfig,
            };
            let server_url =
                std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
            Ok(Box::new(WhisperTranscriber::new(WhisperTranscriberConfig { server_url })))
        }
        #[cfg(feature = "openai")]
        "openai" => {
            use outloud::transcribe::http::{
                DEFAULT_SERVER_URL, HttpTranscriber, HttpTranscriberConfig,
            };
            let server_url =
                std::env::var("OUTLOUD_STT_URL").unwrap_or_else(|_| DEFAULT_SERVER_URL.to_string());
            Ok(Box::new(HttpTranscriber::new(HttpTranscriberConfig { server_url })))
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
) {
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
                    outloud::protocol::Command::StartListening => {
                        audio.set_listening(true);
                        let _ = event_tx.blocking_send(Event::Status {
                            state: State::Listening,
                        });
                    }
                    outloud::protocol::Command::StopListening
                    | outloud::protocol::Command::Cancel => {
                        audio.set_listening(false);
                        let _ = event_tx.blocking_send(Event::Status { state: State::Idle });
                    }
                    outloud::protocol::Command::Shutdown => {
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
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_env_filter("outloud=debug")
        .init();

    // Unified event channel — all events flow through here to stdout.
    let (event_tx, event_rx) = tokio::sync::mpsc::channel::<Event>(64);

    // Initial status.
    let _ = event_tx.send(Event::Status { state: State::Idle }).await;

    // Transcription backend.
    let transcriber: Arc<dyn SpeechTranscriber> = Arc::from(build_transcriber()?);
    let stt_available = transcriber.is_ready();
    let backend_name = transcriber.name().to_string();
    if stt_available {
        tracing::info!("STT backend ready ({backend_name})");
    } else {
        tracing::warn!(
            "STT backend not ready ({backend_name}) — will emit placeholder transcripts"
        );
    }

    // Audio capture.
    let audio = Arc::new(AudioCapture::new(AudioConfig::from_env()));
    let device_sample_rate = audio.sample_rate();
    let sync_rx = audio.start()?;
    audio.set_listening(false);

    let token = CancellationToken::new();

    // Spawn stdout writer.
    let writer_handle = tokio::spawn(stdout_writer(event_rx));

    // Spawn stdin command handler.
    let stdin_handle = tokio::spawn(stdin_command_loop(
        audio.clone(),
        event_tx.clone(),
        token.clone(),
    ));

    // Build and run the pipeline.
    let pipeline_result = PipelineBuilder::from(AudioSource::new(sync_rx))
        .filter_pipe(VadFilter::new(event_tx.clone()))
        .pipe(TranscribeTransform::new(
            transcriber,
            device_sample_rate,
            stt_available,
        ))
        .into(EventSink::new(event_tx))
        .run_with_token(token)
        .await;

    // Cleanup.
    audio.set_listening(false);
    let _ = stdin_handle.await;
    let _ = writer_handle.await;

    pipeline_result.map_err(|e| anyhow::anyhow!("{e}"))
}
