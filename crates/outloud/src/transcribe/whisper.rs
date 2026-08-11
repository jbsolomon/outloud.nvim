//! Whisper transcription backend.
//!
//! Delegates STT to a [whisper-server](https://github.com/fstirl/whisper-server)
//! instance over HTTP. This is the default backend for outloud.

use super::{SpeechTranscriber, TranscribeResult};
use anyhow::{Context, Result};
use reqwest::blocking::Client;
use serde::Deserialize;
use std::io::Cursor;
use std::time::Instant;

pub const DEFAULT_SERVER_URL: &str = "http://127.0.0.1:8000";

pub struct WhisperTranscriberConfig {
    pub server_url: String,
    /// Timeout for each /inference request. Larger models (e.g. turbo q8)
    /// on CPU can need 60–120 s for long utterances.
    pub timeout_secs: u64,
}

pub struct WhisperTranscriber {
    server_url: String,
    client: Client,
}

impl WhisperTranscriber {
    pub fn new(config: WhisperTranscriberConfig) -> Self {
        Self {
            server_url: config.server_url,
            client: Client::builder()
                .timeout(std::time::Duration::from_secs(config.timeout_secs))
                .build()
                .expect("failed to build HTTP client"),
        }
    }

    /// POST to whisper-server's /inference endpoint.
    fn try_inference_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/inference", self.server_url);
        let start = std::time::Instant::now();

        let form = reqwest::blocking::multipart::Form::new()
            .part(
                "file",
                reqwest::blocking::multipart::Part::bytes(wav_bytes.to_vec())
                    .file_name("audio.wav")
                    .mime_str("audio/wav")?,
            )
            // no_context=false: carry the last ~1000 tokens as context into each
            // chunk so the model has continuity across chunk boundaries. This
            // eliminates trailing "..." and leading punctuation artifacts that
            // occur when each chunk is transcribed in isolation.
            .text("no_context", "false")
            // split_on_word=true: split on word boundaries rather than token
            // boundaries, reducing mid-word truncation at chunk edges.
            .text("split_on_word", "true");

        tracing::info!("POST {} ({} bytes)", url, wav_bytes.len());

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .context("inference endpoint request failed")?;

        let elapsed_send = start.elapsed();
        tracing::info!("response received in {:?}", elapsed_send);

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            anyhow::bail!("inference endpoint returned {status}: {body}");
        }

        let body: InferenceResponse = resp.json().context("failed to parse inference response")?;
        let total_elapsed = start.elapsed();
        tracing::info!("inference complete in {:?}", total_elapsed);
        Ok(body.text.trim().to_string())
    }
}

impl SpeechTranscriber for WhisperTranscriber {
    fn transcribe(&self, samples: &[f32], sample_rate: u32) -> Result<TranscribeResult> {
        let start = Instant::now();
        let wav_bytes = encode_wav(samples, sample_rate)?;
        let text = self.try_inference_endpoint(&wav_bytes)?;

        Ok(TranscribeResult {
            text,
            duration_ms: start.elapsed().as_millis() as u64,
        })
    }

    fn is_ready(&self) -> bool {
        // whisper-server responds to GET / with a simple text response
        let url = self.server_url.clone();
        self.client.get(&url).send().is_ok()
    }

    fn name(&self) -> &str {
        "whisper"
    }
}

// --- Wire types (private) ---------------------------------------------------

#[derive(Deserialize)]
struct InferenceResponse {
    text: String,
}

/// Encode f32 samples as a WAV file in memory.
///
/// Whisper-server expects 16 kHz mono audio. If the device captures at a
/// different rate (e.g. 48 kHz on WASAPI shared mode), resample via
/// nearest-neighbor before encoding.
fn encode_wav(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>> {
    const WHISPER_SAMPLE_RATE: u32 = 16000;

    let samples_16k = if sample_rate == WHISPER_SAMPLE_RATE {
        samples.to_vec()
    } else {
        resample_nearest(samples, sample_rate, WHISPER_SAMPLE_RATE)
    };

    let mut buf = Vec::new();
    let mut cursor = Cursor::new(&mut buf);

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate: WHISPER_SAMPLE_RATE,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };

    let mut writer = hound::WavWriter::new(&mut cursor, spec)?;
    for &sample in &samples_16k {
        let s16 = (sample * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer.write_sample(s16)?;
    }
    writer.finalize()?;

    Ok(buf)
}

/// Resample `samples` from `from_rate` to `to_rate` using nearest-neighbor
/// interpolation. Good enough for speech — whisper-server will do its own
/// filtering anyway.
fn resample_nearest(samples: &[f32], from_rate: u32, to_rate: u32) -> Vec<f32> {
    if samples.is_empty() {
        return Vec::new();
    }
    let out_len = (samples.len() as u64 * to_rate as u64 / from_rate as u64) as usize;
    let mut out = Vec::with_capacity(out_len);
    for i in 0..out_len {
        let src_idx = ((i as u64 * from_rate as u64) / to_rate as u64) as usize;
        out.push(samples[src_idx.min(samples.len() - 1)]);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_wav_produces_valid_header() {
        let samples = vec![0.0f32; 160];
        let wav = encode_wav(&samples, 16000).unwrap();
        assert_eq!(&wav[..4], b"RIFF");
        assert_eq!(&wav[8..12], b"WAVE");
    }

    #[test]
    fn encode_wav_correct_sample_count() {
        let samples = vec![0.5f32; 100];
        let wav = encode_wav(&samples, 16000).unwrap();
        assert_eq!(wav.len(), 44 + 100 * 2);
    }

    #[test]
    fn encode_wav_silence_is_near_zero() {
        let samples = vec![0.0f32; 160];
        let wav = encode_wav(&samples, 16000).unwrap();
        let audio_data = &wav[44..];
        for chunk in audio_data.chunks(2) {
            let sample = i16::from_le_bytes([chunk[0], chunk[1]]);
            assert_eq!(sample, 0);
        }
    }

    #[test]
    fn encode_wav_full_scale_positive() {
        let samples = vec![1.0f32; 1];
        let wav = encode_wav(&samples, 16000).unwrap();
        let audio_data = &wav[44..];
        let sample = i16::from_le_bytes([audio_data[0], audio_data[1]]);
        assert_eq!(sample, 32767);
    }

    #[test]
    fn encode_wav_full_scale_negative() {
        let samples = vec![-1.0f32; 1];
        let wav = encode_wav(&samples, 16000).unwrap();
        let audio_data = &wav[44..];
        let sample = i16::from_le_bytes([audio_data[0], audio_data[1]]);
        assert_eq!(sample, -32767);
    }

    #[test]
    fn encode_wav_clamps_over_scale() {
        let samples = vec![2.0f32; 1];
        let wav = encode_wav(&samples, 16000).unwrap();
        let audio_data = &wav[44..];
        let sample = i16::from_le_bytes([audio_data[0], audio_data[1]]);
        assert_eq!(sample, 32767);
    }

    #[test]
    fn encode_wav_clamps_under_scale() {
        let samples = vec![-2.0f32; 1];
        let wav = encode_wav(&samples, 16000).unwrap();
        let audio_data = &wav[44..];
        let sample = i16::from_le_bytes([audio_data[0], audio_data[1]]);
        assert_eq!(sample, -32768);
    }

    #[test]
    fn encode_wav_empty_samples() {
        let samples: Vec<f32> = vec![];
        let wav = encode_wav(&samples, 16000).unwrap();
        assert_eq!(wav.len(), 44);
    }
}
