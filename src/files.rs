//! File tools: `read_file`, `write_file`, `edit_file`.
//!
//! Relative paths resolve against the process working directory, which ACP
//! `session/new` sets from `params.cwd`.

use std::collections::HashMap;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use anyhow::{Context, Result, anyhow, bail};
use serde_json::{Value, json};

use crate::output;
use crate::tools::{ToolDefinition, ToolRegistry};

const DEFAULT_READ_LINES: usize = 2000;
const MAX_LINE_CHARS: usize = 2000;
const MAX_READ_BYTES: usize = 100_000;

/// Content hashes of files as the model last saw them: recorded by
/// `read_file` and by this module's own writes. `edit_file`, and `write_file`
/// over an existing file, refuse to write unless the file on disk still
/// matches, so an edit planned against text that has since changed (a `bash`
/// command, a formatter, the user in their editor) can't land on the wrong
/// code. Keyed by canonical path so symlinks and relative paths agree.
static SEEN: LazyLock<Mutex<HashMap<PathBuf, u64>>> = LazyLock::new(Default::default);

fn seen_key(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).or_else(|_| std::path::absolute(path)).unwrap_or_else(|_| path.to_path_buf())
}

fn digest(bytes: &[u8]) -> u64 {
    let mut hasher = DefaultHasher::new();
    bytes.hash(&mut hasher);
    hasher.finish()
}

fn remember(path: &Path, bytes: &[u8]) {
    SEEN.lock().unwrap_or_else(|e| e.into_inner()).insert(seen_key(path), digest(bytes));
}

/// Record a successful image read in the freshness cache, so a later
/// `write_file`/`edit_file` on the same path passes the "has not been read yet"
/// check — exactly as a successful text read does via [`read_file`].
///
/// `read_file` cannot record this itself: it returns image *metadata* before
/// the dispatch layer knows whether the model can actually view the image. The
/// caller invokes this only once the image has truly been delivered to the
/// model (vision enabled and the attachment prepared and stored); the no-vision
/// error path returns earlier and so never authorizes a write for an image the
/// model never saw.
pub fn mark_image_read(path: &Path, bytes: &[u8]) {
    remember(path, bytes);
}

/// Fail unless `current` (the file's bytes on disk) is what the model last saw.
fn check_fresh(path: &Path, current: &[u8]) -> Result<()> {
    let seen = SEEN.lock().unwrap_or_else(|e| e.into_inner()).get(&seen_key(path)).copied();
    match seen {
        None => bail!("{} has not been read yet; read it with read_file before changing it", path.display()),
        Some(hash) if hash != digest(current) => bail!(
            "{} has changed since it was last read (by a command, a tool or the user); read it again before changing it",
            path.display()
        ),
        Some(_) => Ok(()),
    }
}

fn string_arg<'a>(args: &'a Value, name: &str) -> Result<&'a str> {
    // A malformed-arguments failure means the model's JSON never decoded; the
    // dispatch loop rejects these calls before any tool runs (via
    // `ToolCall::raw_arguments_error`), so by the time a handler sees
    // `arguments` it is always well-formed JSON.
    match args.get(name) {
        None => bail!("missing required argument {name:?}"),
        Some(Value::Null) => bail!("argument {name:?} is null; provide a string value"),
        Some(value) => {
            value.as_str().ok_or_else(|| anyhow!("argument {name:?} must be a string, got {}", type_name(value)))
        }
    }
}

fn type_name(value: &Value) -> &'static str {
    match value {
        Value::Null => "null",
        Value::Bool(_) => "a boolean",
        Value::Number(_) => "a number",
        Value::String(_) => "a string",
        Value::Array(_) => "an array",
        Value::Object(_) => "an object",
    }
}

fn path_arg(args: &Value) -> Result<PathBuf> {
    let path = string_arg(args, "path")?;
    if path.trim().is_empty() {
        bail!("path must not be empty");
    }
    Ok(PathBuf::from(path))
}

fn count_arg(args: &Value, name: &str) -> Result<Option<usize>> {
    match args.get(name) {
        None | Some(Value::Null) => Ok(None),
        Some(value) => value
            .as_u64()
            .filter(|n| *n >= 1)
            .map(|n| Some(n as usize))
            .ok_or_else(|| anyhow!("{name} must be a positive integer")),
    }
}

/// Numbered lines `offset..offset+limit` (1-based) of a text file.
///
/// An image (PNG, JPEG, GIF or WebP, recognised by magic bytes) returns a
/// structured [`Value`] object instead of text: `{ "image": { media_type,
/// extension, path, width, height, bytes } }` — the metadata only, never the
/// pixels. The dispatch loop re-reads the file by path to downscale it, then
/// turns that into a message attachment when the model can view images, or a
/// text error when it cannot. Other binary files keep the "looks like a binary
/// file" error.
pub fn read_file(args: &Value) -> Result<Value> {
    let path = path_arg(args)?;
    let offset = count_arg(args, "offset")?.unwrap_or(1);
    let limit = count_arg(args, "limit")?.unwrap_or(DEFAULT_READ_LINES);
    let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    if let Some(format) = crate::attachment::ImageFormat::sniff(&bytes) {
        return read_image(&path, &bytes, format);
    }
    if bytes.iter().take(8192).any(|b| *b == 0) {
        bail!("{} looks like a binary file ({} bytes)", path.display(), bytes.len());
    }
    let text = String::from_utf8_lossy(&bytes);
    let total = text.lines().count();
    if total == 0 {
        remember(&path, &bytes);
        return Ok(Value::String(format!("({} is empty)", path.display())));
    }
    if offset > total {
        bail!("offset {offset} is past the end of {} ({total} lines)", path.display());
    }
    // Record the hash only once the read has succeeded, so a failed
    // out-of-range read can't authorize a later edit the model never saw.
    remember(&path, &bytes);
    let mut out = String::new();
    for (index, line) in text.lines().enumerate().skip(offset - 1).take(limit) {
        let line = if line.chars().count() > MAX_LINE_CHARS {
            format!("{}... [line truncated]", line.chars().take(MAX_LINE_CHARS).collect::<String>())
        } else {
            line.to_string()
        };
        out.push_str(&format!("{:>6}\t{line}\n", index + 1));
    }
    let last = (offset - 1 + limit).min(total);
    if last < total {
        out.push_str(&format!("[showing lines {offset}-{last} of {total}; use offset={} to continue]\n", last + 1));
    }
    Ok(Value::String(output::bound_output(&out, MAX_READ_BYTES).0))
}

/// Build the structured result for an image: its metadata only (never the
/// pixel bytes). Base64-encoding the whole source here would create an
/// unbounded transient allocation — several times the file size once the
/// dispatch loop clones it for the `AfterToolCall` hook and decodes it back —
/// before the model's byte/dimension limits are ever applied, so a large
/// image could OOM even though it would end up well under the provider cap.
/// The dispatch loop instead re-reads the file by `path` and applies `prepare`
/// (which knows the model's capability) before any base64 encoding; here we
/// only decode dimensions.
fn read_image(path: &Path, bytes: &[u8], format: crate::attachment::ImageFormat) -> Result<Value> {
    let (width, height) = image_dimensions(bytes)?;
    // Persist an absolute source path so the advertised re-`read_file` workflow
    // survives a session resume under a different working directory (ACP
    // `session/load` accepts a new cwd, and CLI resume does not restore the
    // recorded one). Resolve it against the still-active cwd now; `absolute` is
    // lexical (no filesystem access), so it never fails for a path we just read.
    let path = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    Ok(json!({
        "image": {
            "media_type": format.media_type(),
            "extension": format.extension(),
            "path": path,
            "width": width,
            "height": height,
            "bytes": bytes.len(),
        }
    }))
}

/// Decode an image's pixel dimensions.
fn image_dimensions(bytes: &[u8]) -> Result<(u32, u32)> {
    let reader =
        image::ImageReader::new(std::io::Cursor::new(bytes)).with_guessed_format().context("guess image format")?;
    reader.into_dimensions().context("read image dimensions")
}

/// What the caller expected the target to be when the write was planned. The
/// rename is validated against this immediately before committing so a change
/// that races the write fails instead of being silently clobbered.
enum Expect<'a> {
    /// The target did not exist at plan time; the rename must not overwrite a
    /// file that appeared in the meantime (a concurrent create).
    Absent,
    /// The target existed with exactly these bytes at plan time.
    Bytes(&'a [u8]),
}

