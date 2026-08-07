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
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .expect("failed to build HTTP client"),
        }
    }

    /// POST to whisper-server's /inference endpoint.
    fn try_inference_endpoint(&self, wav_bytes: &[u8]) -> Result<String> {
        let url = format!("{}/inference", self.server_url);

        let form = reqwest::blocking::multipart::Form::new().part(
            "file",
            reqwest::blocking::multipart::Part::bytes(wav_bytes.to_vec())
                .file_name("audio.wav")
                .mime_str("audio/wav")?,
        );

        let resp = self
            .client
            .post(&url)
            .multipart(form)
            .send()
            .context("inference endpoint request failed")?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().unwrap_or_default();
            anyhow::bail!("inference endpoint returned {status}: {body}");
        }

        let body: InferenceResponse = resp.json().context("failed to parse inference response")?;
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
fn encode_wav(samples: &[f32], sample_rate: u32) -> Result<Vec<u8>> {
    let mut buf = Vec::new();
    let mut cursor = Cursor::new(&mut buf);

    let spec = hound::WavSpec {
        channels: 1,
        sample_rate,
        bits_per_sample: 16,
        sample_format: hound::SampleFormat::Int,
    };

    let mut writer = hound::WavWriter::new(&mut cursor, spec)?;
    for &sample in samples {
        let s16 = (sample * 32767.0).clamp(-32768.0, 32767.0) as i16;
        writer.write_sample(s16)?;
    }
    writer.finalize()?;

    Ok(buf)
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
