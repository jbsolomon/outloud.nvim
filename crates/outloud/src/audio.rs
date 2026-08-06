//! Microphone capture and Voice Activity Detection.
//!
//! Uses `cpal` for cross-platform audio input. VAD is a simple energy-based
//! detector for now — will be replaced with silero-vad (ONNX) later.

use anyhow::{Context, Result};
use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

/// Configuration for audio capture.
pub struct AudioConfig {
    pub sample_rate: u32,
    pub channels: u16,
    pub vad_threshold: f32,
    pub silence_duration_ms: u64,
    pub max_duration_ms: u64,
    /// How often to emit an interim (partial) transcript while speaking.
    /// Zero disables partials.
    pub partial_interval_ms: u64,
    /// Size of the sliding window for partial transcription in milliseconds.
    /// Each partial only transcribes the most recent `window_ms` of audio.
    pub window_ms: u64,
    /// Optional device name to use for input. If None, uses the default device.
    pub device_name: Option<String>,
}

impl Default for AudioConfig {
    fn default() -> Self {
        Self {
            sample_rate: 16000,
            channels: 1,
            vad_threshold: 0.01,
            // Trailing-silence wait before finalizing. This is the dominant
            // perceived-latency knob, so it is kept short.
            silence_duration_ms: 400,
            max_duration_ms: 30000,
            partial_interval_ms: 700,
            window_ms: 5000,
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
        assert_eq!(cfg.sample_rate, 16000);
        assert_eq!(cfg.channels, 1);
        assert_eq!(cfg.vad_threshold, 0.01);
        assert_eq!(cfg.silence_duration_ms, 400);
        assert_eq!(cfg.max_duration_ms, 30000);
        assert_eq!(cfg.partial_interval_ms, 700);
        assert_eq!(cfg.window_ms, 5000);
    }

    #[test]
    fn from_env_no_vars() {
        // With no OUTLOUD_* env vars set, should fall back to defaults
        let cfg = AudioConfig::from_env_map(std::iter::empty::<(&str, &str)>());
        assert_eq!(cfg.sample_rate, 16000);
        assert_eq!(cfg.channels, 1);
        assert_eq!(cfg.vad_threshold, 0.01);
        assert_eq!(cfg.silence_duration_ms, 400);
        assert_eq!(cfg.max_duration_ms, 30000);
        assert_eq!(cfg.partial_interval_ms, 700);
        assert_eq!(cfg.window_ms, 5000);
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
    fn from_env_overrides_partial_ms() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_PARTIAL_MS", "0")].into_iter());
        assert_eq!(cfg.partial_interval_ms, 0);
    }

    #[test]
    fn from_env_overrides_window_ms() {
        let cfg = AudioConfig::from_env_map([("OUTLOUD_WINDOW_MS", "10000")].into_iter());
        assert_eq!(cfg.window_ms, 10000);
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
                ("OUTLOUD_PARTIAL_MS", "500"),
            ]
            .into_iter(),
        );
        assert_eq!(cfg.vad_threshold, 0.1);
        assert_eq!(cfg.silence_duration_ms, 200);
        assert_eq!(cfg.partial_interval_ms, 500);
        // Unchanged
        assert_eq!(cfg.max_duration_ms, 30000);
        assert_eq!(cfg.window_ms, 5000);
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
            sample_rate: d.sample_rate,
            channels: d.channels,
            vad_threshold: parse(&map, "OUTLOUD_VAD_THRESHOLD", d.vad_threshold),
            silence_duration_ms: parse(&map, "OUTLOUD_SILENCE_MS", d.silence_duration_ms),
            max_duration_ms: parse(&map, "OUTLOUD_MAX_MS", d.max_duration_ms),
            partial_interval_ms: parse(&map, "OUTLOUD_PARTIAL_MS", d.partial_interval_ms),
            window_ms: parse(&map, "OUTLOUD_WINDOW_MS", d.window_ms),
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
    /// An interim snapshot of the in-progress utterance, emitted periodically
    /// while the user is still speaking. Uses a sliding window of recent audio
    /// (not the full buffer) to keep each request constant-size.
    Partial {
        samples: Vec<f32>,
        sample_rate: u32,
        window_start_ms: u64,
        window_end_ms: u64,
        seq: u64,
    },
    /// A complete utterance was captured.
    Utterance { samples: Vec<f32>, sample_rate: u32, duration_ms: u64 },
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
                if d.name()?.eq_ignore_ascii_case(n) {
                    return Ok((d, n.to_string()));
                }
            }
            anyhow::bail!("input device '{}' not found", n);
        }
        None => {
            let device = host.default_input_device().context("no input device available")?;
            let name = device.name().unwrap_or_else(|_| "default".to_string());
            Ok((device, name))
        }
    }
}