/// Write `content` to `path` via a temp file + rename, re-validating `expect`
/// immediately before the rename: the earlier check at read time leaves a window
/// in which an editor or formatter can change the file (`Expect::Bytes`), or
/// another process can create a not-yet-existing one (`Expect::Absent`), and the
/// rename would then clobber that newer content. Re-checking right before
/// committing shrinks the window to the rename itself so a mid-call change fails
/// instead of being lost. (A change in the remaining micro-window is still
/// possible; fully closing it needs OS-level compare-and-swap/locking, which this
/// does not attempt.) The temp file is removed on every pre-rename error path so
/// the proposed contents never leak under its predictable name.
fn write_atomically(path: &Path, content: &str, expect: Expect<'_>) -> Result<()> {
    // Write through symlinks: renaming onto the link would replace it with a file.
    let resolved;
    let path = if path.symlink_metadata().is_ok_and(|m| m.file_type().is_symlink()) {
        resolved = std::fs::canonicalize(path).with_context(|| format!("resolve symlink {}", path.display()))?;
        resolved.as_path()
    } else {
        path
    };
    if let Some(parent) = path.parent().filter(|p| !p.as_os_str().is_empty()) {
        std::fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let name = path.file_name().ok_or_else(|| anyhow!("{} is not a file path", path.display()))?;
    let tmp = path.with_file_name(format!(".{}.tmp-{}", name.to_string_lossy(), std::process::id()));
    // A partial write (e.g. `ENOSPC`) can create the temp file and still fail, so
    // remove it on the write-error path too — every exit that has touched `tmp`
    // must clean it up, not just the pre-rename validation below.
    if let Err(e) = std::fs::write(&tmp, content) {
        std::fs::remove_file(&tmp).ok();
        return Err(e).with_context(|| format!("write {}", tmp.display()));
    }
    // Once the temp file exists, every exit before a successful rename must remove
    // it. Do the pre-rename validation and rename in a closure and clean up `tmp`
    // on any error, so no path (including a failed re-read) leaks the temp file.
    let commit = || -> Result<()> {
        if let Ok(meta) = std::fs::metadata(path) {
            std::fs::set_permissions(&tmp, meta.permissions()).ok();
        }
        match expect {
            Expect::Bytes(expected) => {
                let current = std::fs::read(path).with_context(|| format!("re-read {}", path.display()))?;
                check_fresh(path, &current)?;
                // `check_fresh` compares against what the model last saw, which can be
                // stale if the file changed after the caller's own read; also require the
                // bytes to still be exactly what this write was planned against.
                if current != expected {
                    bail!(
                        "{} changed while the edit was being prepared; read it again before changing it",
                        path.display()
                    );
                }
            }
            Expect::Absent => {
                // The target did not exist when the write was planned. If a
                // directory entry now exists, another process or the user created
                // it in the meantime and the rename would silently overwrite it —
                // fail instead of clobbering. Use `symlink_metadata` rather than
                // `Path::exists()`: the latter follows symlinks and reports `false`
                // for a dangling one, so a symlink created in the window would be
                // clobbered. Propagate stat errors other than `NotFound`.
                match path.symlink_metadata() {
                    Ok(_) => bail!(
                        "{} was created while the write was being prepared; read it again before overwriting it",
                        path.display()
                    ),
                    Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                    Err(e) => return Err(e).with_context(|| format!("stat {}", path.display())),
                }
            }
        }
        std::fs::rename(&tmp, path).with_context(|| format!("replace {}", path.display()))
    };
    let committed = commit();
    if committed.is_err() {
        std::fs::remove_file(&tmp).ok();
    }
    committed
}

/// A located edit: replace each of `ranges` in the text with `new`. `how` says which
/// relaxed rule found it (None for an exact match).
struct Located {
    ranges: Vec<(usize, usize)>,
    /// One replacement per `ranges` entry, each normalized to its own region's
    /// line-ending style. A single match (and every relaxed match) has exactly
    /// one; `replace_all` may have several, one per occurrence.
    news: Vec<String>,
    how: Option<&'static str>,
}

/// Convert `s` to the file's line endings: `read_file` shows lines without
/// `\r`, so the model writes `\n` even for CRLF files.
fn to_file_endings(text: &str, s: &str) -> String {
    if text.contains("\r\n") && !s.contains('\r') { s.replace('\n', "\r\n") } else { s.to_string() }
}

/// The line ending to use for a replacement over `text[start..end]`. The
/// region's own style wins: a multiline region that already ends a line LF stays
/// LF even if a distant line is CRLF. A single-line region has no internal
/// newline of its own, so it falls back to the line terminator it sits on (the
/// one the edit changes), else the file's first line ending.
fn ending_for(text: &str, start: usize, end: usize) -> &'static str {
    let lo = start.min(text.len());
    let hi = end.min(text.len()).max(lo);
    let ls = text[..lo].rfind('\n').map_or(0, |i| i + 1);
    let le = text[ls..].find('\n').map_or(text.len(), |i| ls + i);
    let line_crlf = text[ls..le].ends_with('\r');
    if text[lo..hi].contains('\n') {
        // Multiline region: the terminator of the line the region starts on.
        return if line_crlf { "\r\n" } else { "\n" };
    }
    // Single-line region: the terminator of the line containing it, else the
    // file's first line ending.
    let file_crlf = text.split_inclusive('\n').next().is_some_and(|l| l.ends_with("\r\n"));
    if line_crlf || file_crlf { "\r\n" } else { "\n" }
}

/// Convert `s` to the line ending used by the region `text[start..end]`:
/// `read_file` shows lines without `\r`, so the model writes `\n` even for CRLF
/// files.
fn to_endings_at(text: &str, start: usize, end: usize, s: &str) -> String {
    if ending_for(text, start, end) == "\r\n" && !s.contains('\r') { s.replace('\n', "\r\n") } else { s.to_string() }
}

/// `read_file` prefixes each line with a right-aligned number and a tab. If
/// the model copied those into `old_string` (every physical line has one, blank
/// content lines included), strip them from `old_string` only. `new_string` is not transformed: a
/// prefix-shaped line there is either genuine content (kept verbatim) or, when
/// its number falls in `old_string`'s copied range, rejected as ambiguous.
///
/// Returns `Ok(None)` when `old` is not copied `read_file` output. Returns `Err`
/// when `old` is numbered but `new_string` also carries a prefix-shaped line
/// whose number falls in `old`'s range: that form is ambiguous (is the number
/// copied metadata or an intended TSV cell?), so rather than silently drop the
/// field we reject it and ask for unnumbered content.
fn strip_line_numbers(old: &str, new: &str) -> Result<Option<(String, String, u64)>> {
    fn prefix_num(line: &str) -> Option<(u64, &str)> {
        // `read_file` renders the number as `{:>6}\t` (right-aligned, space-padded
        // to at least six wide). Require the field to equal that exact rendering so
        // a genuine TSV cell like `1\tfoo`, a zero-padded `000002`, or an
        // over-padded field — none of which `read_file` emits — isn't mistaken for
        // a line-number prefix and stripped.
        let (field, rest) = line.split_once('\t')?;
        let digits = field.trim_start_matches(' ');
        if digits.is_empty() || !digits.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        let num: u64 = digits.parse().ok()?;
        if field != format!("{num:>6}") {
            return None;
        }
        Some((num, rest))
    }
    // `old` must look like copied `read_file` output: EVERY physical line
    // carries a prefix AND the numbers are a consecutive ascending run. Blank
    // lines are not exempt — `read_file` numbers empty-content lines too, so a
    // bare blank line means the input was not copied verbatim. Filtering blanks
    // out would let `"     1\tfoo\n\n     2\tbar"` pass as numbered, strip to
    // `"foo\n\nbar"`, and anchor an edit at line `1` even though the intervening
    // blank line pushes `bar` to line 3 — misaligning the numbering. Genuine TSV
    // data whose leading integers merely look prefix-shaped is not consecutive,
    // so it can't retarget an unrelated block by being stripped.
    let lines: Vec<&str> = old.lines().collect();
    let nums: Vec<u64> = match lines.iter().map(|l| prefix_num(l).map(|(n, _)| n)).collect::<Option<_>>() {
        Some(nums) => nums,
        None => return Ok(None),
    };
    if nums.is_empty() || nums.windows(2).any(|w| w[0].checked_add(1) != Some(w[1])) {
        return Ok(None);
    }
    let (lo, hi) = (nums[0], *nums.last().unwrap());
    // Strip the prefix from every `old` line (it's all line-numbered). `new` is
    // different: a prefix-shaped line there is ambiguous — it may be a copied
    // line number, or a genuine TSV cell the model means to write verbatim.
    // Range membership can't tell those apart (a real row can reuse one of
    // `old`'s numbers), so reject any numbered `new` line rather than silently
    // drop a field that was intended as content.
    if new.lines().any(|l| prefix_num(l).is_some_and(|(n, _)| (lo..=hi).contains(&n))) {
        bail!(
            "new_string line(s) start with a number in old_string's copied line range {lo}..={hi}; \
             that prefix is ambiguous (line number or intended content?). Resubmit new_string \
             without the leading line-number field."
        );
    }
    let strip_old =
        |s: &str| s.split('\n').map(|l| prefix_num(l).map_or(l, |(_, rest)| rest)).collect::<Vec<_>>().join("\n");
    Ok(Some((strip_old(old), new.to_string(), lo)))
}

/// The 1-based line number that byte offset `at` falls on in `text`.
fn line_at(text: &str, at: usize) -> u64 {
    text[..at].bytes().filter(|&b| b == b'\n').count() as u64 + 1
}

/// Whether byte offset `at` sits at the start of a physical line — either the
/// file start or immediately after a newline (`\n`, which also terminates a
/// `\r\n` line). A stripped line-number candidate must begin here, not merely
/// somewhere on its named line, so it can't retarget a mid-line substring.
fn at_line_start(text: &str, at: usize) -> bool {
    at == 0 || text.as_bytes()[at - 1] == b'\n'
}

/// The file's lines as (start, end-of-content, end-including-terminator)
/// byte offsets.
fn line_spans(text: &str) -> Vec<(usize, usize, usize)> {
    let mut spans = Vec::new();
    let mut at = 0;
    for line in text.split_inclusive('\n') {
        let content = line.trim_end_matches('\n').trim_end_matches('\r');
        spans.push((at, at + content.len(), at + line.len()));
        at += line.len();
    }
    spans
}

/// `old`'s lines without a trailing empty line, and whether it ended in `\n`.
fn old_lines(old: &str) -> (Vec<&str>, bool) {
    let ends_nl = old.ends_with('\n');
    let body = if ends_nl { &old[..old.len() - 1] } else { old };
    (body.split('\n').map(|l| l.trim_end_matches('\r')).collect(), ends_nl)
}

fn leading_ws(s: &str) -> &str {
    &s[..s.len() - s.trim_start().len()]
}

