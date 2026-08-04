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
        // With no LAZYSPEAK_* env vars set, should fall back to defaults
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
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_VAD_THRESHOLD", "0.05")].into_iter());
        assert_eq!(cfg.vad_threshold, 0.05);
        // Others unchanged
        assert_eq!(cfg.silence_duration_ms, 400);
    }

    #[test]
    fn from_env_overrides_silence_ms() {
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_SILENCE_MS", "800")].into_iter());
        assert_eq!(cfg.silence_duration_ms, 800);
    }

    #[test]
    fn from_env_overrides_max_ms() {
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_MAX_MS", "60000")].into_iter());
        assert_eq!(cfg.max_duration_ms, 60000);
    }

    #[test]
    fn from_env_overrides_partial_ms() {
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_PARTIAL_MS", "0")].into_iter());
        assert_eq!(cfg.partial_interval_ms, 0);
    }

    #[test]
    fn from_env_overrides_window_ms() {
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_WINDOW_MS", "10000")].into_iter());
        assert_eq!(cfg.window_ms, 10000);
    }

    #[test]
    fn from_env_invalid_value_falls_back() {
        let cfg = AudioConfig::from_env_map([("LAZYSPEAK_SILENCE_MS", "not_a_number")].into_iter());
        assert_eq!(cfg.silence_duration_ms, 400); // default
    }

    #[test]
    fn from_env_multiple_overrides() {
        let cfg = AudioConfig::from_env_map([
            ("LAZYSPEAK_VAD_THRESHOLD", "0.1"),
            ("LAZYSPEAK_SILENCE_MS", "200"),
            ("LAZYSPEAK_PARTIAL_MS", "500"),
        ].into_iter());
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
    pub fn from_env_map<'a, I, K, V>(env: I) -> Self
    where
        I: IntoIterator<Item = (K, V)>,
        K: AsRef<str>,
        V: AsRef<str>,
    {
        let map: std::collections::HashMap<String, String> = env
            .into_iter()
            .map(|(k, v)| (k.as_ref().to_string(), v.as_ref().to_string()))
            .collect();
        fn parse<T: std::str::FromStr>(map: &std::collections::HashMap<String, String>, key: &str, default: T) -> T {
            map.get(key)
                .and_then(|v| v.parse().ok())
                .unwrap_or(default)
        }
        let d = AudioConfig::default();
        AudioConfig {
            sample_rate: d.sample_rate,
            channels: d.channels,
            vad_threshold: parse(&map, "LAZYSPEAK_VAD_THRESHOLD", d.vad_threshold),
            silence_duration_ms: parse(&map, "LAZYSPEAK_SILENCE_MS", d.silence_duration_ms),
            max_duration_ms: parse(&map, "LAZYSPEAK_MAX_MS", d.max_duration_ms),
            partial_interval_ms: parse(&map, "LAZYSPEAK_PARTIAL_MS", d.partial_interval_ms),
            window_ms: parse(&map, "LAZYSPEAK_WINDOW_MS", d.window_ms),
        }
    }

    /// Build from `LAZYSPEAK_*` environment variables, falling back to defaults
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
        window_start_ms: u64,
        window_end_ms: u64,
        seq: u64,
    },
    /// A complete utterance was captured.
    Utterance { samples: Vec<f32>, duration_ms: u64 },
    /// An error occurred.
    Error(String),
}

/// Captures audio from the default input device with energy-based VAD.
pub struct AudioCapture {
    config: AudioConfig,
    listening: Arc<AtomicBool>,
    device_sample_rate: u32,
}

impl AudioCapture {
    pub fn new(config: AudioConfig) -> Self {
        let host = cpal::default_host();
        let sample_rate = host
            .default_input_device()
            .and_then(|d| d.default_input_config().ok())
            .map(|c| c.sample_rate().0)
            .unwrap_or(config.sample_rate);

        Self {
            config,
            listening: Arc::new(AtomicBool::new(false)),
            device_sample_rate: sample_rate,
        }
    }

    /// Returns the actual sample rate of the capture device.
    pub fn sample_rate(&self) -> u32 {
        self.device_sample_rate
    }

    /// Start capturing audio. Sends events through the returned receiver.
    /// Call `stop()` to end capture.
    pub fn start(&self) -> Result<mpsc::Receiver<AudioEvent>> {
        let (tx, rx) = mpsc::channel();

        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .context("no input device available")?;

        let supported = device
            .default_input_config()
            .context("no supported input config")?;

        let stream_config = cpal::StreamConfig {
            channels: supported.channels().min(self.config.channels),
            sample_rate: supported.sample_rate(),
            buffer_size: cpal::BufferSize::Default,
        };

        let listening = self.listening.clone();
        let threshold = self.config.vad_threshold;
        let silence_dur = Duration::from_millis(self.config.silence_duration_ms);
        let max_dur = Duration::from_millis(self.config.max_duration_ms);
        let partial_interval = self.config.partial_interval_ms;
        let window_ms = self.config.window_ms;
        let sample_rate = stream_config.sample_rate.0;
        let device_channels = stream_config.channels as usize;

        let state = Arc::new(Mutex::new(CaptureState::new()));

        let state_clone = state.clone();
        let tx_clone = tx.clone();

        let stream = device.build_input_stream(
            &stream_config,
            move |data: &[f32], _: &cpal::InputCallbackInfo| {
                if !listening.load(Ordering::Relaxed) {
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
                    let _ = tx_clone.send(AudioEvent::Vad(true));
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
                        let _ = tx_clone.send(AudioEvent::Vad(false));

                        let samples = std::mem::take(&mut st.buffer);
                        let duration_ms = (samples.len() as u64 * 1000) / sample_rate as u64;
                        let _ = tx_clone.send(AudioEvent::Utterance {
                            samples,
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
                        let window_samples =
                            (window_ms as usize * sample_rate as usize) / 1000;
                        let window_start = if total_samples > window_samples {
                            total_samples - window_samples
                        } else {
                            0
                        };
                        let window = st.buffer[window_start..].to_vec();

                        let window_start_ms =
                            (window_start as u64 * 1000) / sample_rate as u64;
                        let window_end_ms = (total_samples as u64 * 1000) / sample_rate as u64;

                        st.seq += 1;
                        let _ = tx_clone.send(AudioEvent::Partial {
                            samples: window,
                            window_start_ms,
                            window_end_ms,
                            seq: st.seq,
                        });
                    }
                }
            },
            move |err| {
                let _ = tx.send(AudioEvent::Error(format!("audio stream error: {err}")));
            },
            None,
        )?;

        stream.play()?;
        // Leak the stream so it stays alive — stopped via the listening flag
        std::mem::forget(stream);

        self.listening.store(true, Ordering::Relaxed);

        Ok(rx)
    }

    pub fn set_listening(&self, active: bool) {
        self.listening.store(active, Ordering::Relaxed);
    }

    pub fn is_listening(&self) -> bool {
        self.listening.load(Ordering::Relaxed)
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
