//! Camera frames to JPEG, entirely in memory.
//!
//! The in-app camera hands us raw frames from the preview stream (BGRA on iOS,
//! YUV 4:2:0 on Android) instead of letting the camera plugin write a JPEG to a
//! cache file: a plaintext temporary file is exactly what the vault must never
//! produce (`docs/requirements.md`, In-app camera). The JPEG we encode carries no
//! EXIF at all, so no location either.

// No unsafe Rust in the core: the compiler refuses it (docs/supply-chain.md).
#![forbid(unsafe_code)]

use image::codecs::jpeg::JpegEncoder;
use image::{imageops, ExtendedColorType, RgbImage};

/// JPEG quality for the stored photo and its preview.
const QUALITY: u8 = 90;
const THUMB_QUALITY: u8 = 80;
/// Longest side of the preview shown in the vault grid.
pub const THUMB_SIZE: u32 = 320;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("frame data does not match its size or format")]
    BadFrame,
    #[error("JPEG encoding failed: {0}")]
    Encode(#[from] image::ImageError),
}

pub type Result<T> = std::result::Result<T, Error>;

/// One plane of a camera frame as the platform delivers it.
pub struct Plane<'a> {
    pub bytes: &'a [u8],
    pub bytes_per_row: usize,
    /// Distance between neighbouring samples in a row (1 for planar, 2 for interleaved UV).
    pub bytes_per_pixel: usize,
}

pub enum Format {
    /// iOS: one plane, 4 bytes per pixel, B G R A.
    Bgra8888,
    /// Android: Y, U, V planes; U and V subsampled 2×2.
    Yuv420,
}

pub struct Frame<'a> {
    pub width: usize,
    pub height: usize,
    pub format: Format,
    pub planes: Vec<Plane<'a>>,
    /// Clockwise rotation (0, 90, 180, 270) that turns the sensor image upright.
    pub rotation: u32,
}

/// A finished photo: full JPEG plus a small JPEG preview.
pub struct Photo {
    pub jpeg: Vec<u8>,
    pub thumbnail: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// Convert, rotate upright and encode a frame.
pub fn encode(frame: &Frame<'_>) -> Result<Photo> {
    let rgb = match frame.format {
        Format::Bgra8888 => from_bgra(frame)?,
        Format::Yuv420 => from_yuv420(frame)?,
    };
    let rgb = match frame.rotation % 360 {
        90 => imageops::rotate90(&rgb),
        180 => imageops::rotate180(&rgb),
        270 => imageops::rotate270(&rgb),
        _ => rgb,
    };
    let (w, h) = rgb.dimensions();
    let jpeg = to_jpeg(&rgb, QUALITY)?;
    let (tw, th) = fit(w, h, THUMB_SIZE);
    let thumb = imageops::thumbnail(&rgb, tw, th);
    let thumbnail = to_jpeg(&thumb, THUMB_QUALITY)?;
    Ok(Photo {
        jpeg,
        thumbnail,
        width: w,
        height: h,
    })
}

fn to_jpeg(img: &RgbImage, quality: u8) -> Result<Vec<u8>> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality).encode(
        img.as_raw(),
        img.width(),
        img.height(),
        ExtendedColorType::Rgb8,
    )?;
    Ok(out)
}

fn fit(w: u32, h: u32, max: u32) -> (u32, u32) {
    if w <= max && h <= max {
        return (w.max(1), h.max(1));
    }
    if w >= h {
        (max, (h as u64 * max as u64 / w as u64).max(1) as u32)
    } else {
        ((w as u64 * max as u64 / h as u64).max(1) as u32, max)
    }
}

fn check(frame: &Frame<'_>, n: usize) -> Result<()> {
    if frame.width == 0 || frame.height == 0 || frame.planes.len() < n {
        return Err(Error::BadFrame);
    }
    Ok(())
}

/// Last byte index a plane must contain for `rows` rows of `row_bytes` bytes.
fn need(p: &Plane<'_>, rows: usize, row_bytes: usize) -> Result<()> {
    let last = (rows - 1)
        .checked_mul(p.bytes_per_row)
        .and_then(|v| v.checked_add(row_bytes))
        .ok_or(Error::BadFrame)?;
    if p.bytes.len() < last {
        return Err(Error::BadFrame);
    }
    Ok(())
}

fn from_bgra(frame: &Frame<'_>) -> Result<RgbImage> {
    check(frame, 1)?;
    let p = &frame.planes[0];
    need(p, frame.height, frame.width * 4)?;
    let mut img = RgbImage::new(frame.width as u32, frame.height as u32);
    for (y, row) in img.rows_mut().enumerate() {
        let src = &p.bytes[y * p.bytes_per_row..];
        for (x, px) in row.enumerate() {
            let i = x * 4;
            px.0 = [src[i + 2], src[i + 1], src[i]];
        }
    }
    Ok(img)
}