/// Re-indent `text` by the difference between `had` (the replacement's own
/// indentation) and `want` (the file's). A line carrying the replacement's base
/// indentation `had` is rebased onto `want`, keeping any deeper indentation that
/// follows the common prefix so tab/space structure survives a mixed-whitespace
/// shift (e.g. `had = "\t    "`, `want = "\t"` yields `"\t"`, not one space). A
/// line shallower than `had` still shifts with the block: deepening appends the
/// extra whitespace after the line's own indentation (so a mixed-whitespace line
/// keeps its leading tabs/spaces in order), dedenting drops that many leading
/// whitespace *characters* (so multibyte whitespace can't be split). When `had` and `want` use
/// incompatible whitespace (e.g. spaces vs tabs) neither is a prefix of the
/// other, so no unambiguous delta exists and we reject the relaxed match rather
/// than corrupt lines.
fn reindent(text: &str, had: &str, want: &str) -> Result<String> {
    if !want.starts_with(had) && !had.starts_with(want) {
        bail!(
            "can't re-indent relaxed match: replacement indentation {had:?} and file indentation \
             {want:?} use incompatible whitespace; copy the file's exact indentation into new_string"
        );
    }
    Ok(text
        .split('\n')
        .map(|l| {
            if l.trim().is_empty() {
                return l.to_string();
            }
            let ws = leading_ws(l);
            let rest = &l[ws.len()..];
            if let Some(deeper) = ws.strip_prefix(had) {
                // Carries the base indentation: rebase onto the file's `want`,
                // preserving whatever nests below the common prefix.
                format!("{want}{deeper}{rest}")
            } else if let Some(extra) = want.strip_prefix(had) {
                // Deepen a line shallower than the base by the block delta.
                // Append the delta *after* the line's own indentation so a
                // mixed-whitespace line keeps its leading tabs/spaces in order
                // (prepending `extra` would put spaces before an existing tab).
                format!("{ws}{extra}{rest}")
            } else {
                // Dedent a line shallower than the base, char-safely.
                let drop = had.chars().count() - want.chars().count();
                let kept: String = ws.chars().skip(drop).collect();
                format!("{kept}{rest}")
            }
        })
        .collect::<Vec<_>>()
        .join("\n"))
}

/// Match `old` line by line, ignoring trailing whitespace (`trim_start`:
/// all leading and trailing whitespace). Only a unique match is used; with
/// `trim_start` the replacement is re-indented by the difference between the
/// file's indentation and `old`'s.
fn match_lines(text: &str, old: &str, new: &str, trim_start: bool) -> Result<Option<Located>> {
    let spans = line_spans(text);
    let (lines, ends_nl) = old_lines(old);
    let k = lines.len();
    if lines.iter().all(|l| l.trim().is_empty()) || spans.len() < k {
        return Ok(None);
    }
    let norm = |s: &str| if trim_start { s.trim().to_string() } else { s.trim_end().to_string() };
    let file_line = |i: usize| &text[spans[i].0..spans[i].1];
    // Normalize each side once (O(file_lines + old_lines)), then anchor on the
    // first line and verify the full window only where it matches, instead of
    // re-normalizing up to `k` lines at every start (O(file_lines x old_lines)).
    let file_norm: Vec<String> = (0..spans.len()).map(|i| norm(file_line(i))).collect();
    let old_norm: Vec<String> = lines.iter().map(|l| norm(l)).collect();
    let hits: Vec<usize> = (0..=spans.len() - k)
        .filter(|&i| file_norm[i] == old_norm[0] && (1..k).all(|j| file_norm[i + j] == old_norm[j]))
        .collect();
    let how = if trim_start { "ignoring indentation" } else { "ignoring trailing whitespace" };
    let i = match hits.as_slice() {
        [] => return Ok(None),
        [i] => *i,
        _ => bail!("old_string matches {} places ({how}); add surrounding context to make it unique", hits.len()),
    };
    let start = spans[i].0;
    let end = if ends_nl { spans[i + k - 1].2 } else { spans[i + k - 1].1 };
    let mut new = new.to_string();
    if trim_start && let Some(j0) = lines.iter().position(|l| !l.trim().is_empty()) {
        let (want, had) = (leading_ws(file_line(i + j0)), leading_ws(lines[j0]));
        // The indentation-ignoring match trims every line independently, so a
        // span whose indentation shifts non-uniformly still matches. Re-indenting
        // `new` by the first line's delta alone would then move later lines out of
        // their block, so require every matched line to share the first line's
        // indentation mapping and reject the match as ambiguous otherwise. (When
        // the first line's delta is zero this demands the file's indentation match
        // `old`'s exactly, catching spans that only differ deeper down.)
        let consistent = |had_j: &str, want_j: &str| {
            if let Some(extra) = want.strip_prefix(had) {
                want_j.strip_prefix(had_j) == Some(extra)
            } else if let Some(dropped) = had.strip_prefix(want) {
                had_j.strip_prefix(want_j) == Some(dropped)
            } else {
                // Incompatible whitespace on the first line; `reindent` rejects it below.
                true
            }
        };
        for (j, ol) in lines.iter().enumerate() {
            if ol.trim().is_empty() {
                continue;
            }
            if !consistent(leading_ws(ol), leading_ws(file_line(i + j))) {
                bail!(
                    "old_string matches at line {} ignoring indentation, but its indentation shifts \
                     non-uniformly (line {} differs); copy the file's exact indentation into old_string",
                    i + 1,
                    i + j + 1
                );
            }
        }
        if want != had {
            new = reindent(&new, had, want)?;
        }
    }
    Ok(Some(Located { ranges: vec![(start, end)], news: vec![to_endings_at(text, start, end, &new)], how: Some(how) }))
}

