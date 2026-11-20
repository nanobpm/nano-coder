/// Image attachments for `read_file` (port of `attachment.rs`).
///
/// An image a vision model reads is prepared against the model's limits
/// (longest side, byte cap, accepted media types), stored once under the
/// session's `<id>.attachments/` directory as `<sha256>.<ext>`, and referenced
/// from the tool-result message. Request builders re-read the stored bytes
/// (hash-checked) and base64 them for the newest few images.
///
/// Rust decodes and re-encodes with the `image` crate. D has no image codec,
/// so dimensions and EXIF orientation are read from the file headers here.
/// Any image that must change (too large, or a type the model won't take) is
/// re-encoded by the platform tool: `sips` on macOS, ImageMagick elsewhere.
/// Without one, such an image fails with a clear error. Images already within
/// the limits are sent unchanged, as in Rust.
module nano.attachment;

@safe:
import nano.clock : stdTimeNow;

import nano.safeio : readBytes, readImmutableBytes;
import std.format : format;
import std.typecons : Nullable;
import std.algorithm : canFind;

/// Longest side a sent image is downscaled to (Anthropic's guidance).
enum uint MAX_DIMENSION = 1568;

/// Default cap on one image's encoded size (GitHub Copilot's `max_prompt_image_size`).
enum size_t DEFAULT_MAX_BYTES = 3 * 1024 * 1024;

/// An image format `read_file` recognises by magic bytes.
enum ImageFormat { png, jpeg, gif, webp }

/// The format these bytes start with, if we accept it.
Nullable!ImageFormat sniff(const(ubyte)[] b) pure
{
    Nullable!ImageFormat r;
    if (b.length >= 8 && b[0 .. 8] == cast(const(ubyte)[]) "\x89PNG\r\n\x1a\n") r = ImageFormat.png;
    else if (b.length >= 3 && b[0] == 0xff && b[1] == 0xd8 && b[2] == 0xff) r = ImageFormat.jpeg;
    else if (b.length >= 6 && (b[0 .. 6] == cast(const(ubyte)[]) "GIF87a" || b[0 .. 6] == cast(const(ubyte)[]) "GIF89a"))
        r = ImageFormat.gif;
    else if (b.length >= 12 && b[0 .. 4] == cast(const(ubyte)[]) "RIFF" && b[8 .. 12] == cast(const(ubyte)[]) "WEBP")
        r = ImageFormat.webp;
    return r;
}

string mediaType(ImageFormat f) pure nothrow
{
    final switch (f)
    {
        case ImageFormat.png: return "image/png";
        case ImageFormat.jpeg: return "image/jpeg";
        case ImageFormat.gif: return "image/gif";
        case ImageFormat.webp: return "image/webp";
    }
}

/// File extension of the stored copy.
string extension(ImageFormat f) pure nothrow
{
    final switch (f)
    {
        case ImageFormat.png: return "png";
        case ImageFormat.jpeg: return "jpg";
        case ImageFormat.gif: return "gif";
        case ImageFormat.webp: return "webp";
    }
}

/// Hex sha256 of `bytes` (lowercase); names the stored copy.
string sha256Hex(const(ubyte)[] bytes) pure
{
    import std.digest.sha : sha256Of;
    import std.digest : toHexString, LetterCase;
    return toHexString!(LetterCase.lower)(sha256Of(bytes)).idup;
}

private uint be16(const(ubyte)[] b, size_t i) pure { return (b[i] << 8) | b[i + 1]; }
private uint le16(const(ubyte)[] b, size_t i) pure { return b[i] | (b[i + 1] << 8); }
private uint be32(const(ubyte)[] b, size_t i) pure { return (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3]; }
private uint le24(const(ubyte)[] b, size_t i) pure { return b[i] | (b[i + 1] << 8) | (b[i + 2] << 16); }
private uint le32(const(ubyte)[] b, size_t i) pure { return le24(b, i) | (b[i + 3] << 24); }

/// The stored pixel dimensions, read from the header (no decode). Throws on
/// a truncated or malformed header.
uint[2] dimensions(const(ubyte)[] b)
{
    auto f = sniff(b);
    if (f.isNull) throw new Exception("not a recognised image");
    final switch (f.get)
    {
        case ImageFormat.png:
            if (b.length < 24 || b[12 .. 16] != cast(const(ubyte)[]) "IHDR") throw new Exception("truncated PNG header");
            return [be32(b, 16), be32(b, 20)];
        case ImageFormat.gif:
            if (b.length < 10) throw new Exception("truncated GIF header");
            return [le16(b, 6), le16(b, 8)];
        case ImageFormat.webp:
            return webpDimensions(b);
        case ImageFormat.jpeg:
            return jpegDimensions(b);
    }
}