impl AudioCapture {
    /// Create a new AudioCapture without opening any audio stream.
    ///
    /// Returns `(self, receiver)` — the receiver is handed to the pipeline
    /// at startup; all sessions write into the shared sender.
    pub fn new(config: AudioConfig) -> (Self, mpsc::Receiver<AudioEvent>) {
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

    /// Returns a list of available input devices as (name, is_default) pairs.
    pub fn list_devices() -> Result<Vec<(String, bool)>> {
        let host = cpal::default_host();
        let default_name = host
            .default_input_device()
            .and_then(|d| d.name().ok())
            .unwrap_or_default();

        let mut devices = host
            .input_devices()?
            .filter_map(|d| {
                let name = d.name().ok()?;
                Some((name.clone(), name == default_name))
            })
            .collect::<Vec<_>>();

        // Sort so default is first
        devices.sort_by(|a, b| b.1.cmp(&a.1));
        Ok(devices)
    }

    /// Start a capture session on the given device.
    ///
    /// If `device_name` is `Some`, uses that device. Falls back to
    /// `config.device_name`, then system default.
    ///
    /// The cpal stream is opened in a background thread and kept alive
    /// until `stop()` is called. Audio events flow into the shared channel
    /// that the pipeline reads from (obtained via `receiver()`).
    pub fn start(&self, device_name: Option<&str>) -> Result<()> {
        // Close any existing session first
        self.stop();

        let (device, name) = resolve_device(device_name.or_else(|| self.config.device_name.as_deref()))
            .context("no input device available")?;

        // Update the active device name
        *self.device_name.lock().unwrap() = Some(name.clone());

        let supported = device
            .default_input_config()
            .context("no supported input config")?;

        let stream_config = cpal::StreamConfig {
            channels: supported.channels().min(self.config.channels),
            sample_rate: supported.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let listening = Arc::new(AtomicBool::new(true));
        let threshold = self.config.vad_threshold;
        let silence_dur = Duration::from_millis(self.config.silence_duration_ms);
        let max_dur = Duration::from_millis(self.config.max_duration_ms);
        let partial_interval = self.config.partial_interval_ms;
        let window_ms = self.config.window_ms;
        let sample_rate = stream_config.sample_rate.0;
        let device_channels = stream_config.channels as usize;

        let state = Arc::new(Mutex::new(CaptureState::new()));

        let state_clone = state.clone();
        let tx_data = self.event_tx.clone();
        let tx_err = self.event_tx.clone();
        let listening_clone = listening.clone();

        // Build the stream in a background thread so we can keep it alive
        // without leaking memory. The thread holds the stream; dropping
        // the receiver signals it to exit.
        let (drop_tx, drop_rx) = std::sync::mpsc::channel();

        let _handle = std::thread::spawn(move || {
            let stream = device.build_input_stream(
                &stream_config,
                move |data: &[f32], _: &cpal::InputCallbackInfo| {
                    if !listening_clone.load(Ordering::Relaxed) {
                        return;
                    }

                    // Downmix to mono if device has multiple channels
                    let mono: Vec<f32> = if device_channels > 1 {
                        data.chunks(device_channels)
                            .map(|frame| frame.iter().sum::<f32>() / device_channels as f32)
                            .collect()
                    } else {
                        data.to_vec()
                    };
                    let data = &mono;

                    let rms = (data.iter().map(|s| s * s).sum::<f32>() / data.len() as f32).sqrt();
                    let is_speech = rms > threshold;

                    let mut st = state_clone.lock().unwrap();

                    // Detect speech start/stop transitions
                    if is_speech && !st.was_speaking {
                        st.was_speaking = true;
                        st.speech_start = Some(Instant::now());
                        st.last_speech = Instant::now();
                        st.last_partial = Instant::now();
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

                        if since_speech >= silence_dur || since_start >= max_dur {
                            st.was_speaking = false;
                            let _ = tx_data.send(AudioEvent::Vad(false));

                            let samples = std::mem::take(&mut st.buffer);
                            let duration_ms = (samples.len() as u64 * 1000) / sample_rate as u64;
                            let _ = tx_data.send(AudioEvent::Utterance {
                                samples,
                                sample_rate,
                                duration_ms,
                            });

                            st.speech_start = None;
                        } else if partial_interval > 0
                            && st.last_partial.elapsed() >= Duration::from_millis(partial_interval)
                            && !st.partial_in_flight
                        {
                            // Sliding window: only transcribe the most recent window_ms
                            // of audio, keeping each request constant-size.
                            st.last_partial = Instant::now();
                            st.partial_in_flight = true;

                            let total_samples = st.buffer.len();
                            let window_samples = (window_ms as usize * sample_rate as usize) / 1000;
                            let window_start = total_samples.saturating_sub(window_samples);
                            let window = st.buffer[window_start..].to_vec();

                            let window_start_ms = (window_start as u64 * 1000) / sample_rate as u64;
                            let window_end_ms = (total_samples as u64 * 1000) / sample_rate as u64;

                            st.seq += 1;
                            let _ = tx_data.send(AudioEvent::Partial {
                                samples: window,
                                sample_rate,
                                window_start_ms,
                                window_end_ms,
                                seq: st.seq,
                            });
                        }
                    }
                },
                {
                    let tx_err2 = tx_err.clone();
                    move |err| {
                        let _ = tx_err2.send(AudioEvent::Error(format!("audio stream error: {err}")));
                    }
                },
                None,
            );

            match stream {
                Ok(s) => {
                    if let Err(e) = s.play() {
                        let _ = tx_err.send(AudioEvent::Error(format!("failed to play stream: {e}")));
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
        *self.stream_handle.lock().unwrap() = Some(StreamHandle { _drop_signal: drop_tx });

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

struct CaptureState {
    buffer: Vec<f32>,
    was_speaking: bool,
    last_speech: Instant,
    speech_start: Option<Instant>,
    last_partial: Instant,
    /// True while a partial transcription is in flight (latest-wins policy).
    partial_in_flight: bool,
    /// Monotonic sequence number for partial ordering.
    seq: u64,
}

impl CaptureState {
    fn new() -> Self {
        Self {
            buffer: Vec::new(),
            was_speaking: false,
            last_speech: Instant::now(),
            speech_start: None,
            last_partial: Instant::now(),
            partial_in_flight: false,
            seq: 0,
        }
    }
}