/// Find where `old` is in `text`: exactly first (as the model saw it, then
/// with `read_file` line numbers removed), then line by line ignoring
/// trailing whitespace, then ignoring indentation. Relaxed matches must be
/// unique; fuzzier matching (edit distance) is deliberately not attempted,
/// since a wrong guess edits the wrong code.
fn locate(text: &str, old: &str, new: &str, replace_all: bool) -> Result<Located> {
    // One matching attempt: the text to find, its replacement, a note on how it
    // was derived, and (for the line-number-stripped candidate) the file line
    // its numbers claim — a stripped match is accepted only where it sits.
    type Attempt = (String, String, Option<&'static str>, Option<u64>);
    // Try to match one attempt exactly: the literal text and its
    // file-ending-rewritten form. `Ok(None)` means it doesn't occur; `Err` is a
    // genuine ambiguity (multiple occurrences without `replace_all`).
    let exact = |(o, n, how, at_line): &Attempt| -> Result<Option<Located>> {
        // Gather matches for every distinct representation of `o` — the literal
        // form and the file-ending-rewritten form — before enforcing uniqueness
        // or applying `replace_all`. In a mixed-ending file `old = "a\nb"` can
        // match both an LF block and a CRLF block; considering only the literal
        // form would see one match and edit just the LF block even though
        // `read_file` shows two identical blocks.
        let normalized = to_file_endings(text, o);
        let candidates: Vec<&str> =
            if normalized != *o { vec![o.as_str(), normalized.as_str()] } else { vec![o.as_str()] };
        // For a stripped candidate, keep only matches that actually start on
        // the line its (consecutive) numbers name AND begin at that physical
        // line's boundary — a match landing mid-line (e.g. `foo` inside line 2's
        // `prefix foo suffix`) is a genuine substring, not the numbered row, so
        // stripping must not retarget it. Genuine TSV data whose leading integers
        // merely look prefix-shaped won't sit at that line start either.
        let mut ranges: Vec<(usize, usize)> = candidates
            .iter()
            .flat_map(|c| text.match_indices(c))
            .map(|(at, m)| (at, at + m.len()))
            .filter(|&(at, _)| at_line.is_none_or(|lo| line_at(text, at) == lo && at_line_start(text, at)))
            .collect();
        ranges.sort_unstable();
        ranges.dedup();
        // Coalesce overlapping cross-representation ranges, but ONLY when one is
        // contained in the other: the LF and CRLF forms of one logical
        // occurrence overlap with a shared end (in `a\r\nb`, `old = "\nb"`
        // matches `\r\nb` at 1..4 and its literal `\nb` suffix at 2..4). Those
        // are the SAME occurrence, so keep only the first — otherwise it is
        // miscounted as a second occurrence and, under `replace_all`, rebuilding
        // slices `text[end..start]` and panics. A range that merely *crosses*
        // the previous one without being contained (in `a\r\na\na`,
        // `old = "a\na"` yields CRLF `0..4` and LF `3..6`) is a DISTINCT
        // occurrence that physically overlaps its neighbour; the two cannot both
        // be edited, so reject it as ambiguous rather than silently dropping it.
        // Ranges are sorted by (start, end), so any later range starts no
        // earlier — containment reduces to `r.1 <= prev.1`.
        let mut deduped: Vec<(usize, usize)> = Vec::with_capacity(ranges.len());
        for r in ranges {
            match deduped.last() {
                Some(&(_, e)) if r.1 <= e => {} // contained: same occurrence, drop
                Some(&(_, e)) if r.0 < e => bail!(
                    "old_string matches overlapping occurrences ambiguously; add surrounding context to disambiguate"
                ),
                _ => deduped.push(r),
            }
        }
        let ranges = deduped;
        if ranges.is_empty() {
            return Ok(None);
        }
        // Normalize each replacement to its own region's line ending, not the
        // whole file's or the first occurrence's: in a mixed-ending file an
        // LF-region replacement must not pick up CRLF from a distant line (and
        // vice versa), and under `replace_all` two occurrences may sit in
        // regions of different styles. `n` is normalized even when `o` matched
        // literally: a single-line `o` in a CRLF region must not leave a
        // multiline `n` with LF endings and split that region's endings.
        let news: Vec<String> = ranges.iter().map(|&(s, e)| to_endings_at(text, s, e, n)).collect();
        match ranges.len() {
            1 => Ok(Some(Located { ranges, news, how: *how })),
            // `replace_all` only ever applies to the exact, literal attempt:
            // a relaxed (stripped) match must be unique per the PR contract.
            _ if replace_all && how.is_none() => Ok(Some(Located { ranges, news, how: *how })),
            count => {
                bail!("old_string occurs {count} times; add surrounding context to make it unique or set replace_all")
            }
        }
    };

    // Exact-match the literal candidate FIRST. The line-number-stripped
    // candidate is built lazily, only after the literal text fails to match
    // exactly: its ambiguity error (a prefix-shaped `new_string` line) must not
    // reject an otherwise valid exact edit whose literal text merely happens to
    // be prefix-shaped (e.g. replacing a real `     1\tabc` TSV row in place).
    let literal: Attempt = (old.to_string(), new.to_string(), None, None);
    if let Some(found) = exact(&literal)? {
        return Ok(found);
    }
    let mut attempts: Vec<Attempt> = vec![literal];
    if let Some((o, n, lo)) = strip_line_numbers(old, new)? {
        attempts.push((o, n, Some("after removing read_file line numbers"), Some(lo)));
    }
    // Now exact-match the stripped candidate (the literal one already missed).
    for attempt in attempts.iter().skip(1) {
        if let Some(found) = exact(attempt)? {
            return Ok(found);
        }
    }
    for trim_start in [false, true] {
        // Evaluate every attempt under this relaxed rule before returning. The
        // literal and line-number-stripped candidates can each match a different
        // location (e.g. `"     2\tfoo"` matches a prefix-shaped row on line 1 after
        // trimming trailing whitespace, while its stripped `foo` matches line 2).
        // Returning the first would silently pick one valid interpretation over
        // another, so reject the edit as ambiguous unless every attempt that
        // matches lands on the same range.
        let mut chosen: Option<Located> = None;
        for (o, n, _, at_line) in &attempts {
            if let Some(found) = match_lines(text, o, n, trim_start)? {
                // A stripped candidate's line-matched range must also land on the
                // line its numbers name, else the "prefix" was genuine data.
                if at_line.is_some_and(|lo| line_at(text, found.ranges[0].0) != lo) {
                    continue;
                }
                match &chosen {
                    None => chosen = Some(found),
                    Some(prev) if prev.ranges == found.ranges => {}
                    Some(prev) => bail!(
                        "old_string matches multiple distinct locations under relaxed matching \
                         (lines {} and {}); add surrounding context to make it unique",
                        line_at(text, prev.ranges[0].0),
                        line_at(text, found.ranges[0].0)
                    ),
                }
            }
        }
        if let Some(found) = chosen {
            return Ok(found);
        }
    }
    bail!(
        "old_string not found; read the file and copy the text exactly{}",
        near_miss(text, &attempts.last().unwrap().0)
    )
}

/// Lines `lo..=hi` (0-based) of `text`, numbered as `read_file` shows them.
/// Long spans keep their first and last 20 lines.
fn numbered(lines: &[&str], lo: usize, hi: usize) -> String {
    let fmt = |i: usize| {
        let line: String = lines[i].chars().take(MAX_LINE_CHARS).collect();
        format!("{:>6}\t{line}\n", i + 1)
    };
    if hi + 1 - lo > 40 {
        let mut out: String = (lo..lo + 20).map(fmt).collect();
        out.push_str("   ...\n");
        out.extend((hi - 19..=hi).map(fmt));
        out
    } else {
        (lo..=hi).map(fmt).collect()
    }
}

/// The edited regions of `text` (each `start..end` in bytes) with three lines
/// of context either side, so the model can check the result without a re-read.
/// Overlapping or adjacent regions merge; a gap between distant regions is
/// shown as `...`. Each rendered region respects the 40-line cap, and a global
/// budget bounds the total so a `replace_all` with many distant matches can't
/// flood the output — omitted regions are noted.
fn snippet(text: &str, ranges: &[(usize, usize)]) -> String {
    let lines: Vec<&str> = text.lines().collect();
    if lines.is_empty() {
        return "(the file is now empty)\n".into();
    }
    let max = lines.len() - 1;
    let mut spans: Vec<(usize, usize)> = ranges
        .iter()
        .map(|&(start, end)| {
            let first = text[..start].matches('\n').count().min(max);
            let region = &text[start..end];
            let last = (first + region.strip_suffix('\n').unwrap_or(region).matches('\n').count()).min(max);
            (first.saturating_sub(3), (last + 3).min(max))
        })
        .collect();
    spans.sort_unstable();
    let mut merged: Vec<(usize, usize)> = Vec::with_capacity(spans.len());
    for (lo, hi) in spans {
        match merged.last_mut() {
            Some(prev) if lo <= prev.1 + 1 => prev.1 = prev.1.max(hi),
            _ => merged.push((lo, hi)),
        }
    }
    const MAX_SNIPPET_LINES: usize = 40;
    let mut out = String::new();
    let mut used = 0;
    for (idx, &(lo, hi)) in merged.iter().enumerate() {
        let region = numbered(&lines, lo, hi);
        let region_lines = region.matches('\n').count();
        // Always show the first region; stop once the global budget is spent.
        if idx > 0 && used + region_lines > MAX_SNIPPET_LINES {
            out.push_str(&format!("   ... ({} more edited region(s) not shown)\n", merged.len() - idx));
            break;
        }
        if idx > 0 {
            out.push_str("   ...\n");
        }
        out.push_str(&region);
        used += region_lines;
    }
    out
}

/// For a failed match: the window of the file sharing the most (trimmed,
/// non-blank) lines with `old`, so the next attempt can copy it exactly. When no
/// whole line agrees (e.g. a misspelled single line), fall back to a per-line
/// character-overlap score — used only for the diagnostic hint, never to select
/// an edit — so a miss still points at the closest candidate.
fn near_miss(text: &str, old: &str) -> String {
    let lines: Vec<&str> = text.lines().collect();
    let (want, _) = old_lines(old);
    let k = want.len().min(lines.len());
    if k == 0 {
        return String::new();
    }
    // This is a diagnostic on an already-failed edit, so keep it cheap: score at
    // most `MAX_SCAN` windows rather than every file-line offset (a naive scan is
    // O(file_lines x old_lines)), and reuse one char-count map per `want` line
    // instead of allocating one per line pair.
    const MAX_SCAN: usize = 2000;
    let span = lines.len() - k + 1;
    let windows = 0..span.min(MAX_SCAN);
    // When the file has more candidate windows than we scan, the result is the
    // closest match *within the scanned prefix*, not a global one; qualify the
    // message so a near match past the boundary isn't implied to be absent.
    let scope = if span > MAX_SCAN {
        format!(" (nearest within the first {} of {span} candidate positions scanned)", span.min(MAX_SCAN))
    } else {
        String::new()
    };
    let trimmed: Vec<&str> = want.iter().map(|l| l.trim()).collect();
    let line_score = |i: usize| (0..k).filter(|&j| !trimmed[j].is_empty() && lines[i + j].trim() == trimmed[j]).count();
    let (best, i) =
        windows.clone().map(|i| (line_score(i), i)).max_by_key(|&(s, i)| (s, std::cmp::Reverse(i))).unwrap();
    if best > 0 {
        let of = want.iter().filter(|l| !l.trim().is_empty()).count();
        return format!(
            ". Closest match ({best} of {of} lines agree){scope}, lines {}-{}:\n{}",
            i + 1,
            i + k,
            numbered(&lines, i, i + k - 1)
        );
    }
    // No whole line agrees: rank windows by shared characters so even a
    // misspelled single line gets a hint. Diagnostic only — the edit already failed.
    // Build each `want` line's char counts once, then score each window against a
    // single REUSED scratch map (cleared, never reallocated) so the fallback does
    // NOT allocate — or clone `want_counts` — once per window/line pair. The score
    // is the multiset intersection size: sum over `want` chars of
    // min(want_count, line_count).
    let want_counts: Vec<std::collections::HashMap<char, i32>> = trimmed
        .iter()
        .map(|w| {
            let mut m = std::collections::HashMap::new();
            for c in w.chars() {
                *m.entry(c).or_insert(0) += 1;
            }
            m
        })
        .collect();
    let mut scratch: std::collections::HashMap<char, i32> = std::collections::HashMap::new();
    let (mut sbest, mut si) = (0usize, 0usize);
    for i in windows {
        let mut score = 0usize;
        for j in 0..k {
            scratch.clear();
            for c in lines[i + j].trim().chars() {
                *scratch.entry(c).or_insert(0) += 1;
            }
            score += want_counts[j].iter().map(|(c, &wc)| wc.min(scratch.get(c).copied().unwrap_or(0))).sum::<i32>()
                as usize;
        }
        // Strictly-greater keeps the earliest (smallest-i) window among ties,
        // matching the line-score pass's `(s, Reverse(i))` preference.
        if score > sbest {
            sbest = score;
            si = i;
        }
    }
    if sbest == 0 {
        return String::new();
    }
    format!(
        ". Closest lines {}-{} (no lines match exactly){scope}:\n{}",
        si + 1,
        si + k,
        numbered(&lines, si, si + k - 1)
    )
}

pub fn write_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let content = string_arg(args, "content")?;
    let existed = path.exists();
    let current = if existed {
        // Propagate a read failure instead of silently skipping the freshness
        // check: an unreadable-but-writable file would otherwise be overwritten
        // without the prior-read / stale-content guarantees.
        let current = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
        check_fresh(&path, &current)?;
        Some(current)
    } else {
        None
    };
    write_atomically(&path, content, current.as_deref().map_or(Expect::Absent, Expect::Bytes))?;
    remember(&path, content.as_bytes());
    Ok(format!("{} {} ({} bytes)", if existed { "Overwrote" } else { "Created" }, path.display(), content.len()))
}