private uint[2] webpDimensions(const(ubyte)[] b) pure
{
    if (b.length < 30) throw new Exception("truncated WebP header");
    auto chunk = (cast(const(char)[]) b[12 .. 16]).idup;
    if (chunk == "VP8X") return [le24(b, 24) + 1, le24(b, 27) + 1];
    if (chunk == "VP8L")
    {
        if (b[20] != 0x2f) throw new Exception("bad WebP lossless signature");
        auto v = le32(b, 21);
        return [(v & 0x3fff) + 1, ((v >> 14) & 0x3fff) + 1];
    }
    if (chunk == "VP8 ")
    {
        if (b[23] != 0x9d || b[24] != 0x01 || b[25] != 0x2a) throw new Exception("bad WebP frame header");
        return [le16(b, 26) & 0x3fff, le16(b, 28) & 0x3fff];
    }
    throw new Exception("unknown WebP chunk " ~ chunk);
}

/// Walk JPEG markers, calling `each(marker, segment)` for each segment
/// before the scan; stops when `each` returns true.
private void jpegSegments(const(ubyte)[] b, scope bool delegate(ubyte, const(ubyte)[]) @safe each)
{
    size_t i = 2;
    while (i + 4 <= b.length)
    {
        if (b[i] != 0xff) throw new Exception("bad JPEG marker");
        while (i < b.length && b[i] == 0xff) i++;
        if (i >= b.length) break;
        auto m = b[i++];
        if (m == 0xd8 || m == 0x01 || (m >= 0xd0 && m <= 0xd7)) continue;
        if (m == 0xd9 || m == 0xda) break;
        if (i + 2 > b.length) break;
        auto len = be16(b, i);
        if (len < 2 || i + len > b.length) throw new Exception("truncated JPEG segment");
        if (each(m, b[i + 2 .. i + len])) return;
        i += len;
    }
}

private uint[2] jpegDimensions(const(ubyte)[] b)
{
    uint[2] dims;
    bool found;
    jpegSegments(b, (ubyte m, const(ubyte)[] seg) {
        // SOFn: every C0..CF except DHT (C4), JPG (C8) and DAC (CC).
        if (m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc && seg.length >= 5)
        {
            dims = [be16(seg, 3), be16(seg, 1)];
            found = true;
            return true;
        }
        return false;
    });
    if (!found) throw new Exception("JPEG has no frame header");
    return dims;
}

/// The EXIF orientation (1..8) of a JPEG; 1 when absent or unreadable. Other
/// formats report 1. (Rust also reads WebP EXIF; D treats WebP as upright.)
uint exifOrientation(const(ubyte)[] b, ImageFormat f)
{
    if (f != ImageFormat.jpeg) return 1;
    uint result = 1;
    try jpegSegments(b, (ubyte m, const(ubyte)[] seg) {
        if (m != 0xe1 || seg.length < 14 || seg[0 .. 6] != cast(const(ubyte)[]) "Exif\0\0") return false;
        auto t = seg[6 .. $];
        bool le = t[0] == 'I';
        uint u16(size_t i) { return i + 2 <= t.length ? (le ? le16(t, i) : be16(t, i)) : 0; }
        uint u32(size_t i) { return i + 4 <= t.length ? (le ? le32(t, i) : be32(t, i)) : 0; }
        auto ifd = u32(4);
        auto n = u16(ifd);
        foreach (k; 0 .. n)
        {
            auto e = ifd + 2 + k * 12;
            if (e + 12 > t.length) break;
            if (u16(e) == 0x0112)
            {
                auto v = u16(e + 8);
                if (v >= 1 && v <= 8) result = v;
                break;
            }
        }
        return true;
    });
    catch (Exception) {} // a truncated or malformed JPEG: keep whatever was read so far
    return result;
}

/// Orientations 5..8 are quarter turns: display width and height swap.
bool swapsAxes(uint orientation) pure nothrow { return orientation >= 5 && orientation <= 8; }

