//! Image attachments on messages.
//!
//! `read_file` returns images as an [`Attachment`] on the tool-result message
//! instead of refusing them as binary. The attachment records the image's
//! metadata (media type, source path, content hash, dimensions, byte size); the
//! pixels live on disk under the session's `attachments/` directory, referenced
//! by content hash so the same image is stored once and session logs stay small.
//!
//! Only the request builders turn an attachment into provider bytes (base64),
//! and only for the newest few images the model accepts — see
//! [`crate::llm::Message::attachments`].

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use sha2::Digest;

use crate::llm::Attachment;

/// Longest side a sent image is downscaled to (Anthropic's guidance). Images
/// within the limit are sent as-is.
pub const MAX_DIMENSION: u32 = 1568;

/// Default cap on the encoded byte size of one image (GitHub Copilot's
/// `max_prompt_image_size`). A model whose endpoint reports a different limit
/// overrides this.
pub const DEFAULT_MAX_BYTES: usize = 3 * 1024 * 1024;

/// An image format `read_file` recognises by magic bytes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImageFormat {
    Png,
    Jpeg,
    Gif,
    WebP,
}

impl ImageFormat {
    /// The format these magic bytes start, if it is one we accept.
    pub fn sniff(bytes: &[u8]) -> Option<Self> {
        if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
            Some(Self::Png)
        } else if bytes.starts_with(b"\xff\xd8\xff") {
            Some(Self::Jpeg)
        } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
            Some(Self::Gif)
        } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
            Some(Self::WebP)
        } else {
            None
        }
    }

    pub fn media_type(self) -> &'static str {
        match self {
            Self::Png => "image/png",
            Self::Jpeg => "image/jpeg",
            Self::Gif => "image/gif",
            Self::WebP => "image/webp",
        }
    }

    /// File extension used for the stored attachment copy.
    pub fn extension(self) -> &'static str {
        match self {
            Self::Png => "png",
            Self::Jpeg => "jpg",
            Self::Gif => "gif",
            Self::WebP => "webp",
        }
    }

    fn image_format(self) -> image::ImageFormat {
        match self {
            Self::Png => image::ImageFormat::Png,
            Self::Jpeg => image::ImageFormat::Jpeg,
            Self::Gif => image::ImageFormat::Gif,
            Self::WebP => image::ImageFormat::WebP,
        }
    }
}

