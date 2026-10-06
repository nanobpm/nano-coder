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
/// dimensions.
///
/// The output type is always one the endpoint accepts: the source type when it
/// is in `accepted_media_types` (empty = accept any of ours), else a re-encode
/// into an accepted codec this build can emit (JPEG, then PNG). Fails clearly
/// when none of those is accepted, rather than sending a type the model
/// rejects. Also fails when the image still exceeds `max_bytes` at the minimum
/// dimensions, rather than returning oversized bytes the request would reject.
pub fn prepare(
    bytes: &[u8],
    format: ImageFormat,
    max_dim: u32,
    max_bytes: usize,
    accepted_media_types: &[String],
) -> Result<PreparedImage> {
    let (mut width, mut height) = dimensions(bytes)?;
    let accepts = |mt: &str| accepted_media_types.is_empty() || accepted_media_types.iter().any(|t| t == mt);
    let accepts_source = accepts(format.media_type());
    // The codec to re-encode into when the bytes must change (unaccepted source
    // type, or too large to keep). JPEG compresses photos best; PNG is the
    // lossless fallback; otherwise keep an accepted source type. If none of
    // those is accepted there is no codec we can emit, so fail clearly rather
    // than send a rejected type.
    let shrink_codec = if accepts(ImageFormat::Jpeg.media_type()) {
        ImageFormat::Jpeg
    } else if accepts(ImageFormat::Png.media_type()) {
        ImageFormat::Png
    } else if accepts_source {
        format
    } else {
        bail!(
            "image is {}, but the model accepts only {:?} and this build can re-encode \
             only to PNG or JPEG",
            format.media_type(),
            accepted_media_types
        );
    };

    let mut out_bytes = bytes.to_vec();
    // The format the prepared bytes are actually encoded as — media type and
    // file extension are both derived from this, so they never disagree with
    // the bytes (e.g. after a JPEG re-encode).
    let mut out_format = format;

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
        // Start from the source type when the model accepts it (avoids a
        // needless recompression), else go straight to the accepted re-encode
        // codec. Encode, shrinking until under the byte cap.
        let mut codec = if accepts_source { format } else { shrink_codec };
        loop {
            let (w, h) = (img.width(), img.height());
            let encoded = encode_as(&img, codec)?;
            if encoded.len() <= max_bytes {
                out_bytes = encoded;
                out_format = codec;
                width = w;
                height = h;
                break;
            }
            // Too big: switch to the size-reducing codec first, before shrinking.
            if codec != shrink_codec {
                codec = shrink_codec;
                continue;
            }
            // Already the smallest codec and still over the cap at the minimum
            // dimensions: the cap cannot be met, so fail instead of returning
            // oversized bytes the provider would reject.
            if w <= 16 && h <= 16 {
                bail!(
                    "image cannot be reduced under the {max_bytes}-byte limit even at {w}×{h}; \
                     the model's image size limit is too small for this image"
                );
            }
            let (nw, nh) = ((w * 3 / 4).max(16), (h * 3 / 4).max(16));
            img = img.resize(nw, nh, image::imageops::FilterType::Triangle);
        }
    }
    Ok(PreparedImage {
        bytes: out_bytes,
        media_type: out_format.media_type().to_string(),
        extension: out_format.extension().to_string(),
        width,
        height,
    })
}

/// An image ready to send: its (possibly downscaled / re-encoded) bytes, the
/// media type of those bytes, the file extension matching that media type, and
/// their pixel dimensions.
#[derive(Debug)]
pub struct PreparedImage {
    pub bytes: Vec<u8>,
    pub media_type: String,
    pub extension: String,
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

/// Encode `img` as `codec`, flattening alpha for the alpha-less JPEG codec.
fn encode_as(img: &image::DynamicImage, codec: ImageFormat) -> Result<Vec<u8>> {
    if codec == ImageFormat::Jpeg { encode_jpeg(img) } else { encode_format(img, codec) }
}

fn encode_jpeg(img: &image::DynamicImage) -> Result<Vec<u8>> {
    let mut out = std::io::Cursor::new(Vec::new());
    // JPEG has no alpha; composite onto white so transparent pixels do not turn
    // black. `to_rgb8()` alone would merely drop the alpha channel, leaving the
    // (commonly black) RGB under transparent pixels.
    let rgb = flatten_onto_white(img);
    let mut encoder = image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, 85);
    encoder.encode_image(&rgb).context("encode jpeg")?;
    Ok(out.into_inner())
}