/// `(w, h)` scaled so the longest side is `maxDim`, aspect preserved.
uint[2] scaledDimensions(uint w, uint h, uint maxDim) pure
{
    import std.math : round;
    auto longest = w > h ? w : h;
    if (longest <= maxDim) return [w, h];
    double scale = cast(double) maxDim / longest;
    uint nw = cast(uint) round(w * scale), nh = cast(uint) round(h * scale);
    return [nw < 1 ? 1 : nw, nh < 1 ? 1 : nh];
}

/// The per-model limits an image is prepared against.
struct ImageLimits
{
    uint maxDimension = MAX_DIMENSION;
    size_t maxBytes = DEFAULT_MAX_BYTES;
    /// Media types the model accepts; empty means any of ours.
    string[] acceptedMediaTypes;

    bool accepts(string mt) pure const
    {
        import std.algorithm : canFind;
        return !acceptedMediaTypes.length || acceptedMediaTypes.canFind(mt);
    }
}

/// An image attached to a message: a reference to the stored copy plus
/// metadata (the session log never holds pixels).
struct Attachment
{
    /// MIME type of the stored (prepared) bytes.
    string mediaType;
    /// The path the image was read from (display and re-`read_file`).
    string path;
    /// Hex sha256 of the stored bytes; names the stored file.
    string sha256;
    uint width, height;
    /// Byte size of the stored copy.
    size_t bytes;
    /// Extension of the stored copy (`png`, `jpg`, `gif`, `webp`).
    string extension;

    /// Stands in for the image where it is summarized away or not sent.
    string placeholder() pure const { return format("[image: %s, %s×%s]", path, width, height); }

    import std.json : JSONValue, JSONType;
    JSONValue toJSON() pure const
    {
        JSONValue j = ["media_type": mediaType, "path": path, "sha256": sha256, "extension": extension];
        j["width"] = width;
        j["height"] = height;
        j["bytes"] = bytes;
        return j;
    }

    static Attachment fromJSON(const JSONValue j) pure
    {
        Attachment a;
        string s(string k) { auto p = k in j.objectNoRef; return p && p.type == JSONType.string ? p.str : null; }
        ulong n(string k)
        {
            auto p = k in j.objectNoRef;
            if (p is null) return 0;
            if (p.type == JSONType.uinteger) return p.uinteger;
            if (p.type == JSONType.integer && p.integer > 0) return p.integer;
            return 0;
        }
        a.mediaType = s("media_type");
        a.path = s("path");
        a.sha256 = s("sha256");
        a.extension = s("extension");
        a.width = cast(uint) n("width");
        a.height = cast(uint) n("height");
        a.bytes = cast(size_t) n("bytes");
        return a;
    }
}

/// An image ready to store or send.
struct PreparedImage
{
    immutable(ubyte)[] bytes;
    string mediaType, extension;
    uint width, height;
}

/// Re-encodes `src` to `codec` (PNG or JPEG) with its longest side at most
/// `maxSide`, applying EXIF orientation and flattening onto white for JPEG.
/// Replaceable for tests.
alias Encoder = immutable(ubyte)[] delegate(const(ubyte)[] src, ImageFormat codec, uint maxSide) @safe;

/// The platform encoder: `sips` (macOS) or ImageMagick (`magick`/`convert`).
/// Null when none is available.
Encoder platformEncoder()
{
    import std.file : exists;
    import std.process : environment;
    import std.path : buildPath, pathSeparator;
    import std.algorithm : splitter;
    version (OSX)
        if (exists("/usr/bin/sips"))
            return (const(ubyte)[] src, ImageFormat codec, uint maxSide) => sipsEncode(src, codec, maxSide);
    foreach (name; ["magick", "convert"])
        foreach (dir; environment.get("PATH", "").splitter(pathSeparator))
            if (dir.length && exists(buildPath(dir, name)))
            {
                auto tool = buildPath(dir, name);
                return (const(ubyte)[] src, ImageFormat codec, uint maxSide) => magickEncode(tool, src, codec, maxSide);
            }
    return null;
}

