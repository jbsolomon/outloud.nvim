//! Microphone capture and Voice Activity Detection.
//!
//! Uses `cpal` for cross-platform audio input. VAD is a simple energy-based
//! detector for now — will be replaced with silero-vad (ONNX) later.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{FromSample, Sample};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// Configuration for audio capture.
///
/// The cpal stream is always opened with the device's native channel count
/// and sample rate: on WASAPI (Windows) the shared-mode audio engine only
/// accepts the mix format, so requesting anything else (e.g. mono from a
/// stereo mic array) fails with `StreamConfigNotSupported`. The VAD pipeline
/// downmixes to mono f32 in the stream callback, so the device layout is
/// transparent to everything downstream.
pub struct AudioConfig {
    pub vad_threshold: f32,
    pub silence_duration_ms: u64,
    pub max_duration_ms: u64,
    /// How often to emit a non-overlapping audio chunk while speaking.
    /// Zero disables chunking (only final utterance on silence).
    pub chunk_interval_ms: u64,
    /// Optional device name to use for input. If None, uses the default device.
    pub device_name: Option<String>,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            vad_threshold: 0.01,
            // Trailing-silence wait before finalizing. This is the dominant
            // perceived-latency knob, so it is kept short.
            silence_duration_ms: 400,
            max_duration_ms: 30000,
            chunk_interval_ms: 5000,
            device_name: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_config() {
        let cfg = AudioConfig::default();
        assert_eq!(cfg.vad_threshold, 0.01);
        assert_eq!(cfg.silence_duration_ms, 400);
        assert_eq!(cfg.max_duration_ms, 30000);
        assert_eq!(cfg.chunk_interval_ms, 5000);
    }

    #[test]
    fn from_env_no_vars() {
        // With no OUTLOUD_* env vars set, should fall back to defaults
        let cfg = AudioConfig::from_env_map(std::iter::empty::<(&str, &str)>());
        assert_eq!(cfg.vad_threshold, 0.01);
        assert_eq!(cfg.silence_duration_ms, 400);
        assert_eq!(cfg.max_duration_ms, 30000);
        assert_eq!(cfg.chunk_interval_ms, 5000);
    }