/// Alpha-composite `img` over an opaque white background, returning RGB. Fully
/// opaque pixels are unchanged; fully transparent pixels become white.
fn flatten_onto_white(img: &image::DynamicImage) -> image::RgbImage {
    let rgba = img.to_rgba8();
    let (width, height) = rgba.dimensions();
    let mut rgb = image::RgbImage::new(width, height);
    for (dst, src) in rgb.pixels_mut().zip(rgba.pixels()) {
        let a = u32::from(src[3]);
        let inv = 255 - a;
        // `channel * a + white(255) * (255 - a)`, rounded, over 255.
        let over = |c: u8| (((u32::from(c) * a + 255 * inv) + 127) / 255) as u8;
        *dst = image::Rgb([over(src[0]), over(src[1]), over(src[2])]);
    }
    rgb
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

/// An attachment's on-disk file name, `<sha256>.<extension>`, validated before
/// it is joined onto the attachments directory.
///
/// The metadata comes from a deserialized session log, so neither field is
/// trustworthy: a crafted or corrupt entry could carry `../` (or an absolute /
/// separator-bearing) `sha256` or `extension` and make a resume read or write
/// *outside* `<session>.attachments`, sending unrelated local bytes to the
/// provider. Both fields are therefore restricted to the shapes the writer
/// produces — `sha256` is 64 lowercase hex digits, `extension` is one of the
/// known image extensions — so the joined name can never escape the directory.
/// Returns `None` for anything else; callers then treat the attachment as
/// unavailable (read) or refuse it (store).
fn stored_filename(attachment: &Attachment) -> Option<String> {
    let sha = attachment.sha256.as_str();
    let valid_sha = sha.len() == 64 && sha.bytes().all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase());
    let valid_ext = matches!(attachment.extension.as_str(), "png" | "jpg" | "gif" | "webp");
    (valid_sha && valid_ext).then(|| format!("{sha}.{}", attachment.extension))
}

/// Write an attachment's prepared bytes to the session's attachments directory,
/// named by content hash so the same image is stored once. Returns the path.
/// `bytes` are the *prepared* (post-downscale) bytes whose hash is `attachment.sha256`.
pub fn store(attachments_dir: &Path, attachment: &Attachment, bytes: &[u8]) -> Result<PathBuf> {
    if sha256_hex(bytes) != attachment.sha256 {
        bail!("attachment bytes do not match their recorded hash");
    }
    let filename = stored_filename(attachment).context("attachment metadata fails validation")?;
    std::fs::create_dir_all(attachments_dir).with_context(|| format!("create {}", attachments_dir.display()))?;
    let path = attachments_dir.join(filename);
    if !path.exists() {
        std::fs::write(&path, bytes).with_context(|| format!("write {}", path.display()))?;
    }
    Ok(path)
}

/// Base64-encode an attachment's stored bytes for a provider payload. `None`
/// when the file is missing (e.g. deleted before a resume) — the caller then
/// sends a text placeholder instead. The stored bytes are re-checked against
/// the recorded hash so a tampered or swapped file is not sent to the provider.
pub fn read_base64(attachments_dir: &Path, attachment: &Attachment) -> Option<String> {
    let path = attachments_dir.join(stored_filename(attachment)?);
    let bytes = std::fs::read(path).ok()?;
    if sha256_hex(&bytes) != attachment.sha256 {
        return None;
    }
    Some(base64::Engine::encode(&base64::engine::general_purpose::STANDARD, bytes))
}