private immutable(ubyte)[] runEncoder(const(ubyte)[] src, ImageFormat codec,
        string[] delegate(string input, string output) @safe argv)
{
    import std.file : write, read, remove, exists, tempDir;
    import std.path : buildPath;
    import std.process : execute, thisProcessID;
    import std.datetime.systime : Clock;
    import core.atomic : atomicOp;
    static shared ulong counter;
    auto stem = buildPath(tempDir, format("nano-coder-img-%s-%s-%s", thisProcessID,
            stdTimeNow, atomicOp!"+="(counter, 1)));
    auto input = stem ~ ".in", output = stem ~ "." ~ codec.extension;
    scope (exit)
    {
        if (exists(input)) remove(input);
        if (exists(output)) remove(output);
    }
    write(input, src);
    auto r = execute(argv(input, output));
    if (r.status != 0 || !exists(output))
        throw new Exception(format("image re-encode failed: %s", r.output.length > 200 ? r.output[0 .. 200] : r.output));
    return readImmutableBytes(output);
}

private immutable(ubyte)[] sipsEncode(const(ubyte)[] src, ImageFormat codec, uint maxSide) @safe
{
    // sips keeps EXIF orientation as metadata rather than rotating, so a
    // quarter-turned photo keeps its tag (viewers still display it upright).
    return runEncoder(src, codec, (string i, string o) => ["/usr/bin/sips", "-s", "format",
        codec == ImageFormat.jpeg ? "jpeg" : "png"] ~ (codec == ImageFormat.jpeg ? ["-s", "formatOptions", "85"] : [])
        ~ ["-Z", format("%s", maxSide), i, "--out", o]);
}

private immutable(ubyte)[] magickEncode(string tool, const(ubyte)[] src, ImageFormat codec, uint maxSide) @safe
{
    auto size = format("%sx%s>", maxSide, maxSide);
    return runEncoder(src, codec, (string i, string o) => [tool, i ~ "[0]", "-auto-orient", "-resize", size]
        ~ (codec == ImageFormat.jpeg ? ["-background", "white", "-alpha", "remove", "-quality", "85"] : [])
        ~ [o]);
}

/// Prepare `bytes` for a model: keep them when they are an accepted type
/// within `limits`, else downscale/re-encode (JPEG, then PNG) until they fit.
/// Fails clearly when no accepted codec can be produced, the cap can't be
/// met, or no encoder is available.
PreparedImage prepare(const(ubyte)[] bytes, ImageFormat fmt, const ref ImageLimits limits, Encoder encode = null)
{
    auto d = dimensions(bytes);
    uint width = d[0], height = d[1];
    if (swapsAxes(exifOrientation(bytes, fmt))) { auto t = width; width = height; height = t; }
    bool acceptsSource = limits.accepts(fmt.mediaType);
    ImageFormat shrink;
    if (limits.accepts(ImageFormat.jpeg.mediaType)) shrink = ImageFormat.jpeg;
    else if (limits.accepts(ImageFormat.png.mediaType)) shrink = ImageFormat.png;
    else if (acceptsSource) shrink = fmt;
    else
        throw new Exception(format("image is %s, but the model accepts only %s and this build can re-encode only to PNG or JPEG",
            fmt.mediaType, limits.acceptedMediaTypes));
    auto maxDim = limits.maxDimension;
    if (acceptsSource && width <= maxDim && height <= maxDim && bytes.length <= limits.maxBytes)
        return PreparedImage(bytes.idup, fmt.mediaType, fmt.extension, width, height);

    if (encode is null) encode = platformEncoder();
    if (encode is null)
        throw new Exception("the image needs resizing or re-encoding, and no image tool was found (install ImageMagick)");
    // This build re-encodes only to PNG or JPEG: a GIF/WebP source that must
    // change goes straight to the shrink codec.
    auto codec = acceptsSource && (fmt == ImageFormat.png || fmt == ImageFormat.jpeg) ? fmt : shrink;
    if (codec != ImageFormat.png && codec != ImageFormat.jpeg)
        throw new Exception(format("image is %s and must shrink, but this build can re-encode only to PNG or JPEG", fmt.mediaType));
    uint target = scaledLongest(width, height, maxDim);
    for (;;)
    {
        auto out_ = encode(bytes, codec, target);
        auto od = dimensions(out_);
        auto orient = exifOrientation(out_, codec);
        uint w = od[0], h = od[1];
        if (swapsAxes(orient)) { auto t = w; w = h; h = t; }
        if (out_.length <= limits.maxBytes)
            return PreparedImage(out_, codec.mediaType, codec.extension, w, h);
        if (codec != shrink) { codec = shrink; continue; }
        if (w <= 16 && h <= 16)
            throw new Exception(format("image cannot be reduced under the %s-byte limit even at %s×%s; "
                ~ "the model's image size limit is too small for this image", limits.maxBytes, w, h));
        auto longest = w > h ? w : h;
        target = longest * 3 / 4 < 16 ? 16 : longest * 3 / 4;
    }
}