    #[test]
    fn from_env_overrides_vad_threshold() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_VAD_THRESHOLD", "0.05")].into_iter());
        assert_eq!(cfg.vad_threshold, 0.05);
        // Others unchanged
        assert_eq!(cfg.silence_duration_ms, 400);
    }

    #[test]
    fn from_env_overrides_silence_ms() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_SILENCE_MS", "800")].into_iter());
        assert_eq!(cfg.silence_duration_ms, 800);
    }

    #[test]
    fn from_env_overrides_max_ms() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_MAX_MS", "60000")].into_iter());
        assert_eq!(cfg.max_duration_ms, 60000);
    }

    #[test]
    fn from_env_overrides_chunk_ms() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_CHUNK_MS", "10000")].into_iter());
        assert_eq!(cfg.chunk_interval_ms, 10000);
    }

    #[test]
    fn from_env_invalid_value_falls_back() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_SILENCE_MS", "not_a_number")].into_iter());
        assert_eq!(cfg.silence_duration_ms, 400); // default
    }

    #[test]
    fn from_env_multiple_overrides() {
        let cfg = AudioConfig::from_env_map(
            [
                ("OUTLOUD_VAD_THRESHOLD", "0.1"),
                ("OUTLOUD_SILENCE_MS", "200"),
                ("OUTLOUD_CHUNK_MS", "500"),
            ]
            .into_iter(),
        );
        assert_eq!(cfg.vad_threshold, 0.1);
        assert_eq!(cfg.silence_duration_ms, 200);
        assert_eq!(cfg.chunk_interval_ms, 500);
        // Unchanged
        assert_eq!(cfg.max_duration_ms, 30000);
    }

    #[test]
    fn parse_sample_format_known() {
        assert!(matches!(
            parse_sample_format("i16"),
            Some(cpal::SampleFormat::I16)
        ));
        assert!(matches!(
            parse_sample_format("u16"),
            Some(cpal::SampleFormat::U16)
        ));
        assert!(matches!(
            parse_sample_format("f32"),
            Some(cpal::SampleFormat::F32)
        ));
        assert!(matches!(
            parse_sample_format("F32"),
            Some(cpal::SampleFormat::F32)
        ));
        assert!(matches!(
            parse_sample_format(" i16 "),
            Some(cpal::SampleFormat::I16)
        ));
    }

    #[test]
    fn parse_sample_format_unknown() {
        assert_eq!(parse_sample_format("banana"), None);
        assert_eq!(parse_sample_format(""), None);
    }

    /// The audio callback emits non-overlapping chunks at the configured
    /// interval. Each chunk contains samples that haven't been sent before.
    #[test]
    fn chunks_are_non_overlapping() {
        let params = CaptureParams {
            threshold: 0.01,
            silence_dur: Duration::from_millis(400),
            max_dur: Duration::from_millis(30000),
            chunk_interval: 10, // 10ms chunk interval for testing
            sample_rate: 16000,
            device_channels: 1,
        };
        let listening = AtomicBool::new(true);
        let state = Mutex::new(CaptureState::new());
        let (tx, rx) = mpsc::channel();
        // 10 ms of audio comfortably above the VAD threshold.
        let speech = vec![0.5f32; 160];

        // Speech start: VAD event only, no chunk yet (interval not elapsed).
        handle_input(&speech, &listening, &state, &tx, &params);
        assert!(matches!(rx.try_recv().unwrap(), AudioEvent::Vad(true)));

        // Interval elapsed → chunk emitted.
        state.lock().unwrap().last_chunk = Instant::now() - Duration::from_secs(1);
        handle_input(&speech, &listening, &state, &tx, &params);
        let evt = rx.try_recv().unwrap();
        assert!(matches!(evt, AudioEvent::Chunk { .. }));
        if let AudioEvent::Chunk { samples, .. } = evt {
            // First 160 accumulated but not emitted, then 160 more added.
            // Chunk contains all samples since last_chunk (which was reset
            // at speech start), so 320 total.
            assert_eq!(samples.len(), 320);
        }

        // Next callback: no new samples since last chunk, so nothing emitted.
        handle_input(&[0.0f32; 1], &listening, &state, &tx, &params);
        assert!(rx.try_recv().is_err());
    }
}

impl AudioConfig {
    /// Build from an iterator of (key, value) pairs, falling back to
    /// defaults for anything missing or unparseable.
    pub fn from_env_map<I, K, V>(env: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let map: std::collections::HashMap<String, String> = env
            .into_iter()
            .map(|(k, v)| (k.as_ref().to_string(), v.as_ref().to_string()))
            .collect();
        fn parse<T: std::str::FromStr>(
            map: &std::collections::HashMap<String, String>,
            key: &str,
            default: T,
        ) -> T {
            map.get(key).and_then(|v| v.parse().ok()).unwrap_or(default)
        }
        let d = AudioConfig::default();
        AudioConfig {
            vad_threshold: parse(&map, "OUTLOUD_VAD_THRESHOLD", d.vad_threshold),
            silence_duration_ms: parse(&map, "OUTLOUD_SILENCE_MS", d.silence_duration_ms),
            max_duration_ms: parse(&map, "OUTLOUD_MAX_MS", d.max_duration_ms),
            chunk_interval_ms: parse(&map, "OUTLOUD_CHUNK_MS", d.chunk_interval_ms),
            device_name: map
                .get("OUTLOUD_MIC_DEVICE")
                .and_then(|s| if s.is_empty() { None } else { Some(s.clone()) }),
        }
    }

    /// Build from `OUTLOUD_*` environment variables, falling back to defaults
    /// for anything unset or unparseable.
    pub fn from_env() -> Self {
        Self::from_env_map(std::env::vars())
    }
}