pub fn edit_file(args: &Value) -> Result<String> {
    let path = path_arg(args)?;
    let old = string_arg(args, "old_string")?;
    let new = string_arg(args, "new_string")?;
    let replace_all = args.get("replace_all").and_then(Value::as_bool).unwrap_or(false);
    if old.is_empty() {
        bail!("old_string must not be empty (use write_file to create a file)");
    }
    if old == new {
        bail!("old_string and new_string are identical");
    }
    let bytes = std::fs::read(&path).with_context(|| format!("read {}", path.display()))?;
    check_fresh(&path, &bytes)?;
    let text = String::from_utf8(bytes.clone()).map_err(|_| anyhow!("{} is not valid UTF-8", path.display()))?;
    let found = locate(&text, old, new, replace_all).map_err(|e| anyhow!("{}: {e}", path.display()))?;
    let mut updated = String::with_capacity(text.len() + found.news.iter().map(String::len).sum::<usize>());
    let mut last = 0;
    let mut new_ranges: Vec<(usize, usize)> = Vec::with_capacity(found.ranges.len());
    for (&(start, end), repl) in found.ranges.iter().zip(&found.news) {
        updated.push_str(&text[last..start]);
        let at = updated.len();
        updated.push_str(repl);
        new_ranges.push((at, updated.len()));
        last = end;
    }
    updated.push_str(&text[last..]);
    write_atomically(&path, &updated, Expect::Bytes(&bytes))?;
    remember(&path, updated.as_bytes());
    Ok(format!(
        "Replaced {} occurrence(s) in {}{}:\n{}",
        found.ranges.len(),
        path.display(),
        found.how.map(|h| format!(" (matched {h})")).unwrap_or_default(),
        snippet(&updated, &new_ranges)
    ))
}