private uint scaledLongest(uint w, uint h, uint maxDim) pure
{
    auto s = scaledDimensions(w, h, maxDim);
    return s[0] > s[1] ? s[0] : s[1];
}

/// `<sha256>.<ext>`, or null when either field isn't the shape the writer
/// produces: the metadata comes from a session log, and a crafted `../`
/// must not read or write outside the attachments directory.
string storedFilename(const ref Attachment a) pure
{
    import std.algorithm : all, canFind;
    import std.ascii : isDigit;
    bool validSha = a.sha256.length == 64 && a.sha256.all!(c => c.isDigit || (c >= 'a' && c <= 'f'));
    bool validExt = ["png", "jpg", "gif", "webp"].canFind(a.extension);
    return validSha && validExt ? a.sha256 ~ "." ~ a.extension : null;
}

/// Store prepared bytes under `dir` by hash (reusing an intact copy,
/// repairing a corrupt one atomically). Returns the path.
string store(string dir, const ref Attachment a, const(ubyte)[] bytes)
{
    import std.file : mkdirRecurse, read, write, rename, exists, remove;
    import std.path : buildPath;
    import std.process : thisProcessID;
    import std.datetime.systime : Clock;
    if (sha256Hex(bytes) != a.sha256) throw new Exception("attachment bytes do not match their recorded hash");
    auto name = storedFilename(a);
    if (name is null) throw new Exception("attachment metadata fails validation");
    mkdirRecurse(dir);
    auto path = buildPath(dir, name);
    bool intact;
    try intact = exists(path) && sha256Hex(readBytes(path)) == a.sha256;
    catch (Exception) {} // a missing or unreadable copy counts as not intact and is rewritten below
    if (!intact)
    {
        auto tmp = buildPath(dir, format(".tmp-%s-%s", thisProcessID, stdTimeNow));
        scope (failure) if (exists(tmp)) remove(tmp);
        write(tmp, bytes);
        rename(tmp, path);
    }
    return path;
}

/// The stored bytes when present and hash-intact, else null.
private immutable(ubyte)[] readIntact(string dir, const ref Attachment a)
{
    import std.file : read;
    import std.path : buildPath;
    auto name = storedFilename(a);
    if (name is null || !dir.length) return null;
    try
    {
        auto b = readImmutableBytes(buildPath(dir, name));
        return sha256Hex(b) == a.sha256 ? b : null;
    }
    catch (Exception) return null; // missing, unreadable or changed on disk: the caller treats null as gone
}

/// Whether the stored copy is present and intact (the gate before sending).
bool exists(string dir, const ref Attachment a) { return readIntact(dir, a) !is null; }

/// An image on the wire: base64 data and the media type of those bytes.
struct ImageData { string mediaType, dataBase64; }

/// The stored bytes, made to fit the *active* model's limits: unchanged
/// when they already do (checked from the verified bytes, not the log's
/// metadata), else re-prepared. Null when missing, tampered or unfixable.
Nullable!ImageData readForLimits(string dir, const ref Attachment a, const ref ImageLimits limits, Encoder encode = null)
{
    import std.base64 : Base64;
    Nullable!ImageData none;
    auto bytes = readIntact(dir, a);
    if (bytes is null) return none;
    auto f = sniff(bytes);
    if (f.isNull) return none;
    try
    {
        auto d = dimensions(bytes);
        if (limits.accepts(f.get.mediaType) && bytes.length <= limits.maxBytes
                && d[0] <= limits.maxDimension && d[1] <= limits.maxDimension)
            return Nullable!ImageData(ImageData(f.get.mediaType, Base64.encode(bytes).idup));
        auto p = prepare(bytes, f.get, limits, encode);
        return Nullable!ImageData(ImageData(p.mediaType, Base64.encode(p.bytes).idup));
    }
    catch (Exception) return none; // unreadable or undecodable image: the caller skips it
}