/// Events emitted by the audio capture system.
pub enum AudioEvent {
    /// VAD detected speech start/stop.
    Vad(bool),
    /// A non-overlapping chunk of the in-progress utterance, emitted
    /// periodically while the user is still speaking. Each chunk contains
    /// samples that haven't been sent before. `is_final` is true for the
    /// last chunk (triggered by silence or max duration).
    Chunk {
        samples: Vec<f32>,
        sample_rate: u32,
        duration_ms: u64,
        is_final: bool,
    },
    /// An error occurred.
    Error(String),
    /// Device info emitted when a capture session starts.
    DeviceInfo { name: String, sample_rate: u32 },
}

/// Captures audio from an input device with energy-based VAD.
///
/// The cpal stream is opened on `start()` and closed on `stop()`. This allows
/// switching devices between sessions without restarting the daemon.
pub struct AudioCapture {
    config: AudioConfig,
    /// Shared channel for audio events. The pipeline reads from the receiver
    /// (returned by `new()`); `start()` feeds events into this sender.
    event_tx: mpsc::Sender<AudioEvent>,
    /// Handle to the background thread that keeps the cpal stream alive.
    /// Dropping this handle closes the stream.
    stream_handle: Mutex<Option<StreamHandle>>,
    /// The device name for the **currently active** session.
    device_name: Mutex<Option<String>>,
}

/// Keeps a cpal stream alive in a background thread. Dropping this handle
/// signals the thread to drop the stream, releasing the device handle.
struct StreamHandle {
    /// Sending on this channel signals the background thread to drop the stream.
    _drop_signal: std::sync::mpsc::Sender<()>,
}

/// Resolve an input device by name, or fall back to the default.
fn resolve_device(name: Option<&str>) -> Result<(cpal::Device, String)> {
    let host = cpal::default_host();
    match name {
        Some(n) => {
            for d in host.input_devices()? {
                if d.to_string().eq_ignore_ascii_case(n) {
                    return Ok((d, n.to_string()));
                }
            }
            anyhow::bail!("input device '{}' not found", n);
        }
        None => {
            let device = host
                .default_input_device()
                .context("no input device available")?;
            let name = device.to_string();
            Ok((device, name))
        }
    }
}

impl AudioCapture {
    /// Create a new AudioCapture without opening any audio stream.
    ///
    /// Returns `(self, receiver)` — the receiver is handed to the pipeline
    /// at startup; all sessions write into the shared sender.
    pub fn new(
        config: AudioConfig,
    ) -> (Self, mpsc::Receiver<AudioEvent>) {
        let (event_tx, event_rx) = mpsc::channel();
        (
            Self {
                config,
                event_tx,
                stream_handle: Mutex::new(None),
                device_name: Mutex::new(None),
            },
            event_rx,
        )
    }

    /// Returns the name of the active capture device, or `None` if no session is active.
    pub fn device_name(&self) -> Option<String> {
        self.device_name.lock().unwrap().clone()
    }

    /// Returns a list of available input devices as (name, is_default, sample_format) tuples.
    pub fn list_devices() -> Result<Vec<(String, bool, String)>> {
        let host = cpal::default_host();
        let default_name = host
            .default_input_device()
            .map(|d| d.to_string())
            .unwrap_or_default();

        let mut devices = host
            .input_devices()?
            .map(|d| {
                let name = d.to_string();
                let sample_format = d
                    .default_input_config()
                    .ok()
                    .map(|c| c.sample_format().to_string())
                    .unwrap_or_else(|| "unknown".to_string());
                (name.clone(), name == default_name, sample_format)
            })
            .collect::<Vec<_>>();

        // Sort so default is first
        devices.sort_by_key(|d| std::cmp::Reverse(d.1));
        Ok(devices)
    }