fn from_yuv420(frame: &Frame<'_>) -> Result<RgbImage> {
    check(frame, 3)?;
    let (yp, up, vp) = (&frame.planes[0], &frame.planes[1], &frame.planes[2]);
    let (cw, ch) = (frame.width.div_ceil(2), frame.height.div_ceil(2));
    need(yp, frame.height, frame.width)?;
    for c in [up, vp] {
        let step = c.bytes_per_pixel.max(1);
        need(c, ch, (cw - 1) * step + 1)?;
    }
    let mut img = RgbImage::new(frame.width as u32, frame.height as u32);
    for (y, row) in img.rows_mut().enumerate() {
        let yrow = &yp.bytes[y * yp.bytes_per_row..];
        let urow = &up.bytes[(y / 2) * up.bytes_per_row..];
        let vrow = &vp.bytes[(y / 2) * vp.bytes_per_row..];
        for (x, px) in row.enumerate() {
            let luma = yrow[x] as f32;
            let u = urow[(x / 2) * up.bytes_per_pixel.max(1)] as f32 - 128.0;
            let v = vrow[(x / 2) * vp.bytes_per_pixel.max(1)] as f32 - 128.0;
            // BT.601 full range, as Android cameras deliver.
            let r = luma + 1.402 * v;
            let g = luma - 0.344_136 * u - 0.714_136 * v;
            let b = luma + 1.772 * u;
            px.0 = [clamp(r), clamp(g), clamp(b)];
        }
    }
    Ok(img)
}

fn clamp(v: f32) -> u8 {
    v.round().clamp(0.0, 255.0) as u8
}

#[cfg(test)]
mod tests {
    use super::*;

    fn decode(jpeg: &[u8]) -> RgbImage {
        image::load_from_memory_with_format(jpeg, image::ImageFormat::Jpeg)
            .unwrap()
            .to_rgb8()
    }

    #[test]
    fn bgra_with_row_padding_rotates_upright() {
        // 4×2, padded rows; left half red, right half blue.
        let (w, h, stride) = (4usize, 2usize, 20usize);
        let mut bytes = vec![0u8; stride * h];
        for y in 0..h {
            for x in 0..w {
                let i = y * stride + x * 4;
                let (b, g, r) = if x < 2 { (0, 0, 255) } else { (255, 0, 0) };
                bytes[i..i + 4].copy_from_slice(&[b, g, r, 255]);
            }
        }
        let frame = Frame {
            width: w,
            height: h,
            format: Format::Bgra8888,
            planes: vec![Plane {
                bytes: &bytes,
                bytes_per_row: stride,
                bytes_per_pixel: 4,
            }],
            rotation: 90,
        };
        let photo = encode(&frame).unwrap();
        assert_eq!((photo.width, photo.height), (2, 4));
        let img = decode(&photo.jpeg);
        // After 90° clockwise, the left (red) half is on top.
        assert!(img.get_pixel(0, 0).0[0] > 150 && img.get_pixel(0, 0).0[2] < 100);
        assert!(img.get_pixel(1, 3).0[2] > 150 && img.get_pixel(1, 3).0[0] < 100);
    }

    #[test]
    fn yuv420_grey_and_interleaved_chroma() {
        let (w, h) = (6usize, 4usize);
        let y = vec![128u8; w * h];
        // Interleaved UV (pixel stride 2), neutral chroma → grey.
        let uv = vec![128u8; w * h / 2];
        let frame = Frame {
            width: w,
            height: h,
            format: Format::Yuv420,
            planes: vec![
                Plane {
                    bytes: &y,
                    bytes_per_row: w,
                    bytes_per_pixel: 1,
                },
                Plane {
                    bytes: &uv,
                    bytes_per_row: w,
                    bytes_per_pixel: 2,
                },
                Plane {
                    bytes: &uv[1..],
                    bytes_per_row: w,
                    bytes_per_pixel: 2,
                },
            ],
            rotation: 0,
        };
        let photo = encode(&frame).unwrap();
        let px = decode(&photo.jpeg).get_pixel(2, 2).0;
        assert!(px.iter().all(|&c| (120..=136).contains(&c)), "{px:?}");
    }

    #[test]
    fn no_exif_and_small_thumbnail() {
        let bytes = vec![200u8; 1280 * 720 * 4];
        let frame = Frame {
            width: 1280,
            height: 720,
            format: Format::Bgra8888,
            planes: vec![Plane {
                bytes: &bytes,
                bytes_per_row: 1280 * 4,
                bytes_per_pixel: 4,
            }],
            rotation: 90,
        };
        let photo = encode(&frame).unwrap();
        assert!(!photo.jpeg.windows(4).any(|w| w == b"Exif"));
        let t = decode(&photo.thumbnail);
        assert_eq!(t.width().max(t.height()), THUMB_SIZE);
        assert!(t.height() > t.width());
    }

    #[test]
    fn short_buffers_are_rejected_not_panicking() {
        let bytes = vec![0u8; 10];
        let frame = Frame {
            width: 100,
            height: 100,
            format: Format::Bgra8888,
            planes: vec![Plane {
                bytes: &bytes,
                bytes_per_row: 400,
                bytes_per_pixel: 4,
            }],
            rotation: 0,
        };
        assert!(matches!(encode(&frame), Err(Error::BadFrame)));
    }
}