version (unittest)
{
    /// A PNG header claiming `w`×`h`, padded to `size` bytes.
    immutable(ubyte)[] fakePng(uint w, uint h, size_t size = 64) pure
    {
        ubyte[] b = cast(ubyte[]) "\x89PNG\r\n\x1a\n\0\0\0\x0dIHDR".dup;
        foreach (v; [w, h]) b ~= [cast(ubyte)(v >> 24), cast(ubyte)(v >> 16), cast(ubyte)(v >> 8), cast(ubyte) v];
        while (b.length < size) b ~= 0;
        return b.idup;
    }

    /// A JPEG with an optional EXIF orientation and a SOF0 of `w`×`h`.
    immutable(ubyte)[] fakeJpeg(uint w, uint h, uint orientation = 0) pure
    {
        ubyte[] b = [0xff, 0xd8];
        if (orientation)
        {
            // APP1: "Exif\0\0" + big-endian TIFF, IFD0 at 8 with one entry.
            ubyte[] t = cast(ubyte[]) "MM\0\x2a\0\0\0\x08".dup;
            t ~= cast(ubyte[]) [0, 1, 0x01, 0x12, 0, 3, 0, 0, 0, 1, 0, orientation, 0, 0, 0, 0, 0, 0];
            ubyte[] seg = cast(ubyte[]) "Exif\0\0".dup ~ t;
            auto len = seg.length + 2;
            b ~= cast(ubyte[]) [0xff, 0xe1, len >> 8, len & 0xff];
            b ~= seg;
        }
        b ~= [0xff, 0xc0, 0, 11, 8, cast(ubyte)(h >> 8), cast(ubyte) h, cast(ubyte)(w >> 8), cast(ubyte) w, 1, 1, 0x11, 0];
        b ~= [0xff, 0xda, 0, 2, 0xff, 0xd9];
        return b.idup;
    }
}