    /// Start a capture session on the given device.
    ///
    /// If `device_name` is `Some`, uses that device. Falls back to
    /// `config.device_name`, then system default.
    ///
    /// `sample_format` is the device's native sample format as forwarded in
    /// the `start_listening` request (e.g. `"i16"`, `"f32"`). The cpal stream
    /// is opened in exactly that format, avoiding cpal's internal conversion
    /// layer. If `None`, the daemon probes the device's default input config
    /// itself.
    ///
    /// The cpal stream is opened in a background thread and kept alive
    /// until `stop()` is called. Audio events flow into the shared channel
    /// that the pipeline reads from (obtained via `receiver()`).
    pub fn start(&self, device_name: Option<&str>, sample_format: Option<&str>) -> Result<()> {
        // Close any existing session first
        self.stop();

        let (device, name) = resolve_device(device_name.or(self.config.device_name.as_deref()))
            .context("no input device available")?;

        // Update the active device name
        *self.device_name.lock().unwrap() = Some(name.clone());

        let supported = device
            .default_input_config()
            .context("no supported input config")?;

        // Sample format: prefer the one forwarded in the start request,
        // otherwise probe the device itself.
        let sample_format = match sample_format {
            Some(s) => parse_sample_format(s)
                .with_context(|| format!("unsupported sample format '{s}' in start request"))?,
            None => supported.sample_format(),
        };

        // Open the stream in the device's native configuration. Requesting
        // anything else — e.g. fewer channels than the hardware provides —
        // is rejected by WASAPI's shared-mode engine with
        // `StreamConfigNotSupported` ("The requested stream configuration is
        // not supported by the device"). Multi-channel input is downmixed to
        // mono in the stream callback, so capturing every channel is safe.
        let stream_config = cpal::StreamConfig {
            channels: supported.channels(),
            sample_rate: supported.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let listening = Arc::new(AtomicBool::new(true));
        let params = CaptureParams {
            threshold: self.config.vad_threshold,
            silence_dur: Duration::from_millis(self.config.silence_duration_ms),
            max_dur: Duration::from_millis(self.config.max_duration_ms),
            chunk_interval: self.config.chunk_interval_ms,
            sample_rate: stream_config.sample_rate,
            device_channels: stream_config.channels as usize,
        };

        let tx_data = self.event_tx.clone();
        let tx_err = self.event_tx.clone();

        // Build the stream in a background thread so we can keep it alive
        // without leaking memory. The thread holds the stream; dropping
        // the receiver signals it to exit.
        let (drop_tx, drop_rx) = std::sync::mpsc::channel();

        let _handle = std::thread::spawn(move || {
            // Build a stream whose data callback receives samples in the
            // device's native format; they are converted to f32 inside the
            // callback so the VAD pipeline stays format-agnostic.
            macro_rules! build_typed {
                ($t:ty) => {
                    build_typed_stream::<$t>(
                        &device,
                        stream_config,
                        params,
                        listening.clone(),
                        tx_data.clone(),
                        tx_err.clone(),
                    )
                };
            }

            let stream: Result<cpal::Stream, String> = match sample_format {
                cpal::SampleFormat::I8 => build_typed!(i8),
                cpal::SampleFormat::I16 => build_typed!(i16),
                cpal::SampleFormat::I32 => build_typed!(i32),
                cpal::SampleFormat::I64 => build_typed!(i64),
                cpal::SampleFormat::U8 => build_typed!(u8),
                cpal::SampleFormat::U16 => build_typed!(u16),
                cpal::SampleFormat::U32 => build_typed!(u32),
                cpal::SampleFormat::U64 => build_typed!(u64),
                cpal::SampleFormat::F32 => build_typed!(f32),
                cpal::SampleFormat::F64 => build_typed!(f64),
                // I24/U24/DSD formats are exotic for microphone input;
                // report an error rather than guessing at a conversion.
                other => Err(format!("unsupported sample format: {other}")),
            };

            match stream {
                Ok(s) => {
                    if let Err(e) = s.play() {
                        let _ =
                            tx_err.send(AudioEvent::Error(format!("failed to play stream: {e}")));
                    }
                    // Block until drop signal is received. Dropping `s` releases the cpal stream.
                    let _ = drop_rx.recv();
                    drop(s);
                }
                Err(e) => {
                    let _ = tx_err.send(AudioEvent::Error(format!("failed to build stream: {e}")));
                }
            }
        });

        // Store the handle so we can close the stream on stop()
        *self.stream_handle.lock().unwrap() = Some(StreamHandle {
            _drop_signal: drop_tx,
        });

        Ok(())
    }

    /// Stop the current capture session, closing the cpal stream and releasing
    /// the device handle. Safe to call when no session is active.
    pub fn stop(&self) {
        let mut handle = self.stream_handle.lock().unwrap();
        if let Some(h) = handle.take() {
            // Signal the background thread to drop the stream
            let _ = h._drop_signal.send(());
        }
        *self.device_name.lock().unwrap() = None;
    }

    /// Returns true if a capture session is currently active.
    pub fn is_active(&self) -> bool {
        self.stream_handle.lock().unwrap().is_some()
    }
}

/// Fixed capture parameters shared by every input stream callback,
/// regardless of the device's native sample format.
#[derive(Clone)]
struct CaptureParams {
    /// RMS energy threshold for speech detection.
    threshold: f32,
    /// Trailing silence before finalizing an utterance.
    silence_dur: Duration,
    /// Maximum utterance length.
    max_dur: Duration,
    /// How often to emit non-overlapping chunks; zero disables them.
    chunk_interval: u64,
    /// The stream's sample rate (the device's native rate).
    sample_rate: u32,
    /// Number of channels on the device (pre-downmix).
    device_channels: usize,
}

/// Parse a sample format string forwarded in the `start_listening` request
/// (e.g. `"i16"`, `"f32"`). Returns `None` for unknown formats.
fn parse_sample_format(s: &str) -> Option<cpal::SampleFormat> {
    match s.trim().to_ascii_lowercase().as_str() {
        "i8" => Some(cpal::SampleFormat::I8),
        "i16" => Some(cpal::SampleFormat::I16),
        "i32" => Some(cpal::SampleFormat::I32),
        "i64" => Some(cpal::SampleFormat::I64),
        "u8" => Some(cpal::SampleFormat::U8),
        "u16" => Some(cpal::SampleFormat::U16),
        "u32" => Some(cpal::SampleFormat::U32),
        "u64" => Some(cpal::SampleFormat::U64),
        "f32" => Some(cpal::SampleFormat::F32),
        "f64" => Some(cpal::SampleFormat::F64),
        _ => None,
    }
}

/// Build a cpal input stream whose data callback receives samples in the
/// native format `T`. Samples are converted to f32 inside the callback, so
/// the VAD pipeline below stays format-agnostic.
fn build_typed_stream<T>(
    device: &cpal::Device,
    stream_config: cpal::StreamConfig,
    params: CaptureParams,
    listening: Arc<AtomicBool>,
    tx_data: mpsc::Sender<AudioEvent>,
    tx_err: mpsc::Sender<AudioEvent>,
) -> Result<cpal::Stream, String>
where
    T: cpal::SizedSample,
    f32: FromSample<T>,
{
    let state = Arc::new(Mutex::new(CaptureState::new()));
    device
        .build_input_stream(
            stream_config,
            move |data: &[T], _: &cpal::InputCallbackInfo| {
                handle_input(data, &listening, &state, &tx_data, &params);
            },
            move |err| {
                let _ = tx_err.send(AudioEvent::Error(format!("audio stream error: {err}")));
            },
            None,
        )
        .map_err(|e| e.to_string())
}

/// Input callback body: converts native samples to mono f32 and runs the
/// energy-based VAD state machine.
fn handle_input<T>(
    data: &[T],
    listening: &AtomicBool,
    state: &Mutex<CaptureState>,
    tx_data: &mpsc::Sender<AudioEvent>,
    params: &CaptureParams,
) where
    T: cpal::Sample,
    f32: FromSample<T>,
{
    if !listening.load(Ordering::Relaxed) {
        return;
    }

    // Convert to mono f32, downmixing if the device has multiple channels.
    let mono: Vec<f32> = if params.device_channels > 1 {
        data.chunks(params.device_channels)
            .map(|frame| {
                frame.iter().map(|&s| f32::from_sample(s)).sum::<f32>()
                    / params.device_channels as f32
            })
            .collect()
    } else {
        data.iter().map(|&s| f32::from_sample(s)).collect()
    };
    let data = &mono;

    let rms = (data.iter().map(|s| s * s).sum::<f32>() / data.len() as f32).sqrt();
    let is_speech = rms > params.threshold;

    let mut st = state.lock().unwrap();

    // Detect speech start/stop transitions
    if is_speech && !st.was_speaking {
        st.was_speaking = true;
        st.speech_start = Some(Instant::now());
        st.last_speech = Instant::now();
        st.last_chunk = Instant::now();
        st.chunked_samples = 0;
        let _ = tx_data.send(AudioEvent::Vad(true));
    } else if is_speech {
        st.last_speech = Instant::now();
    }

    // Accumulate samples while speaking
    if st.was_speaking {
        st.buffer.extend_from_slice(data);
    }

    // Check for silence timeout or max duration
    if st.was_speaking {
        let since_speech = st.last_speech.elapsed();
        let since_start = st
            .speech_start
            .map(|s| s.elapsed())
            .unwrap_or(Duration::ZERO);

        if since_speech >= params.silence_dur || since_start >= params.max_dur {
            st.was_speaking = false;
            let _ = tx_data.send(AudioEvent::Vad(false));

            // Flush any samples not yet emitted in a periodic chunk.
            // is_final = true tells the client this is the last chunk.
            if st.buffer.len() > st.chunked_samples {
                let remaining = st.buffer[st.chunked_samples..].to_vec();
                let duration_ms = (remaining.len() as u64 * 1000) / params.sample_rate as u64;
                let _ = tx_data.send(AudioEvent::Chunk {
                    samples: remaining,
                    sample_rate: params.sample_rate,
                    duration_ms,
                    is_final: true,
                });
            }

            std::mem::take(&mut st.buffer);
            st.speech_start = None;
        } else if params.chunk_interval > 0
            && st.last_chunk.elapsed() >= Duration::from_millis(params.chunk_interval)
            && st.buffer.len() > st.chunked_samples
        {
            // Non-overlapping chunk: emit all samples since the last chunk.
            // Each sample is transcribed exactly once — no sliding window,
            // no gate, no staleness checks.
            st.last_chunk = Instant::now();

            let chunk_end = st.buffer.len();
            let chunk = st.buffer[st.chunked_samples..chunk_end].to_vec();
            st.chunked_samples = chunk_end;

            let duration_ms = (chunk.len() as u64 * 1000) / params.sample_rate as u64;
            let _ = tx_data.send(AudioEvent::Chunk {
                samples: chunk,
                sample_rate: params.sample_rate,
                duration_ms,
                is_final: false,
            });
        }
    }
}

struct CaptureState {
    buffer: Vec<f32>,
    was_speaking: bool,
    last_speech: Instant,
    speech_start: Option<Instant>,
    /// When the last chunk was emitted.
    last_chunk: Instant,
    /// Number of samples already emitted in chunks.
    chunked_samples: usize,
}

impl CaptureState {
    fn new() -> Self {
        Self {
            buffer: Vec::new(),
            was_speaking: false,
            last_speech: Instant::now(),
            speech_start: None,
            last_chunk: Instant::now(),
            chunked_samples: 0,
        }
    }
}