/// Whether an attachment's stored copy is still available *intact* on disk:
/// present and matching its recorded hash — exactly the integrity gate
/// `read_base64` applies before encoding. Used to decide whether a request
/// actually carries a sendable image (e.g. the file may have been deleted
/// before a resume). Quota and vision-header decisions go through this so a
/// tampered or truncated file cannot consume an image slot or trigger the
/// vision header only to resolve to a placeholder: it is treated as
/// unavailable and never sent.
pub fn exists(attachments_dir: &Path, attachment: &Attachment) -> bool {
    let Some(filename) = stored_filename(attachment) else { return false };
    let Ok(bytes) = std::fs::read(attachments_dir.join(filename)) else { return false };
    sha256_hex(&bytes) == attachment.sha256
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

    #[test]
    fn jpeg_composites_transparency_onto_white_not_black() {
        // A fully transparent pixel over black RGB: dropping alpha (`to_rgb8`)
        // would keep it black; compositing onto white must make it near-white.
        let mut rgba = image::RgbaImage::new(2, 1);
        rgba.put_pixel(0, 0, image::Rgba([0, 0, 0, 0])); // transparent, black RGB
        rgba.put_pixel(1, 0, image::Rgba([10, 20, 30, 255])); // opaque
        let img = image::DynamicImage::ImageRgba8(rgba);

        let flat = flatten_onto_white(&img);
        assert_eq!(flat.get_pixel(0, 0), &image::Rgb([255, 255, 255]), "transparent pixel must flatten to white");
        assert_eq!(flat.get_pixel(1, 0), &image::Rgb([10, 20, 30]), "opaque pixel must be unchanged");

        // The encoded JPEG must decode with the transparent region near white
        // (JPEG is lossy, so allow a small tolerance), never near black.
        let jpeg = encode_jpeg(&img).unwrap();
        let decoded = image::load_from_memory_with_format(&jpeg, image::ImageFormat::Jpeg).unwrap().to_rgb8();
        let p = decoded.get_pixel(0, 0);
        assert!(p[0] > 230 && p[1] > 230 && p[2] > 230, "transparent region must encode near white, got {p:?}");
    }

    #[test]
    fn jpeg_half_transparent_blends_toward_white() {
        // 50% alpha over black must land roughly mid-grey, not black.
        let mut rgba = image::RgbaImage::new(1, 1);
        rgba.put_pixel(0, 0, image::Rgba([0, 0, 0, 128]));
        let flat = flatten_onto_white(&image::DynamicImage::ImageRgba8(rgba));
        let p = flat.get_pixel(0, 0);
        assert!((120..=140).contains(&p[0]), "half-transparent black over white should be ~mid-grey, got {p:?}");
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
        assert_eq!(prepared.extension, "png");
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
        // The stored extension must track the re-encoded format, not the source,
        // so a JPEG payload is not written as `<sha>.gif`.
        assert_eq!(prepared.extension, "jpg");
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
        // Forced under the cap it falls back to JPEG, so both media type and
        // extension must report JPEG.
        assert_eq!(prepared.media_type, "image/jpeg");
        assert_eq!(prepared.extension, "jpg");
    }

    #[test]
    fn prepare_errors_when_minimum_size_still_exceeds_byte_cap() {
        // A byte cap so small that even the 16×16 floor cannot satisfy it must
        // fail, not return oversized bytes the provider would then reject.
        let bytes = make_png(64, 64);
        let err = prepare(&bytes, ImageFormat::Png, MAX_DIMENSION, 10, &[]).unwrap_err();
        assert!(err.to_string().contains("cannot be reduced"), "{err}");
    }

    #[test]
    fn prepare_respects_accepted_types_when_shrinking() {
        // A model accepting only PNG must not receive a JPEG re-encode when the
        // source (an oversized PNG) is shrunk — the output stays PNG.
        let mut img = image::RgbImage::new(2000, 2000);
        for (x, y, px) in img.enumerate_pixels_mut() {
            *px = image::Rgb([(x % 251) as u8, (y % 239) as u8, ((x * y) % 233) as u8]);
        }
        let mut out = std::io::Cursor::new(Vec::new());
        image::DynamicImage::ImageRgb8(img).write_to(&mut out, image::ImageFormat::Png).unwrap();
        let bytes = out.into_inner();
        let png_only = vec!["image/png".to_string()];
        let prepared = prepare(&bytes, ImageFormat::Png, MAX_DIMENSION, 50_000, &png_only).unwrap();
        assert!(prepared.bytes.len() <= 50_000, "{} bytes", prepared.bytes.len());
        assert_eq!(prepared.media_type, "image/png");
        assert_eq!(prepared.extension, "png");
        assert_eq!(ImageFormat::sniff(&prepared.bytes), Some(ImageFormat::Png));
    }

    #[test]
    fn prepare_reencodes_unaccepted_source_into_an_accepted_codec() {
        // A GIF where only PNG is accepted re-encodes to PNG (not JPEG).
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(20, 20, image::Rgb([1, 2, 3])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Gif).unwrap();
        let bytes = out.into_inner();
        let png_only = vec!["image/png".to_string()];
        let prepared = prepare(&bytes, ImageFormat::Gif, MAX_DIMENSION, DEFAULT_MAX_BYTES, &png_only).unwrap();
        assert_eq!(prepared.media_type, "image/png");
        assert_eq!(prepared.extension, "png");
        assert_eq!(ImageFormat::sniff(&prepared.bytes), Some(ImageFormat::Png));
    }

    #[test]
    fn prepare_errors_when_no_implemented_codec_is_accepted() {
        // A GIF where the model accepts only WebP: we cannot re-encode to an
        // accepted type (we emit only PNG/JPEG), so fail rather than send a GIF
        // or an unsupported JPEG.
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(20, 20, image::Rgb([1, 2, 3])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, image::ImageFormat::Gif).unwrap();
        let bytes = out.into_inner();
        let webp_only = vec!["image/webp".to_string()];
        let err = prepare(&bytes, ImageFormat::Gif, MAX_DIMENSION, DEFAULT_MAX_BYTES, &webp_only).unwrap_err();
        assert!(err.to_string().contains("re-encode"), "{err}");
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
        assert!(exists(dir.path(), &attachment));
        assert!(read_base64(dir.path(), &attachment).is_some());
        // A missing file reads as None (the resume fallback).
        std::fs::remove_file(&p1).unwrap();
        assert!(!exists(dir.path(), &attachment));
        assert_eq!(read_base64(dir.path(), &attachment), None);
        // Tampered bytes that don't match the hash are rejected.
        assert!(store(dir.path(), &attachment, b"other").is_err());
    }

    /// An attachment whose `sha256` / `extension` came from a crafted or
    /// corrupt session log and would escape the attachments directory.
    #[test]
    fn crafted_metadata_cannot_escape_the_attachments_dir() {
        let dir = tempfile::tempdir().unwrap();
        let bytes = make_png(10, 10);
        let good = sha256_hex(&bytes);
        let mut attachment = crate::llm::Attachment {
            media_type: "image/png".into(),
            path: std::path::PathBuf::from("/tmp/x.png"),
            sha256: good.clone(),
            width: 10,
            height: 10,
            bytes: bytes.len(),
            extension: "png".into(),
        };

        // A `sha256` that is not exactly 64 lowercase hex digits is rejected:
        // path traversal, separators, absolute paths, and wrong-length/uppercase
        // hashes alike. `store` refuses it; `read_base64`/`exists` treat it as
        // unavailable rather than joining it onto the directory.
        for bad in ["../escape", "/etc/passwd", "a/b", &good.to_uppercase(), "abc", &format!("{good}x")] {
            attachment.sha256 = bad.to_string();
            assert!(store(dir.path(), &attachment, &bytes).is_err(), "store sha256={bad:?}");
            assert_eq!(read_base64(dir.path(), &attachment), None, "read sha256={bad:?}");
            assert!(!exists(dir.path(), &attachment), "exists sha256={bad:?}");
        }

        // An `extension` outside the known image set is rejected the same way.
        attachment.sha256 = good.clone();
        for bad in ["../escape", "png/..", "exe", "PNG", ""] {
            attachment.extension = bad.to_string();
            assert!(store(dir.path(), &attachment, &bytes).is_err(), "store ext={bad:?}");
            assert_eq!(read_base64(dir.path(), &attachment), None, "read ext={bad:?}");
            assert!(!exists(dir.path(), &attachment), "exists ext={bad:?}");
        }
        // Nothing was written outside (or inside) the attachments dir.
        assert!(std::fs::read_dir(dir.path()).unwrap().next().is_none());
    }

    /// A stored file whose bytes no longer match the recorded hash is not sent.
    #[test]
    fn read_base64_rejects_a_tampered_stored_file() {
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
        let path = store(dir.path(), &attachment, &bytes).unwrap();
        assert!(read_base64(dir.path(), &attachment).is_some());
        // Overwrite the stored copy with different bytes; the hash no longer
        // matches, so the attachment reads as unavailable rather than sending
        // the swapped content to the provider.
        std::fs::write(&path, b"tampered").unwrap();
        assert_eq!(read_base64(dir.path(), &attachment), None);
    }

    /// Availability is the same integrity gate as `read_base64`: a tampered
    /// stored file reports as unavailable, so it can neither consume an image
    /// quota slot nor trigger the vision header only to resolve to a
    /// placeholder.
    #[test]
    fn exists_rejects_a_tampered_stored_file() {
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
        let path = store(dir.path(), &attachment, &bytes).unwrap();
        assert!(exists(dir.path(), &attachment));
        std::fs::write(&path, b"tampered").unwrap();
        assert!(!exists(dir.path(), &attachment));
        // Truncation is caught the same way.
        std::fs::write(&path, &bytes[..bytes.len() - 1]).unwrap();
        assert!(!exists(dir.path(), &attachment));
    }
}