// rust: attachment.rs::scaled_dimensions_preserve_aspect_and_cap
// rust: attachment.rs::sha256_is_stable
// rust: attachment.rs::sniffs_formats_by_magic_bytes
unittest
{
    assert(sniff(fakePng(1, 1)).get == ImageFormat.png);
    assert(sniff(fakeJpeg(1, 1)).get == ImageFormat.jpeg);
    assert(sniff(cast(const(ubyte)[]) "GIF89a\x05\0\x07\0").get == ImageFormat.gif);
    assert(sniff(cast(const(ubyte)[]) "hello").isNull);
    assert(dimensions(fakePng(640, 480)) == [640, 480]);
    assert(dimensions(cast(const(ubyte)[]) "GIF89a\x05\0\x07\0") == [5, 7]);
    assert(dimensions(fakeJpeg(300, 200)) == [300, 200]);
    // WebP extended: 24-bit width-1 / height-1 at 24 and 27.
    ubyte[] webp = cast(ubyte[]) "RIFF\0\0\0\0WEBPVP8X\x0a\0\0\0\0\0\0\0".dup;
    webp ~= cast(ubyte[]) [99, 0, 0, 49, 0, 0];
    assert(dimensions(webp) == [100, 50]);
    assert(exifOrientation(fakeJpeg(300, 200, 6), ImageFormat.jpeg) == 6);
    assert(exifOrientation(fakeJpeg(300, 200), ImageFormat.jpeg) == 1);
    assert(sha256Hex(cast(const(ubyte)[]) "abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    assert(scaledDimensions(3000, 1500, 1568) == [1568, 784]);
}

// rust: attachment.rs::prepare_errors_when_minimum_size_still_exceeds_byte_cap
// rust: attachment.rs::prepare_errors_when_no_implemented_codec_is_accepted
// rust: attachment.rs::prepare_reencodes_unaccepted_source_into_an_accepted_codec
// rust: attachment.rs::prepare_shrinks_until_under_byte_cap
// rust: attachment.rs::prepare_downscales_oversized_images
// rust: attachment.rs::prepare_reports_oriented_dimensions_on_passthrough_path
// rust: attachment.rs::prepare_keeps_small_images_unchanged
unittest
{
    // Passthrough keeps the bytes; a quarter-turn EXIF reports display size.
    ImageLimits lim;
    auto png = fakePng(100, 50);
    auto p = prepare(png, ImageFormat.png, lim, null);
    assert(p.bytes == png && p.width == 100 && p.mediaType == "image/png");
    auto rotated = prepare(fakeJpeg(300, 200, 6), ImageFormat.jpeg, lim, null);
    assert(rotated.width == 200 && rotated.height == 300);

    // Too large: the encoder is asked for the capped size, then shrinks
    // by quarters until the byte cap fits.
    uint[] asked;
    Encoder enc = (const(ubyte)[] src, ImageFormat codec, uint side) @safe {
        asked ~= side;
        return codec == ImageFormat.png ? fakePng(side, side / 2, side * 10) : fakeJpeg(side, side / 2);
    };
    ImageLimits small = {maxDimension: 1000, maxBytes: 8000, acceptedMediaTypes: ["image/png"]};
    auto big = prepare(fakePng(4000, 2000), ImageFormat.png, small, enc);
    assert(asked == [1000, 750], format("%s", asked));
    assert(big.width == 750 && big.bytes.length <= 8000);

    // An unaccepted source goes to JPEG when JPEG is accepted.
    ImageLimits jpegOnly = {acceptedMediaTypes: ["image/jpeg"]};
    auto j = prepare(fakePng(10, 10), ImageFormat.png, jpegOnly, enc);
    assert(j.mediaType == "image/jpeg" && j.extension == "jpg");

    // No codec we can emit, or nothing to emit it with.
    ImageLimits gifOnly = {acceptedMediaTypes: ["image/gif"]};
    bool threw;
    try prepare(fakePng(10, 10), ImageFormat.png, gifOnly, enc);
    catch (Exception e) threw = e.msg.canFind("re-encode only to PNG or JPEG");
    assert(threw);
    // The unmeetable byte cap fails rather than looping.
    ImageLimits tiny = {maxBytes: 10};
    threw = false;
    try prepare(fakePng(100, 100, 100), ImageFormat.png, tiny, enc);
    catch (Exception e) threw = e.msg.canFind("cannot be reduced");
    assert(threw);
}

// rust: attachment.rs::read_for_limits_passes_compliant_bytes_through
// rust: attachment.rs::read_for_limits_rejects_missing_and_tampered_files
// rust: attachment.rs::crafted_metadata_cannot_escape_the_attachments_dir
// rust: attachment.rs::store_repairs_a_corrupt_existing_file
// rust: attachment.rs::exists_rejects_a_tampered_stored_file
// rust: attachment.rs::store_and_read_round_trip_and_dedupe
unittest
{
    import std.file : tempDir, rmdirRecurse, write, exists_ = exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-att-test-%s", thisProcessID));
    scope (exit) if (exists_(dir)) rmdirRecurse(dir);
    auto png = fakePng(20, 10);
    Attachment a = {mediaType: "image/png", path: "/x.png", sha256: sha256Hex(png), width: 20, height: 10,
        bytes: png.length, extension: "png"};
    assert(!exists(dir, a));
    auto path = store(dir, a, png);
    assert(exists(dir, a));
    ImageLimits lim;
    auto ready = readForLimits(dir, a, lim);
    assert(!ready.isNull && ready.get.mediaType == "image/png");
    // Tampered copies are unavailable, and store repairs them.
    write(path, "garbage");
    assert(!exists(dir, a) && readForLimits(dir, a, lim).isNull);
    store(dir, a, png);
    assert(exists(dir, a));
    // Crafted metadata can't escape the directory.
    auto evil = a;
    evil.extension = "../x";
    assert(storedFilename(evil) is null && !exists(dir, evil));
    // JSON round trip (Rust's field names).
    assert(Attachment.fromJSON(a.toJSON) == a);
    assert(a.placeholder == "[image: /x.png, 20×10]");
}

// rust: attachment.rs::prepare_reencodes_when_type_not_accepted
// rust: attachment.rs::prepare_respects_accepted_types_when_shrinking
// rust: attachment.rs::prepare_preserves_narrow_aspect_ratio_while_shrinking
unittest
{
    // A stand-in encoder that scales like sips -Z / magick -resize: the
    // longest side becomes `side`, the short side follows the aspect ratio.
    uint srcW, srcH;
    Encoder enc = (const(ubyte)[] src, ImageFormat codec, uint side) @safe {
        uint w = srcW >= srcH ? side : cast(uint)(cast(ulong) srcW * side / srcH);
        uint h = srcW >= srcH ? cast(uint)(cast(ulong) srcH * side / srcW) : side;
        if (w == 0) w = 1;
        if (h == 0) h = 1;
        auto size = cast(size_t) w * h / 4 + 64;
        return codec == ImageFormat.png ? fakePng(w, h, size) : fakeJpeg(w, h) ~ new immutable(ubyte)[](size);
    };
    // GIF to a JPEG/PNG model: re-encoded as JPEG, stored as .jpg.
    srcW = 20; srcH = 20;
    auto gif = cast(immutable(ubyte)[]) "GIF89a\x14\0\x14\0";
    ImageLimits jp = {acceptedMediaTypes: ["image/jpeg", "image/png"]};
    auto g = prepare(gif, ImageFormat.gif, jp, enc);
    assert(g.mediaType == "image/jpeg" && g.extension == "jpg" && sniff(g.bytes).get == ImageFormat.jpeg);
    // A PNG-only model never gets a JPEG while shrinking.
    srcW = 2000; srcH = 2000;
    ImageLimits pngOnly = {acceptedMediaTypes: ["image/png"], maxBytes: 50_000};
    auto p = prepare(fakePng(2000, 2000, 4_000_000), ImageFormat.png, pngOnly, enc);
    assert(p.bytes.length <= 50_000 && p.mediaType == "image/png" && p.extension == "png");
    assert(sniff(p.bytes).get == ImageFormat.png);
    // A 100:1 panorama shrinks along its longest side; the short side
    // follows the ratio below 16 instead of being pinned there.
    srcW = 2400; srcH = 24;
    ImageLimits capped = {maxBytes: 4_000, acceptedMediaTypes: ["image/png"]};
    auto pan = prepare(fakePng(2400, 24, 100_000), ImageFormat.png, capped, enc);
    assert(pan.bytes.length <= 4_000 && pan.height < 16, format("%s×%s", pan.width, pan.height));
    assert(cast(double) pan.width / pan.height > 60);
}

// rust: attachment.rs::read_base64_rejects_a_tampered_stored_file
// rust: attachment.rs::read_for_limits_ignores_lying_stored_dimensions
// rust: attachment.rs::read_for_limits_omits_when_limits_cannot_be_met
// rust: attachment.rs::read_for_limits_reencodes_for_a_stricter_media_type
unittest
{
    import std.base64 : Base64;
    import std.file : tempDir, rmdirRecurse, write, exists_ = exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-att-limits-%s", thisProcessID));
    scope (exit) if (exists_(dir)) rmdirRecurse(dir);
    Attachment stored(immutable(ubyte)[] b, string ext, string media)
    {
        Attachment a = {mediaType: media, path: "/x." ~ ext, sha256: sha256Hex(b), bytes: b.length, extension: ext};
        store(dir, a, b);
        return a;
    }
    Encoder enc = (const(ubyte)[] src, ImageFormat codec, uint side) @safe =>
        codec == ImageFormat.png ? fakePng(side, side, 200) : fakeJpeg(side, side);
    ImageLimits lim;

    // The log lies that a 2000×2000 image is 10×10: the real size decides.
    auto big = stored(fakePng(2000, 2000), "png", "image/png");
    big.width = 10;
    big.height = 10;
    auto ready = readForLimits(dir, big, lim, enc);
    assert(!ready.isNull);
    auto sent = dimensions(Base64.decode(ready.get.dataBase64));
    assert(sent[0] == MAX_DIMENSION && sent[1] == MAX_DIMENSION, format("%s", sent));

    // A cap no re-encode can meet omits the image.
    auto small = stored(fakePng(64, 64, 300), "png", "image/png");
    ImageLimits tiny = {maxBytes: 10};
    assert(readForLimits(dir, small, tiny, enc).isNull);

    // A stricter media type re-encodes GIF into the accepted PNG.
    auto gif = stored(cast(immutable(ubyte)[]) "GIF89a\x14\0\x14\0", "gif", "image/gif");
    ImageLimits pngOnly = {acceptedMediaTypes: ["image/png"]};
    auto r = readForLimits(dir, gif, pngOnly, enc);
    assert(!r.isNull && r.get.mediaType == "image/png" && sniff(Base64.decode(r.get.dataBase64)).get == ImageFormat.png);

    // A swapped stored copy reads as unavailable, not as the new bytes.
    write(buildPath(dir, storedFilename(small)), "tampered");
    assert(readForLimits(dir, small, lim, enc).isNull);
}