pub fn register(tools: &ToolRegistry) {
    tools.register(
        ToolDefinition::new(
            "read_file",
            "Read a file. Text files return numbered lines; use offset/limit to page through large \
             ones (pagination applies to text only). Image files (PNG, JPEG, GIF, WebP) are returned \
             to vision-capable models as viewable images.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string", "description": "File path, absolute or relative to the working directory" },
                    "offset": { "type": "integer", "description": "1-based first line to return (text files only, default 1)" },
                    "limit": { "type": "integer", "description": "Maximum number of lines (text files only, default 2000)" }
                },
                "required": ["path"]
            }),
        ),
        Box::new(|args| read_file(&args)),
    );
    tools.register(
        ToolDefinition::new(
            "write_file",
            "Create a file, or overwrite one you have read, creating parent directories. Prefer edit_file for changes to existing files.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "content": { "type": "string" }
                },
                "required": ["path", "content"]
            }),
        ),
        Box::new(|args| write_file(&args).map(Value::String)),
    );
    tools.register(
        ToolDefinition::new(
            "edit_file",
            "Replace text in a file you have read (read it again if it changed since). old_string must match exactly once unless replace_all is true; if there is no exact match, a unique match ignoring trailing whitespace or indentation is used. Returns the edited lines with context.",
            json!({
                "type": "object",
                "properties": {
                    "path": { "type": "string" },
                    "old_string": { "type": "string", "description": "Exact text to replace, including whitespace" },
                    "new_string": { "type": "string" },
                    "replace_all": { "type": "boolean", "description": "Replace every occurrence (default false)" }
                },
                "required": ["path", "old_string", "new_string"]
            }),
        ),
        Box::new(|args| edit_file(&args).map(Value::String)),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `read_file` of a text file, as its string content.
    fn read_text(args: &Value) -> String {
        match read_file(args).unwrap() {
            Value::String(text) => text,
            other => panic!("expected text, got {other}"),
        }
    }

    #[test]
    fn read_pages_with_line_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("a.txt");
        std::fs::write(&path, "one\ntwo\nthree\n").unwrap();
        let p = path.to_str().unwrap();
        let all = read_text(&json!({ "path": p }));
        assert!(all.contains("     1\tone\n") && all.contains("     3\tthree\n"));
        let page = read_text(&json!({ "path": p, "offset": 2, "limit": 1 }));
        assert!(page.starts_with("     2\ttwo\n"));
        assert!(page.contains("use offset=3"));
        assert!(read_file(&json!({ "path": p, "offset": 9 })).is_err());
    }

    #[test]
    fn read_rejects_binary() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("b.bin");
        std::fs::write(&path, [0u8, 1, 2]).unwrap();
        assert!(read_file(&json!({ "path": path })).is_err());
    }

    /// Encode a solid-colour image of `w`×`h` in `format`.
    fn make_image(w: u32, h: u32, format: image::ImageFormat) -> Vec<u8> {
        let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(w, h, image::Rgb([10, 120, 200])));
        let mut out = std::io::Cursor::new(Vec::new());
        img.write_to(&mut out, format).unwrap();
        out.into_inner()
    }

    #[test]
    fn read_returns_images_by_magic_bytes() {
        let dir = tempfile::tempdir().unwrap();
        for (name, format, media_type) in [
            ("a.png", image::ImageFormat::Png, "image/png"),
            ("a.jpg", image::ImageFormat::Jpeg, "image/jpeg"),
            ("a.gif", image::ImageFormat::Gif, "image/gif"),
            ("a.webp", image::ImageFormat::WebP, "image/webp"),
        ] {
            let path = dir.path().join(name);
            std::fs::write(&path, make_image(40, 20, format)).unwrap();
            let result = read_file(&json!({ "path": path.to_str().unwrap() })).unwrap();
            let image = result.get("image").unwrap_or_else(|| panic!("{name} should be an image: {result}"));
            assert_eq!(image["media_type"], media_type, "{name}");
            assert_eq!(image["width"], 40, "{name}");
            assert_eq!(image["height"], 20, "{name}");
            assert!(image["bytes"].as_u64().is_some_and(|b| b > 0), "{name}");
            assert!(image.get("data_base64").is_none(), "{name}: metadata must not carry the pixels");
        }
    }

    #[test]
    fn read_image_stores_absolute_source_path() {
        // Regression: the persisted source path must be absolute so the
        // re-`read_file` workflow survives a session resume under a different
        // working directory. `read_image` is lexical here (it never touches the
        // filesystem for the path), so a relative input must come back absolute.
        let bytes = make_image(8, 8, image::ImageFormat::Png);
        let format = crate::attachment::ImageFormat::sniff(&bytes).unwrap();
        let result = read_image(Path::new("sub/rel.png"), &bytes, format).unwrap();
        let stored = result["image"]["path"].as_str().unwrap();
        assert!(Path::new(stored).is_absolute(), "stored path should be absolute: {stored}");
        assert!(
            stored.ends_with("sub/rel.png") || stored.ends_with("sub\\rel.png"),
            "stored path should retain the source tail: {stored}"
        );
    }

    #[test]
    fn read_detects_image_despite_text_extension() {
        // Magic bytes, not the extension, decide: a PNG named `.txt` is an image.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("misleading.txt");
        std::fs::write(&path, make_image(8, 8, image::ImageFormat::Png)).unwrap();
        let result = read_file(&json!({ "path": path.to_str().unwrap() })).unwrap();
        assert!(result.get("image").is_some(), "PNG bytes named .txt are an image: {result}");
    }

    #[test]
    fn write_creates_parents_and_edit_requires_unique_match() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("nested/dir/c.txt");
        let p = path.to_str().unwrap();
        assert!(write_file(&json!({ "path": p, "content": "a b a\n" })).unwrap().starts_with("Created"));
        let err = edit_file(&json!({ "path": p, "old_string": "a", "new_string": "x" })).unwrap_err();
        assert!(err.to_string().contains("occurs 2 times"));
        edit_file(&json!({ "path": p, "old_string": "a b", "new_string": "z b" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "z b a\n");
        edit_file(&json!({ "path": p, "old_string": "a", "new_string": "q", "replace_all": true })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "z b q\n");
        assert!(edit_file(&json!({ "path": p, "old_string": "nope", "new_string": "x" })).is_err());
        assert!(write_file(&json!({ "path": p, "content": "new" })).unwrap().starts_with("Overwrote"));
    }

    #[test]
    fn string_arg_distinguishes_missing_null_and_wrong_type() {
        // Missing field.
        let err = write_file(&json!({ "content": "x" })).unwrap_err();
        assert!(err.to_string().contains("missing required argument \"path\""), "{err}");
        // Explicit null.
        let err = write_file(&json!({ "path": null, "content": "x" })).unwrap_err();
        assert!(err.to_string().contains("\"path\" is null"), "{err}");
        // Wrong JSON type.
        let err = write_file(&json!({ "path": 42, "content": "x" })).unwrap_err();
        assert!(err.to_string().contains("must be a string, got a number"), "{err}");
    }

    #[test]
    fn edit_matches_crlf_files_as_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("w.txt");
        std::fs::write(&path, "a\r\nb\r\nc\r\n").unwrap();
        let p = path.to_str().unwrap();
        read_file(&json!({ "path": p })).unwrap();
        edit_file(&json!({ "path": p, "old_string": "a\nb", "new_string": "x\ny" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "x\r\ny\r\nc\r\n");
    }

    #[cfg(unix)]
    #[test]
    fn writes_through_symlinks() {
        let dir = tempfile::tempdir().unwrap();
        let target = dir.path().join("AGENTS.md");
        let link = dir.path().join("CLAUDE.md");
        std::fs::write(&target, "old\n").unwrap();
        std::os::unix::fs::symlink("AGENTS.md", &link).unwrap();
        let l = link.to_str().unwrap();
        read_file(&json!({ "path": l })).unwrap();
        edit_file(&json!({ "path": l, "old_string": "old", "new_string": "new" })).unwrap();
        write_file(&json!({ "path": l, "content": "newer\n" })).unwrap();
        assert!(link.symlink_metadata().unwrap().file_type().is_symlink());
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "newer\n");
    }

    /// A file with `content`, already read (so edits are allowed).
    fn read_fixture(dir: &tempfile::TempDir, name: &str, content: &str) -> String {
        let path = dir.path().join(name);
        std::fs::write(&path, content).unwrap();
        let p = path.to_str().unwrap().to_string();
        read_file(&json!({ "path": p })).unwrap();
        p
    }

    #[test]
    fn edits_and_overwrites_require_a_current_read() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("s.txt");
        std::fs::write(&path, "one\n").unwrap();
        let p = path.to_str().unwrap();
        let edit = json!({ "path": p, "old_string": "one", "new_string": "two" });
        let err = edit_file(&edit).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
        let err = write_file(&json!({ "path": p, "content": "x" })).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
        read_file(&json!({ "path": p })).unwrap();
        // Changed on disk after the read (a command, the user): refused.
        std::fs::write(&path, "one\nmore\n").unwrap();
        let err = edit_file(&edit).unwrap_err().to_string();
        assert!(err.contains("changed since it was last read"), "{err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "one\nmore\n");
        // Re-read, then edit; our own write keeps the file current for the next edit.
        read_file(&json!({ "path": p })).unwrap();
        edit_file(&edit).unwrap();
        edit_file(&json!({ "path": p, "old_string": "more", "new_string": "less" })).unwrap();
        write_file(&json!({ "path": p, "content": "replaced\n" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "replaced\n");
    }

    #[test]
    fn image_reads_authorize_writes_only_once_dispatched_to_the_model() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("pic.png");
        let png = {
            let img = image::DynamicImage::ImageRgb8(image::RgbImage::from_pixel(8, 8, image::Rgb([1, 2, 3])));
            let mut out = std::io::Cursor::new(Vec::new());
            img.write_to(&mut out, image::ImageFormat::Png).unwrap();
            out.into_inner()
        };
        std::fs::write(&path, &png).unwrap();
        let p = path.to_str().unwrap();
        // `read_file` returns image metadata but does not itself authorize a
        // write: only the dispatch layer, once the model can actually view the
        // image, records the read (the no-vision path must not authorize it).
        assert!(read_file(&json!({ "path": p })).unwrap().get("image").is_some());
        let err = write_file(&json!({ "path": p, "content": "x" })).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
        // Once the image is delivered to the model, a later write passes the
        // freshness gate — matching a successful text read.
        mark_image_read(&path, &png);
        write_file(&json!({ "path": p, "content": "replaced" })).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "replaced");
    }

    #[test]
    fn relaxed_matches_ignore_whitespace_and_line_numbers() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "r.py", "def f():\n    x = 1  \n    return x\n");
        // Trailing whitespace differs.
        let out = edit_file(&json!({ "path": p, "old_string": "    x = 1\n", "new_string": "    x = 2\n" })).unwrap();
        assert!(out.contains("ignoring trailing whitespace"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n    x = 2\n    return x\n");
        // Indentation differs: the replacement is re-indented to the file's.
        let out = edit_file(&json!({
            "path": p, "old_string": "x = 2\nreturn x", "new_string": "x = 3\nif x:\n    return x"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n    x = 3\n    if x:\n        return x\n");
        // read_file's line-number prefixes copied into old_string.
        let out =
            edit_file(&json!({ "path": p, "old_string": "     2\t    x = 3", "new_string": "    x = 4" })).unwrap();
        assert!(out.contains("line numbers"), "{out}");
        assert!(std::fs::read_to_string(&p).unwrap().contains("    x = 4\n"));
    }

    #[test]
    fn relaxed_matches_must_be_unique() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "u.rs", "fn a() {\n    ok()\n}\nfn b() {\n  ok()\n}\n");
        let err = edit_file(&json!({ "path": p, "old_string": "ok()", "new_string": "no()" })).unwrap_err().to_string();
        assert!(err.contains("occurs 2 times"), "{err}");
        let err = edit_file(&json!({ "path": p, "old_string": "\tok()\n", "new_string": "\tno()\n" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("matches 2 places (ignoring indentation)"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "fn a() {\n    ok()\n}\nfn b() {\n  ok()\n}\n");
    }

    #[test]
    fn a_miss_shows_the_closest_lines() {
        let dir = tempfile::tempdir().unwrap();
        let p = read_fixture(&dir, "m.rs", "fn main() {\n    let x = 1;\n    println!(\"{x}\");\n}\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "let x = 1;\nprintln!(\"{y}\");", "new_string": "z"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("not found"), "{err}");
        assert!(err.contains("Closest match (1 of 2 lines agree), lines 2-3"), "{err}");
        assert!(err.contains("     3\t    println!(\"{x}\");"), "{err}");
    }

    #[test]
    fn edit_result_shows_the_changed_lines_in_context() {
        let dir = tempfile::tempdir().unwrap();
        let body: String = (1..=20).map(|n| format!("line {n}\n")).collect();
        let p = read_fixture(&dir, "c.txt", &body);
        let out = edit_file(&json!({ "path": p, "old_string": "line 10\n", "new_string": "ten\nTEN\n" })).unwrap();
        assert!(out.starts_with("Replaced 1 occurrence(s) in "), "{out}");
        assert!(out.contains("     7\tline 7\n") && out.contains("    10\tten\n    11\tTEN\n"), "{out}");
        assert!(out.contains("    14\tline 13\n") && !out.contains("line 14") && !out.contains("line 6\n"), "{out}");
    }

    #[test]
    fn a_failed_read_does_not_authorize_edits() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("f.txt");
        std::fs::write(&path, "one\ntwo\n").unwrap();
        let p = path.to_str().unwrap();
        // An out-of-range read fails and must NOT mark the file as seen.
        assert!(read_file(&json!({ "path": p, "offset": 99 })).is_err());
        let err = edit_file(&json!({ "path": p, "old_string": "one", "new_string": "x" })).unwrap_err().to_string();
        assert!(err.contains("has not been read"), "{err}");
    }

    #[test]
    fn reindent_shifts_lines_shallower_than_the_match() {
        let dir = tempfile::tempdir().unwrap();
        // File is indented deeper (8 then 4) than old_string (4 then 0); the
        // shallower replacement line must shift with the block, not stay at 0.
        let p = read_fixture(&dir, "d.py", "if a:\n        x = 1\n    y = 2\n");
        let out = edit_file(&json!({
            "path": p, "old_string": "    x = 1\ny = 2", "new_string": "    x = 9\ny = 9"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "if a:\n        x = 9\n    y = 9\n");
    }

    #[test]
    fn replace_all_result_shows_every_changed_region() {
        let dir = tempfile::tempdir().unwrap();
        let body: String =
            (1..=30).map(|n| if n == 5 || n == 25 { "mark\n".into() } else { format!("line {n}\n") }).collect();
        let p = read_fixture(&dir, "ra.txt", &body);
        let out =
            edit_file(&json!({ "path": p, "old_string": "mark", "new_string": "DONE", "replace_all": true })).unwrap();
        assert!(out.starts_with("Replaced 2 occurrence(s)"), "{out}");
        // Both edited regions are rendered, separated by a gap marker.
        assert!(out.contains("     5\tDONE\n") && out.contains("    25\tDONE\n") && out.contains("   ...\n"), "{out}");
    }

    #[test]
    fn unpadded_tsv_number_is_not_treated_as_a_line_prefix() {
        let dir = tempfile::tempdir().unwrap();
        // `1\tfoo` is genuine TSV, not a read_file prefix (which pads to >=6
        // wide). With no exact match, stripping `1\t` must NOT let the edit
        // retarget the unrelated `foo` line.
        let p = read_fixture(&dir, "t.tsv", "1\tfoo\n2\tbar\n");
        let err = edit_file(&json!({ "path": p, "old_string": "1\tfoo\nmissing", "new_string": "x" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("not found"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "1\tfoo\n2\tbar\n");
    }

    #[test]
    fn incompatible_indentation_rejects_the_relaxed_match() {
        let dir = tempfile::tempdir().unwrap();
        // File uses a tab; old_string uses spaces. Neither indentation is a
        // prefix of the other, so the relaxed match is rejected, not applied.
        let p = read_fixture(&dir, "mix.py", "def f():\n\treturn 1\n");
        let err = edit_file(&json!({ "path": p, "old_string": "    return 1", "new_string": "    return 2" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("incompatible whitespace"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n\treturn 1\n");
    }

    #[test]
    fn dedent_across_multibyte_whitespace_does_not_panic() {
        let dir = tempfile::tempdir().unwrap();
        // File indents each line with an ideographic space (U+3000, 3 bytes);
        // old_string adds one ASCII space. The replacement is rebased onto the
        // file's exact indentation (the ideographic space), byte-safely — slicing
        // the delta by byte count would split the 3-byte space and panic.
        let p = read_fixture(&dir, "u.txt", "top\n\u{3000}a\n\u{3000}b\n");
        let out = edit_file(&json!({
            "path": p, "old_string": "\u{3000} a\n\u{3000} b", "new_string": "\u{3000} A\n\u{3000} B"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "top\n\u{3000}A\n\u{3000}B\n");
    }

    #[test]
    fn mixed_whitespace_shift_preserves_the_common_prefix() {
        let dir = tempfile::tempdir().unwrap();
        // File indents with a tab; old_string indents with a tab plus four
        // spaces. Dedenting must rebase onto the file's tab (dropping only the
        // trailing spaces), not blindly drop four leading characters (which would
        // leave a single space and corrupt the tab/space structure).
        let p = read_fixture(&dir, "mx.py", "def f():\n\tx = 1\n");
        let out = edit_file(&json!({
            "path": p, "old_string": "\t    x = 1", "new_string": "\t    x = 2"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "def f():\n\tx = 2\n");
    }

    #[test]
    fn mixed_whitespace_deepen_appends_delta_after_existing_indentation() {
        let dir = tempfile::tempdir().unwrap();
        // File is deeper than old_string (tab+8sp / tab+6sp vs tab+4sp / tab+2sp),
        // so the block deepens by four spaces. The shallower second line keeps its
        // own tab+2sp indentation with the delta appended (tab+6sp) — prepending
        // the delta would put spaces before the tab and corrupt the structure.
        let p = read_fixture(&dir, "dp.py", "if a:\n\t        x = 1\n\t      y = 2\n");
        let out = edit_file(&json!({
            "path": p, "old_string": "\t    x = 1\n\t  y = 2", "new_string": "\t    x = 9\n\t  y = 9"
        }))
        .unwrap();
        assert!(out.contains("ignoring indentation"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "if a:\n\t        x = 9\n\t      y = 9\n");
    }

    #[test]
    fn single_line_match_normalizes_multiline_replacement_endings() {
        let dir = tempfile::tempdir().unwrap();
        // A single-line old_string has no newline, so it matches literally even in
        // a CRLF file. The multiline replacement must still be rewritten to CRLF,
        // not left with LF endings that would split the file's line endings.
        let p = read_fixture(&dir, "crlf.txt", "a\r\nb\r\nc\r\n");
        edit_file(&json!({ "path": p, "old_string": "b", "new_string": "x\ny" })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\r\nx\r\ny\r\nc\r\n");
    }

    #[test]
    fn consecutive_tsv_numbers_do_not_retarget_an_unrelated_block() {
        let dir = tempfile::tempdir().unwrap();
        // `123456\tfoo\n123457\tbar` is padded and consecutive, so it looks like a
        // read_file prefix, but the file has `foo`/`bar` at lines 1-2, not
        // 123456-123457. Validating the numbers against the match's file position
        // rejects the stripped attempt rather than editing the unrelated block.
        let p = read_fixture(&dir, "tsv.tsv", "foo\nbar\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "123456\tfoo\n123457\tbar", "new_string": "x"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("not found"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "foo\nbar\n");
    }

    #[test]
    fn replace_all_does_not_apply_to_a_stripped_relaxed_match() {
        let dir = tempfile::tempdir().unwrap();
        // `     1\tfoo` is a read_file prefix for line 1's `foo`. With replace_all
        // it must NOT relax to every `foo`; the stripped candidate is validated to
        // the line its number names (line 1) and edits only that occurrence.
        let p = read_fixture(&dir, "ra2.txt", "foo\nbar\nfoo\n");
        let out = edit_file(&json!({
            "path": p, "old_string": "     1\tfoo", "new_string": "FOO", "replace_all": true
        }))
        .unwrap();
        assert!(out.starts_with("Replaced 1 occurrence(s)"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "FOO\nbar\nfoo\n");
    }

    #[test]
    fn a_misspelled_single_line_still_gets_a_closest_hint() {
        let dir = tempfile::tempdir().unwrap();
        // No whole trimmed line agrees, so the line-count score is 0; the
        // character-overlap fallback still points at the closest line.
        let p = read_fixture(&dir, "sp.rs", "fn main() {\n    let value = compute();\n}\n");
        let err = edit_file(&json!({ "path": p, "old_string": "let valeu = compute();", "new_string": "z" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("not found"), "{err}");
        assert!(err.contains("no lines match exactly"), "{err}");
        assert!(err.contains("    let value = compute();"), "{err}");
    }

    #[test]
    fn snippet_output_is_globally_capped() {
        let dir = tempfile::tempdir().unwrap();
        // Many distant matches would each render a region; the global cap bounds
        // total output and notes the omitted regions instead of flooding.
        let body: String =
            (1..=200).map(|n| if n % 10 == 0 { "mark\n".into() } else { format!("line {n}\n") }).collect();
        let p = read_fixture(&dir, "big.txt", &body);
        let out =
            edit_file(&json!({ "path": p, "old_string": "mark", "new_string": "DONE", "replace_all": true })).unwrap();
        assert!(out.starts_with("Replaced 20 occurrence(s)"), "{out}");
        assert!(out.contains("more edited region(s) not shown"), "{out}");
        assert!(out.lines().count() < 60, "output should stay bounded: {out}");
    }

    #[test]
    fn overwrite_propagates_read_errors_instead_of_skipping_freshness() {
        let dir = tempfile::tempdir().unwrap();
        let sub = dir.path().join("d");
        std::fs::create_dir(&sub).unwrap();
        // A directory can't be read as a file: write_file must surface the read
        // error rather than treat it as a new file and clobber the path.
        let err = write_file(&json!({ "path": sub.to_str().unwrap(), "content": "x" })).unwrap_err().to_string();
        assert!(err.contains("read "), "{err}");
        assert!(sub.is_dir(), "{err}");
    }

    #[test]
    fn new_string_tsv_row_is_not_stripped_as_a_line_prefix() {
        let dir = tempfile::tempdir().unwrap();
        // The file's first line is plain `abc`; read_file shows it as `     1\tabc`.
        // old copies that numbered line, but new is a genuine six-digit TSV row
        // that must be written verbatim, not stripped to `abc`.
        let p = read_fixture(&dir, "n.tsv", "abc\ndef\n");
        let out = edit_file(&json!({ "path": p, "old_string": "     1\tabc", "new_string": "123456\tabc" })).unwrap();
        assert!(out.contains("line numbers"), "{out}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "123456\tabc\ndef\n");
    }

    #[test]
    fn nonconsecutive_numeric_prefixes_are_not_line_numbers() {
        let dir = tempfile::tempdir().unwrap();
        // Padded but NON-consecutive leading integers are TSV data, not read_file
        // line numbers (which are always consecutive), so they must not be
        // stripped to retarget the unrelated `foo`/`bar` lines.
        let p = read_fixture(&dir, "d.tsv", "foo\nbar\n");
        let err = edit_file(&json!({ "path": p, "old_string": "123456\tfoo\n999999\tbar", "new_string": "x" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("not found"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "foo\nbar\n");
    }

    #[test]
    fn bare_blank_line_in_numbered_old_is_not_stripped() {
        let dir = tempfile::tempdir().unwrap();
        // `read_file` numbers blank content lines too, so a *bare* blank line in
        // numbered `old_string` means the input was not copied verbatim. Stripping
        // it anyway would anchor the edit at line 1 even though the blank line
        // pushes `bar` to line 3, misaligning the numbering. Require a prefix on
        // every physical line: the malformed input must fall back to a literal
        // (unfound) match, not silently retarget lines 1-3.
        let p = read_fixture(&dir, "b.txt", "foo\n\nbar\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "     1\tfoo\n\n     2\tbar", "new_string": "x"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("not found"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "foo\n\nbar\n");
    }

    #[test]
    fn numbered_old_with_prefixed_blank_line_strips_and_edits() {
        let dir = tempfile::tempdir().unwrap();
        // A faithful copy of `read_file` output keeps the blank line's prefix
        // (`     2\t`), so numbering stays aligned and the block strips and edits.
        let p = read_fixture(&dir, "b.txt", "foo\n\nbar\n");
        edit_file(&json!({
            "path": p, "old_string": "     1\tfoo\n     2\t\n     3\tbar", "new_string": "FOO\n\nBAR"
        }))
        .unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "FOO\n\nBAR\n");
    }

    #[test]
    fn stripped_line_number_match_must_begin_at_line_boundary() {
        let dir = tempfile::tempdir().unwrap();
        // Numbered `old_string` claims line 2 but its stripped content `foo` also
        // occurs mid-line inside line 2's `prefix foo suffix`. The stripped
        // candidate is anchored to line 2, yet the only occurrence there starts
        // mid-line, not at the line boundary — that is a genuine substring, not
        // the numbered row. The edit must be rejected, not silently retarget the
        // interior `foo`.
        let p = read_fixture(&dir, "m.txt", "alpha\nprefix foo suffix\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "     2\tfoo", "new_string": "BAR"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("not found"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "alpha\nprefix foo suffix\n");
    }

    #[test]
    fn nonuniform_indentation_rejects_the_relaxed_match() {
        let dir = tempfile::tempdir().unwrap();
        // The first matched line's indentation matches the file (zero delta), but
        // a later line is indented differently in the file than in old_string.
        // Re-indenting new by the first line's delta would change block structure,
        // so the ambiguous match must be rejected rather than silently applied.
        let p = read_fixture(&dir, "nu.py", "if a:\n    x = 1\n        y = 2\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "    x = 1\n    y = 2", "new_string": "    x = 9\n    y = 9"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("non-uniformly"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "if a:\n    x = 1\n        y = 2\n");
    }

    #[test]
    fn edit_in_lf_region_of_mixed_file_keeps_lf_replacement() {
        let dir = tempfile::tempdir().unwrap();
        // The file mixes endings: first line CRLF, the rest LF. Editing the
        // LF-only region with a multiline replacement must not convert the
        // replacement to CRLF just because a distant line uses CRLF.
        let p = read_fixture(&dir, "mix.txt", "a\r\nb\nc\n");
        edit_file(&json!({ "path": p, "old_string": "b\nc", "new_string": "x\ny" })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\r\nx\ny\n");
    }

    #[test]
    fn edit_in_crlf_region_of_mixed_file_converts_replacement_to_crlf() {
        let dir = tempfile::tempdir().unwrap();
        // Mirror image: an LF first line, then CRLF. The matched region is CRLF,
        // so the replacement's newlines become CRLF even though the file also
        // contains an LF line.
        let p = read_fixture(&dir, "mix2.txt", "a\nb\r\nc\r\n");
        edit_file(&json!({ "path": p, "old_string": "b\nc", "new_string": "x\ny" })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\nx\r\ny\r\n");
    }

    #[test]
    fn edit_fails_when_file_changes_mid_call() {
        let dir = tempfile::tempdir().unwrap();
        // If the file on disk no longer matches the bytes the edit was planned
        // against when the rename is about to commit, the write must fail rather
        // than clobber the newer content. (The mid-call window is exercised here
        // by changing the file after read_file but before the edit's re-check.)
        let p = read_fixture(&dir, "race.txt", "one\ntwo\n");
        std::fs::write(&p, "one\nCHANGED\n").unwrap();
        let err = edit_file(&json!({ "path": p, "old_string": "two", "new_string": "2" })).unwrap_err().to_string();
        assert!(err.contains("changed"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "one\nCHANGED\n");
    }

    #[test]
    fn prefix_shaped_new_string_in_copied_range_is_rejected() {
        let dir = tempfile::tempdir().unwrap();
        // old copies read_file's numbered line `     1\tabc`; new carries a
        // prefix-shaped line whose number (1) falls in old's copied range. That
        // form is ambiguous — is `1` copied metadata or an intended TSV cell? —
        // so rather than silently strip the field the edit is rejected with
        // guidance, and the file is left untouched.
        let p = read_fixture(&dir, "amb.tsv", "abc\ndef\n");
        let err = edit_file(&json!({ "path": p, "old_string": "     1\tabc", "new_string": "     1\txyz" }))
            .unwrap_err()
            .to_string();
        assert!(err.contains("ambiguous"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "abc\ndef\n");
    }

    #[test]
    fn old_matching_both_ending_styles_is_not_treated_as_unique() {
        let dir = tempfile::tempdir().unwrap();
        // The file holds an LF block `a\nb` and a CRLF block `a\r\nb`, which
        // read_file displays identically. `old = "a\nb"` therefore matches twice
        // — once per representation — and must not be treated as unique (which
        // would edit only the LF block).
        let p = read_fixture(&dir, "both.txt", "a\nb\na\r\nb\r\n");
        let err = edit_file(&json!({ "path": p, "old_string": "a\nb", "new_string": "x\ny" })).unwrap_err().to_string();
        assert!(err.contains("occurs 2 times"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\nb\na\r\nb\r\n");
    }

    #[test]
    fn replace_all_normalizes_each_occurrence_to_its_own_region() {
        let dir = tempfile::tempdir().unwrap();
        // A single-line `old` occurs in both an LF and a CRLF region. The
        // multiline replacement must be normalized per occurrence: LF for the
        // first, CRLF for the second, not one style applied to both.
        let p = read_fixture(&dir, "ra.txt", "mark\nmark\r\n");
        edit_file(&json!({ "path": p, "old_string": "mark", "new_string": "x\ny", "replace_all": true })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "x\ny\nx\r\ny\r\n");
    }

    #[test]
    fn overlapping_crlf_and_lf_ranges_are_one_occurrence() {
        let dir = tempfile::tempdir().unwrap();
        // In `a\r\nb`, `old = "\nb"` matches both the CRLF form `\r\nb` (1..4)
        // and its literal `\nb` suffix (2..4) — the SAME occurrence. These
        // overlapping cross-representation ranges must be coalesced: not counted
        // as two (a false ambiguity) and not rebuilt as-is under `replace_all`,
        // which would slice `text[end..start]` and panic.
        let p = read_fixture(&dir, "ov.txt", "a\r\nb");
        edit_file(&json!({ "path": p, "old_string": "\nb", "new_string": "\nB", "replace_all": true })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\r\nB");
    }

    #[test]
    fn crossing_crlf_and_lf_ranges_are_ambiguous_not_collapsed() {
        let dir = tempfile::tempdir().unwrap();
        // In `a\r\na\na`, `old = "a\na"` matches the CRLF form `a\r\na` (0..4)
        // and the literal LF form `a\na` (3..6). These CROSS (3 < 4 < 6) without
        // one containing the other, so they are two DISTINCT overlapping
        // occurrences — not one. They must not be silently collapsed to a single
        // match (which would edit the wrong occurrence, or panic under
        // `replace_all` slicing `text[4..3]`); the edit must be rejected as
        // ambiguous instead.
        let p = read_fixture(&dir, "cross.txt", "a\r\na\na");
        let err =
            edit_file(&json!({ "path": p, "old_string": "a\na", "new_string": "X", "replace_all": true })).unwrap_err();
        assert!(err.to_string().contains("ambiguously"), "unexpected error: {err}");
        // The file is left untouched.
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "a\r\na\na");
    }

    #[test]
    fn literal_prefix_shaped_row_is_edited_in_place_not_rejected() {
        let dir = tempfile::tempdir().unwrap();
        // The file literally contains a padded, prefix-shaped TSV row. Replacing
        // it with another prefix-shaped row is a valid EXACT edit: the literal
        // text matches before any line-number-stripped candidate is built, so
        // the strip's ambiguity check must not reject it.
        let p = read_fixture(&dir, "tsv.txt", "     1\tabc\n");
        edit_file(&json!({ "path": p, "old_string": "     1\tabc", "new_string": "     1\txyz" })).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "     1\txyz\n");
    }

    #[test]
    fn near_miss_qualifies_a_truncated_scan() {
        // With more candidate windows than the scan cap, the hint must not claim
        // a global closest match — it qualifies with the scanned range so a near
        // match past the boundary is not implied to be absent.
        let big: String = (0..3000).map(|i| format!("line{i}\n")).collect();
        let hint = near_miss(&big, "line");
        assert!(hint.contains("scanned"), "{hint}");
    }

    fn temp_file_present(dir: &Path, name: &str) -> bool {
        let prefix = format!(".{name}.tmp-");
        std::fs::read_dir(dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .any(|e| e.file_name().to_string_lossy().starts_with(&prefix))
    }

    #[test]
    fn absent_target_write_refuses_to_clobber_a_concurrent_create() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("race.txt");
        // The write was planned against an absent target, but the file now exists
        // (a concurrent create). The no-replace commit must refuse rather than
        // silently overwrite the newer file, and must not leak its temp file.
        std::fs::write(&path, "created by someone else\n").unwrap();
        let err = write_atomically(&path, "our contents\n", Expect::Absent).unwrap_err().to_string();
        assert!(err.contains("was created while"), "{err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "created by someone else\n");
        assert!(!temp_file_present(dir.path(), "race.txt"), "temp file leaked");
    }

    #[test]
    fn failed_pre_rename_validation_removes_the_temp_file() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("t.txt");
        std::fs::write(&path, "on disk\n").unwrap();
        remember(&path, b"on disk\n");
        // The bytes the write was planned against differ from what is on disk, so
        // the pre-rename validation fails — and the temp file it wrote must be
        // cleaned up rather than left behind under its predictable name.
        let err = write_atomically(&path, "new\n", Expect::Bytes(b"planned-against\n")).unwrap_err().to_string();
        assert!(err.contains("changed while"), "{err}");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "on disk\n");
        assert!(!temp_file_present(dir.path(), "t.txt"), "temp file leaked");
    }

    #[test]
    fn line_number_prefix_requires_exact_six_wide_rendering() {
        // `read_file` renders the prefix as `{:>6}\t`, e.g. `     2\t` (five spaces).
        // A zero-padded or over-padded field is not something `read_file` emits, so
        // it must not be stripped as a line-number prefix (which could retarget an
        // unrelated `foo`).
        assert!(strip_line_numbers("000002\tfoo\n", "bar\n").unwrap().is_none());
        assert!(strip_line_numbers("      2\tfoo\n", "bar\n").unwrap().is_none());
        // The exact `{:>6}` rendering is still recognized and stripped.
        let (old, _new, lo) = strip_line_numbers("     2\tfoo\n", "bar\n").unwrap().unwrap();
        assert_eq!(lo, 2);
        assert_eq!(old, "foo\n");
    }

    #[test]
    fn line_number_prefix_at_u64_max_does_not_overflow() {
        // A prefix-shaped line whose number is `u64::MAX` parses and renders to
        // itself (20 digits, no padding), so it reaches the consecutiveness check.
        // A following line must not trigger `max + 1` overflow (which panics in
        // debug builds); it should simply be treated as non-consecutive.
        assert!(
            strip_line_numbers("18446744073709551615\tfoo\n18446744073709551615\tbar\n", "baz\n").unwrap().is_none()
        );
    }

    #[test]
    fn relaxed_matching_rejects_ambiguity_across_attempts() {
        let dir = tempfile::tempdir().unwrap();
        // Line 1 is a prefix-shaped row that matches the literal `old_string` once
        // trailing whitespace is trimmed; line 2 matches the line-number-stripped
        // form (`foo`). Two distinct valid interpretations must be rejected rather
        // than silently resolved to the first attempt.
        let p = read_fixture(&dir, "amb.txt", "     2\tfoo\nfoo\n");
        let err = edit_file(&json!({
            "path": p, "old_string": "     2\tfoo   ", "new_string": "bar"
        }))
        .unwrap_err()
        .to_string();
        assert!(err.contains("multiple distinct locations"), "{err}");
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "     2\tfoo\nfoo\n");
    }
}