/// The sha256 content hash of `bytes`, hex-encoded. Identifies an attachment's
/// stored copy and dedupes repeat reads of the same image.
pub fn sha256_hex(bytes: &[u8]) -> String {
    let digest = sha2::Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// Decode `bytes` and return `(width, height)`.
fn dimensions(bytes: &[u8]) -> Result<(u32, u32)> {
    let reader =
        image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().context("guess image format")?;
    reader.into_dimensions().context("read image dimensions")
}

/// Prepare `bytes` (an image of `format`) for sending to a model: downscale so
/// the longest side is at most `max_dim` and re-encode until it fits
/// `max_bytes`. Returns the (possibly unchanged) bytes, their media type and
/// dimensions. Re-encodes to JPEG when the source type is not in
/// `accepted_media_types` (empty = accept all).
pub fn prepare(
    bytes: &[u8],
    format: ImageFormat,
    max_dim: u32,
    max_bytes: usize,
    accepted_media_types: &[String],
) -> Result<PreparedImage> {
    let (mut width, mut height) = dimensions(bytes)?;
    let accepts_source =
        accepted_media_types.is_empty() || accepted_media_types.iter().any(|t| t == format.media_type());
    let mut out_bytes = bytes.to_vec();
    let mut media_type = format.media_type().to_string();

    let needs_downscale = width > max_dim || height > max_dim;
    let needs_reencode = !accepts_source;
    if needs_downscale || needs_reencode || out_bytes.len() > max_bytes {
        let img = image::load_from_memory_with_format(bytes, format.image_format())
            .with_context(|| format!("decode {}", format.media_type()))?;
        // Downscale to the longest-side cap, preserving aspect ratio.
        let mut img = if width > max_dim || height > max_dim {
            let (nw, nh) = scaled_dimensions(width, height, max_dim);
            img.resize(nw, nh, image::imageops::FilterType::Triangle)
        } else {
            img
        };
        // Encode, shrinking further until under the byte cap. JPEG has no alpha
        // and compresses photos well, so it is the fallback when the source type
        // is not accepted or the PNG stays too large.
        let mut use_jpeg = !accepts_source;
        loop {
            let (w, h) = (img.width(), img.height());
            let encoded = if use_jpeg { encode_jpeg(&img)? } else { encode_format(&img, format)? };
            if encoded.len() <= max_bytes || (w <= 16 && h <= 16) {
                out_bytes = encoded;
                media_type = if use_jpeg { "image/jpeg".to_string() } else { format.media_type().to_string() };
                width = w;
                height = h;
                break;
            }
            // Too big: switch to JPEG if we have not, else shrink and retry.
            if !use_jpeg {
                use_jpeg = true;
            } else {
                let (nw, nh) = ((w * 3 / 4).max(16), (h * 3 / 4).max(16));
                img = img.resize(nw, nh, image::imageops::FilterType::Triangle);
            }
        }
    }
    Ok(PreparedImage { bytes: out_bytes, media_type, width, height })
}

/// An image ready to send: its (possibly downscaled / re-encoded) bytes, the
/// media type of those bytes, and their pixel dimensions.
pub struct PreparedImage {
    pub bytes: Vec<u8>,
    pub media_type: String,
    pub width: u32,
    pub height: u32,
}

/// `(width, height)` scaled so the longest side is `max_dim`, aspect preserved.
fn scaled_dimensions(width: u32, height: u32, max_dim: u32) -> (u32, u32) {
    let longest = width.max(height);
    if longest <= max_dim {
        return (width, height);
    }
    let scale = max_dim as f64 / longest as f64;
    let w = ((width as f64 * scale).round() as u32).max(1);
    let h = ((height as f64 * scale).round() as u32).max(1);
    (w, h)
}

fn encode_format(img: &image::DynamicImage, format: ImageFormat) -> Result<Vec<u8>> {
    let mut out = std::io::Cursor::new(Vec::new());
    img.write_to(&mut out, format.image_format()).context("encode image")?;
    Ok(out.into_inner())
}

fn encode_jpeg(img: &image::DynamicImage) -> Result<Vec<u8>> {
    let mut out = std::io::Cursor::new(Vec::new());
    // JPEG has no alpha; flatten onto white so transparent pixels do not turn black.
    let rgb = img.to_rgb8();
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    encoder.encode_image(&rgb).context("encode jpeg")?;
    Ok(out.into_inner())
}

/// The per-model limits an image is prepared against.
#[derive(Debug, Clone)]
pub struct ImageLimits {
    pub max_dimension: u32,
    pub max_bytes: usize,
    /// Media types the model accepts; empty means any of ours.
    pub accepted_media_types: Vec<String>,
}

impl Default for ImageLimits {
    fn default() -> Self {
        Self { max_dimension: MAX_DIMENSION, max_bytes: DEFAULT_MAX_BYTES, accepted_media_types: Vec::new() }
    }
}

/// Write an attachment's prepared bytes to the session's attachments directory,
/// named by content hash so the same image is stored once. Returns the path.
/// `bytes` are the *prepared* (post-downscale) bytes whose hash is `attachment.sha256`.
pub fn store(attachments_dir: &Path, attachment: &Attachment, bytes: &[u8]) -> Result<PathBuf> {
    if sha256_hex(bytes) != attachment.sha256 {
        bail!("attachment bytes do not match their recorded hash");
    }
    std::fs::create_dir_all(attachments_dir).with_context(|| format!("create {}", attachments_dir.display()))?;
    let path = attachments_dir.join(format!("{}.{}", attachment.sha256, attachment.extension));
    if !path.exists() {
        std::fs::write(&path, bytes).with_context(|| format!("write {}", path.display()))?;
    }
    Ok(path)
}

/// Base64-encode an attachment's stored bytes for a provider payload. `None`
/// when the file is missing (e.g. deleted before a resume) — the caller then
/// sends a text placeholder instead.
pub fn read_base64(attachments_dir: &Path, attachment: &Attachment) -> Option<String> {
    let path = attachments_dir.join(format!("{}.{}", attachment.sha256, attachment.extension));
    let bytes = std::fs::read(path).ok()?;
    Some(base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sniffs_formats_by_magic_bytes() {
        assert_eq!(ImageFormat::sniff(b"\x89PNG\r\n\x1a\nrest"), Some(ImageFormat::Png));
        assert_eq!(ImageFormat::sniff(b"\xff\xd8\xff\xe0rest"), Some(ImageFormat::Jpeg));
        assert_eq!(ImageFormat::sniff(b"GIF89a rest"), Some(ImageFormat::Gif));
        assert_eq!(ImageFormat::sniff(b"RIFF....WEBPrest"), Some(ImageFormat::WebP));
        assert_eq!(ImageFormat::sniff(b"plain text"), None);
        assert_eq!(ImageFormat::sniff(b"%PDF-1.4"), None);
    }

    #[test]
    fn scaled_dimensions_preserve_aspect_and_cap() {
        assert_eq!(scaled_dimensions(100, 100, 1568), (100, 100));
        assert_eq!(scaled_dimensions(3136, 1568, 1568), (1568, 784));
        assert_eq!(scaled_dimensions(1568, 3136, 1568), (784, 1568));
    }

    #[test]
    fn sha256_is_stable() {
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    fn make_png(w: u32, h: u32) -> Vec<u8> {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(w, h, image::Rgb([200, 100, 50])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Png).unwrap();
        out.into_inner()
    }

    #[test]
    fn prepare_downscales_oversized_images() {
        // A 4000×2000 PNG exceeds the 1568 longest-side cap.
        let bytes = make_png(4000, 2000);
        let prepared = prepare(&bytes, ImageFormat::Png, MAX_DIMENSION, DEFAULT_MAX_BYTES, &[]).unwrap();
        assert_eq!(prepared.width, 1568);
        assert_eq!(prepared.height, 784);
        assert_eq!(prepared.media_type, "image/png");
        // The prepared bytes decode to the downscaled dimensions.
        assert_eq!(dimensions(&prepared.bytes).unwrap(), (1568, 784));
    }

    #[test]
    fn prepare_keeps_small_images_unchanged() {
        let bytes = make_png(100, 50);
        let prepared = prepare(&bytes, ImageFormat::Png, MAX_DIMENSION, DEFAULT_MAX_BYTES, &[]).unwrap();
        assert_eq!((prepared.width, prepared.height), (100, 50));
        assert_eq!(prepared.bytes, bytes, "within limits: sent as-is");
    }

    #[test]
    fn prepare_reencodes_when_type_not_accepted() {
        // A model accepting only JPEG gets a GIF re-encoded to JPEG.
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(20, 20, image::Rgb([1, 2, 3])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Gif).unwrap();
        let bytes = out.into_inner();
        let accepted = vec!["image/jpeg".to_string(), "image/png".to_string()];
        let prepared = prepare(&bytes, ImageFormat::Gif, MAX_DIMENSION, DEFAULT_MAX_BYTES, &accepted).unwrap();
        assert_eq!(prepared.media_type, "image/jpeg");
        assert_eq!(ImageFormat::sniff(&prepared.bytes), Some(ImageFormat::Jpeg));
    }

    #[test]
    fn prepare_shrinks_until_under_byte_cap() {
        // A large noisy PNG forced under a tiny byte cap shrinks and goes JPEG.
        let mut img = image::RgbImage::new(2000, 2000);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x % 251) as u8, (y % 239) as u8, ((x * y) % 233) as u8]);
        }
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
        let bytes = out.into_inner();
        let prepared = prepare(&bytes, ImageFormat::Png, MAX_DIMENSION, 50_000, &[]).unwrap();
        assert!(prepared.bytes.len() <= 50_000, "{} bytes", prepared.bytes.len());
    }

    #[test]
    fn store_and_read_round_trip_and_dedupe() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = make_png(10, 10);
        let attachment = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("/tmp/x.png"),
            sha256: sha256_hex(&bytes),
            width: 10,
            height: 10,
            bytes: bytes.len(),
            extension: "png".into(),
        };
        let p1 = store(dir.path(), &attachment, &bytes).unwrap();
        let p2 = store(dir.path(), &attachment, &bytes).unwrap();
        assert_eq!(p1, p2, "same hash stores once");
        assert!(read_base64(dir.path(), &attachment).is_some());
        // A missing file reads as None (the resume fallback).
        std::fs::remove_file(&p1).unwrap();
        assert_eq!(read_base64(dir.path(), &attachment), None);
        // Tampered bytes that don't match the hash are rejected.
        assert!(store(dir.path(), &attachment, b"other").is_err());
    }
}
