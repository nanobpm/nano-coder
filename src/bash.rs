//! Bash tool: runs a command with a timeout, captures stdout/stderr to files,
//! and returns bounded model-facing text.
//!
//! Result formatting follows unreal-agent's `harness/tool/bash`
//! (MIT, Copyright (c) 2026 Unreal Labs).

use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::output::{self, MAX_OUTPUT_LENGTH, Spill};
use crate::sandbox::{self, SandboxConfig};
use crate::tools::ToolDefinition;

pub const DEFAULT_TIMEOUT_SECS: u64 = 600;

#[derive(Debug, Clone)]
pub struct BashConfig {
    pub shell: String,
    pub working_dir: Option<PathBuf>,
    /// Directory for stdout/stderr captures that were truncated.
    pub output_dir: PathBuf,
    pub default_timeout: Duration,
    /// Set to kill the running command (turn cancellation).
    pub cancel: Option<Arc<AtomicBool>>,
    /// OS sandbox for the command (see `sandbox.rs`).
    pub sandbox: SandboxConfig,
    /// When set, overrides `output_dir` (the agent's per-session spill dir).
    pub shared_output_dir: Option<Arc<std::sync::RwLock<PathBuf>>>,
    /// When set, each `run`/`run_digest` call replaces the contents with the
    /// [`Spill`] identity (digest + exact marker path) of each capture it
    /// truncated and spilled, so the caller (the agent's loop detector) gets
    /// the spills' identity **out of band** instead of re-parsing the rendered
    /// markers (issue #65).
    pub spill_digests: Option<Arc<std::sync::Mutex<Vec<Spill>>>>,
}

impl Default for BashConfig {
    fn default() -> Self {
        Self {
            shell: "bash".into(),
            working_dir: None,
            output_dir: output::spill_dir(),
            default_timeout: Duration::from_secs(DEFAULT_TIMEOUT_SECS),
            cancel: None,
            sandbox: SandboxConfig::default(),
            shared_output_dir: None,
            spill_digests: None,
        }
    }
}

static CALL_COUNTER: AtomicU64 = AtomicU64::new(0);

pub fn definition() -> ToolDefinition {
    ToolDefinition::new(
        "bash",
        "Run a shell command with `bash -c` and return its stdout, stderr and exit code. \
         Long output is truncated to its head and tail; the complete output is saved to a file whose path is included.",
        json!({
            "type": "object",
            "properties": {
                "command": { "type": "string", "description": "Command to run" },
                "timeout_seconds": {
                    "type": "integer",
                    "description": format!("Kill the command after this many seconds (default {DEFAULT_TIMEOUT_SECS})")
                },
                "max_output_length": {
                    "type": "integer",
                    "description": format!(
                        "Maximum characters of stdout and of stderr to return (default {}, max {MAX_OUTPUT_LENGTH})",
                        output::DEFAULT_MAX_OUTPUT_LENGTH
                    )
                }
            },
            "required": ["command"]
        }),
    )
}

struct Arguments {
    command: String,
    timeout: Duration,
    limit: usize,
}

fn validate(config: &BashConfig, args: &Value) -> Result<Arguments, String> {
    let object = args.as_object().ok_or_else(|| format!("bash arguments must be a JSON object, got {args}"))?;
    let limit =
        output::parse_max_output_length(object.get("max_output_length")).map_err(|e| format!("bash argument: {e}"))?;
    let command = match object.get("command") {
        None => return Err(r#"bash argument "command" must be set"#.into()),
        Some(Value::String(command)) => command.clone(),
        Some(_) => return Err(r#"bash argument "command" must be a string"#.into()),
    };
    if let Some(offset) = command.find('\0') {
        return Err(format!(r#"bash argument "command" contains a NUL byte at offset {offset}"#));
    }
    let timeout = match object.get("timeout_seconds") {
        None | Some(Value::Null) => config.default_timeout,
        Some(value) => match value.as_u64() {
            Some(seconds) if seconds > 0 => Duration::from_secs(seconds),
            _ => return Err("timeout_seconds must be a positive integer".into()),
        },
    };
    Ok(Arguments { command, timeout, limit })
}

/// Execute a bash tool call and return the model-facing result text.
pub fn run(config: &BashConfig, args: &Value) -> String {
    run_digest(config, args).0
}

/// [`run`], also returning the [`Spill`] identity (digest + exact marker path)
/// of each capture that was truncated and spilled (stdout first, then stderr),
/// so the caller can hand the loop detector the spills' identity **out of
/// band** instead of the detector re-parsing the rendered markers (issue #65).
pub fn run_digest(config: &BashConfig, args: &Value) -> (String, Vec<Spill>) {
    let arguments = match validate(config, args) {
        Ok(arguments) => arguments,
        Err(message) => {
            return (format!("Error: {}", output::bound_output(&message, output::DEFAULT_MAX_OUTPUT_LENGTH).0), Vec::new());
        }
    };
    match execute(config, &arguments) {
        Ok(done) => {
            if let Some(slot) = &config.spill_digests {
                *slot.lock().unwrap() = done.spills.clone();
            }
            (done.text, done.spills)
        }
        Err(message) => (format!("Error: {message}"), Vec::new()),
    }
}

/// The model-facing result text plus the identity of each spilled capture.
struct Executed {
    text: String,
    /// The [`Spill`] identity of each truncated capture (stdout, then stderr).
    spills: Vec<Spill>,
}

fn execute(config: &BashConfig, arguments: &Arguments) -> Result<Executed, String> {
    let output_dir = match &config.shared_output_dir {
        Some(shared) => shared.read().unwrap().clone(),
        None => config.output_dir.clone(),
    };
    fs::create_dir_all(&output_dir).map_err(|e| format!("create output directory {}: {e}", output_dir.display()))?;
    // Reserve a per-call output basename without overwriting spills from an
    // earlier run of a resumed session. Their paths are still referenced by
    // logged tool results, so reusing bash-1 again after a restart (when the
    // in-process CALL_COUNTER restarts at zero) would corrupt those "complete
    // output" files. Probe increasing indices with create_new, skipping any
    // that already exist, so a resumed session continues past the highest
    // existing spill instead of clobbering a live name.
    let (out_file, err_file, out_path, err_path) = loop {
        let call = CALL_COUNTER.fetch_add(1, Ordering::SeqCst) + 1;
        let out_path = output_dir.join(format!("bash-{call}.stdout"));
        let err_path = output_dir.join(format!("bash-{call}.stderr"));
        let out_file = match File::create_new(&out_path) {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(format!("create {}: {e}", out_path.display())),
        };
        match File::create_new(&err_path) {
            Ok(err_file) => break (out_file, err_file, out_path, err_path),
            // The stdout name was free but the stderr one was not (e.g. a
            // half-written pair left by a crash): drop the file we just made
            // and advance rather than leaking it.
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                drop(out_file);
                let _ = fs::remove_file(&out_path);
                continue;
            }
            Err(e) => return Err(format!("create {}: {e}", err_path.display())),
        }
    };

    let cwd = match &config.working_dir {
        Some(dir) => dir.clone(),
        None => std::env::current_dir().map_err(|e| format!("working directory: {e}"))?,
    };
    // Keeps the Linux ruleset open until the child has been spawned.
    let mut sandboxed = None;
    let mut plain;
    let command = if config.sandbox.active() {
        &mut sandboxed.insert(sandbox::command(&config.sandbox, &config.shell, &arguments.command, &cwd)?).command
    } else {
        plain = Command::new(&config.shell);
        plain.arg("-c").arg(&arguments.command);
        &mut plain
    };
    command
        .current_dir(&cwd)
        .stdin(Stdio::null())
        .stdout(out_file)
        .stderr(err_file)
        // Own process group so a timeout kills the whole pipeline.
        .process_group(0);
    // Open the capture readers *before* spawning the child. These opens are
    // fallible; doing them after spawn would let a failure (`?`) return while
    // the child keeps running outside timeout/cancellation supervision — a
    // leaked process group. The capture files already exist (created above), so
    // the readers can be opened up front, after which no fallible step stands
    // between spawn and the supervision loop.
    //
    // Digest the captures incrementally *while the command runs* (not in a single
    // post-exit reread): a command emitting many gigabytes must not keep the tool
    // blocked re-hashing the whole file after it exits, yet the digest must cover
    // the *complete* content so two captures that differ only in a truncated
    // middle stay distinct and are never hard-stopped as a false loop (issue #65).
    let mut out_hash = CaptureHasher::open(&out_path).map_err(|e| format!("read {}: {e}", out_path.display()))?;
    let mut err_hash = CaptureHasher::open(&err_path).map_err(|e| format!("read {}: {e}", err_path.display()))?;
    let mut child = command.spawn().map_err(|e| format!("spawn {}: {e}", config.shell))?;
    drop(sandboxed);

    let started = Instant::now();
    let mut poll = Duration::from_millis(5);
    let cancelled = || config.cancel.as_ref().is_some_and(|flag| flag.load(Ordering::SeqCst));
    let mut was_cancelled = false;
    let (status, timed_out) = loop {
        match child.try_wait() {
            Ok(Some(status)) => break (status, false),
            Ok(None) if started.elapsed() >= arguments.timeout || cancelled() => {
                was_cancelled = cancelled();
                // SAFETY: killpg only sends a signal to the child's process group.
                unsafe { libc::killpg(child.id() as libc::pid_t, libc::SIGKILL) };
                let status = child.wait().map_err(|e| format!("wait: {e}"))?;
                break (status, !was_cancelled);
            }
            Ok(None) => {
                // Consume whatever the command has appended so the post-exit
                // catch-up never has to re-read more than one poll interval of
                // output. Ignore read errors here; the final drain reports them.
                let _ = out_hash.drain();
                let _ = err_hash.drain();
                std::thread::sleep(poll);
                poll = (poll * 2).min(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("wait: {e}")),
        }
    };

    let (out_digest, out_len) = out_hash.finish().map_err(|e| format!("read {}: {e}", out_path.display()))?;
    let (err_digest, err_len) = err_hash.finish().map_err(|e| format!("read {}: {e}", err_path.display()))?;
    let (stdout, out_truncated) = read_bounded(&out_path, arguments.limit, &out_digest, out_len)?;
    let (stderr, err_truncated) = read_bounded(&err_path, arguments.limit, &err_digest, err_len)?;
    let sandbox_denied = config.sandbox.active()
        && ["Operation not permitted", "Read-only file system", "Permission denied"]
            .iter()
            .any(|d| stderr.contains(d) || stdout.contains(d));
    for (path, truncated) in [(&out_path, out_truncated), (&err_path, err_truncated)] {
        if !truncated {
            let _ = fs::remove_file(path);
        }
    }

    let mut parts = Vec::new();
    if !stdout.is_empty() {
        parts.push(stdout);
    }
    if !stderr.is_empty() {
        parts.push(format!("Stderr:\n{stderr}"));
    }
    // Hand the loop detector each spilled capture's identity (digest + exact
    // marker path) out of band, so it never has to re-parse the rendered
    // markers to tell two captures apart.
    let mut spills = Vec::new();
    if out_truncated {
        spills.push(Spill { digest: out_digest.clone(), path: out_path.display().to_string() });
    }
    if err_truncated {
        spills.push(Spill { digest: err_digest.clone(), path: err_path.display().to_string() });
    }
    if was_cancelled {
        parts.push("Error: the turn was cancelled; the command was killed".into());
    } else if timed_out {
        parts.push(format!("Error: command timed out after {}s and was killed", arguments.timeout.as_secs()));
    } else if let Some(code) = status.code() {
        if code != 0 {
            parts.push(format!("Exit code: {code}"));
            if sandbox_denied {
                parts.push(format!("Note: {}.", config.sandbox.describe(&cwd)));
            }
        }
    } else if let Some(signal) = status.signal() {
        parts.push(format!("Terminated by signal {signal}"));
    }
    if parts.is_empty() {
        return Ok(Executed { text: "(no output)".into(), spills });
    }
    Ok(Executed { text: parts.join("\n"), spills })
}

/// Read a capture file, reading only its head and tail when it is large. The
/// `digest` — a hex SHA-256 of the capture's complete content, computed
/// incrementally while the command ran (see [`CaptureHasher`]) — is embedded in
/// the spill marker so the loop detector can distinguish two captures whose
/// bounded head, tail and byte count match but whose (possibly truncated-away)
/// content differs. The head/tail reads here stay O(window) regardless of how
/// large the capture grew.
///
/// `frozen_len` is the capture length [`CaptureHasher::finish`] snapshotted and
/// hashed. A background descendant can still be appending to the file, so this
/// reads **only up to `frozen_len`** — never the live, still-growing length —
/// keeping the digest, the byte count in the marker, and the head/tail the
/// model sees all covering the same bytes (issue #65).
fn read_bounded(path: &Path, limit: usize, digest: &str, frozen_len: u64) -> Result<(String, bool), String> {
    let describe = |e: std::io::Error| format!("read {}: {e}", path.display());
    let mut file = File::open(path).map_err(describe)?;
    let window = (limit as u64).saturating_mul(4); // UTF-8 is at most 4 bytes per char.
    let display = path.display().to_string();
    if frozen_len <= window.saturating_mul(2) {
        let mut bytes = Vec::with_capacity(frozen_len as usize);
        file.take(frozen_len).read_to_end(&mut bytes).map_err(describe)?;
        let text = String::from_utf8_lossy(&bytes);
        if text.chars().count() <= limit {
            return Ok((text.into_owned(), false));
        }
        return Ok(output::bound_parts(&text, Some(&text), frozen_len, limit, Some(&display), Some(digest)));
    }
    let mut head = vec![0; window as usize];
    file.read_exact(&mut head).map_err(describe)?;
    // The tail is the last `window` bytes of the *frozen* prefix, not of the
    // (possibly still-growing) file.
    file.seek(SeekFrom::Start(frozen_len - window)).map_err(describe)?;
    let mut tail = Vec::with_capacity(window as usize);
    file.take(window).read_to_end(&mut tail).map_err(describe)?;
    Ok(output::bound_parts(
        &String::from_utf8_lossy(&head),
        Some(&String::from_utf8_lossy(&tail)),
        frozen_len,
        limit,
        Some(&display),
        Some(digest),
    ))
}

/// Digests a capture file's complete content incrementally, as the command
/// appends to it, so the marker digest never costs an unbounded post-exit reread
/// of a multi-gigabyte capture yet still covers every byte (issue #65). Each
/// [`drain`](Self::drain) hashes only the bytes written since the previous call,
/// so the work is spread across the command's lifetime and the final post-exit
/// catch-up in [`finish`](Self::finish) is bounded by one poll interval of
/// output. Truncated to 16 hex chars (64 bits) to match the bounder's marker.
struct CaptureHasher {
    file: File,
    hasher: sha2::Sha256,
    /// Total bytes hashed so far — equal to the file offset the next drain
    /// resumes from, and the lower bound each drain stops relative to.
    hashed: u64,
}

impl CaptureHasher {
    fn open(path: &Path) -> std::io::Result<Self> {
        use sha2::Digest;
        Ok(Self { file: File::open(path)?, hasher: sha2::Sha256::new(), hashed: 0 })
    }

    /// Hash everything appended since the last drain, but never past the file
    /// length observed *at entry*. A high-throughput or backgrounded producer
    /// can keep the capture growing so that every `read` returns data; draining
    /// until a 0-length read could then monopolise the caller's poll loop
    /// forever and starve the timeout / cancellation checks (issue #65).
    /// Bounding each drain to the entry-time length guarantees it hands control
    /// back after a finite amount of work; the kept offset lets the next drain
    /// resume at the newly written bytes. Returns the entry-time length the
    /// drain stopped at.
    fn drain(&mut self) -> std::io::Result<u64> {
        use sha2::Digest;
        let target = self.file.metadata()?.len();
        let mut buf = [0u8; 65536];
        while self.hashed < target {
            let want = (target - self.hashed).min(buf.len() as u64) as usize;
            let n = self.file.read(&mut buf[..want])?;
            if n == 0 {
                break; // truncated vs. the snapshot; next drain re-checks the length
            }
            self.hasher.update(&buf[..n]);
            self.hashed += n as u64;
        }
        Ok(target)
    }

    /// Finalise the digest and return it with the **frozen** capture length it
    /// covers. The module intentionally returns while background descendants
    /// may still hold stdout/stderr (see
    /// `kills_on_timeout_without_waiting_for_background_children`), so such a
    /// writer can append after this final drain; the returned length is the
    /// single boundary both the digest and the bounded read honour, so the
    /// digest always covers exactly the bytes the model can see and a late
    /// append can never desync the two (issue #65).
    fn finish(mut self) -> std::io::Result<(String, u64)> {
        use sha2::Digest;
        let frozen = self.drain()?; // final catch-up for bytes written since the last poll
        Ok((output::short_digest(self.hasher.finalize()), frozen))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> (tempfile::TempDir, BashConfig) {
        let dir = tempfile::tempdir().unwrap();
        let config = BashConfig {
            output_dir: dir.path().join("out"),
            working_dir: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        (dir, config)
    }

    #[test]
    fn formats_stdout_stderr_and_exit_code() {
        let (_dir, config) = config();
        assert_eq!(run(&config, &json!({"command": "echo hi"})), "hi\n");
        assert_eq!(run(&config, &json!({"command": "true"})), "(no output)");
        assert_eq!(
            run(&config, &json!({"command": "echo out; echo err >&2; exit 3"})),
            "out\n\nStderr:\nerr\n\nExit code: 3"
        );
    }

    #[test]
    fn validates_arguments() {
        let (_dir, config) = config();
        assert_eq!(run(&config, &json!({})), r#"Error: bash argument "command" must be set"#);
        assert!(run(&config, &json!({"command": "a\u{0}b"})).contains("NUL byte at offset 1"));
        assert!(run(&config, &json!("{bad")).starts_with("Error: bash arguments must be a JSON object"));
        assert!(run(&config, &json!({"command": "ls", "max_output_length": 0})).starts_with("Error:"));
    }

    #[test]
    fn truncates_and_keeps_full_capture() {
        let (_dir, config) = config();
        let result = run(&config, &json!({"command": "seq 1 100000", "max_output_length": 20}));
        assert!(result.starts_with("1\n2\n3\n4\n5\n"), "{result}");
        assert!(result.ends_with("...99\n100000\n"), "{result}");
        let path = result.split("complete output in ").nth(1).and_then(|rest| rest.split("...").next()).unwrap();
        assert_eq!(fs::read_to_string(path).unwrap().lines().count(), 100000);
        // Untruncated stderr capture is cleaned up.
        assert!(!Path::new(&path.replace(".stdout", ".stderr")).exists());
    }

    #[test]
    fn kills_on_timeout_without_waiting_for_background_children() {
        let (_dir, config) = config();
        let started = Instant::now();
        let result = run(&config, &json!({"command": "echo start; sleep 30 | cat", "timeout_seconds": 1}));
        assert!(started.elapsed() < Duration::from_secs(5));
        assert!(result.contains("start"), "{result}");
        assert!(result.contains("timed out after 1s"), "{result}");
        // A backgrounded process holding stdout does not block completion.
        let started = Instant::now();
        assert_eq!(run(&config, &json!({"command": "sleep 5 & echo done"})), "done\n");
        assert!(started.elapsed() < Duration::from_secs(3));
    }

    #[test]
    fn marker_digest_covers_the_complete_capture() {
        // The marker digest must cover the *whole* capture — computed
        // incrementally so a multi-GB capture never forces an unbounded
        // post-exit reread (issue #65). Two captures that share an arbitrarily
        // long head and tail but differ only in a truncated-away middle must
        // therefore produce *different* digests, so genuinely changing output is
        // never hard-stopped as a false loop.
        let dir = tempfile::tempdir().unwrap();
        let big = 4 * 1024 * 1024; // larger than any single read chunk
        let head = vec![b'h'; big];
        let tail = vec![b't'; big];
        let build = |mid: u8| {
            let mut v = head.clone();
            v.push(mid);
            v.extend_from_slice(&tail);
            v
        };
        let a = dir.path().join("a.stdout");
        let b = dir.path().join("b.stdout");
        fs::write(&a, build(b'A')).unwrap();
        fs::write(&b, build(b'B')).unwrap();
        let digest = |p: &Path| CaptureHasher::open(p).unwrap().finish().unwrap().0;
        // Same head and tail, one differing middle byte => distinct digests.
        assert_ne!(digest(&a), digest(&b));
        // Identical content => identical digest (genuine repeats stay detectable).
        let a2 = dir.path().join("a2.stdout");
        fs::write(&a2, build(b'A')).unwrap();
        assert_eq!(digest(&a), digest(&a2));
    }

    #[test]
    fn incremental_digest_matches_a_whole_file_hash() {
        // Draining in pieces as the file grows must yield the same digest as a
        // single pass over the finished file: the loop detector relies on the
        // marker digest being a stable function of the complete content.
        use sha2::Digest;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("grow.stdout");
        // Start empty, then append in two bursts while draining between them.
        fs::write(&path, b"").unwrap();
        let mut cap = CaptureHasher::open(&path).unwrap();
        let mut f = fs::OpenOptions::new().append(true).open(&path).unwrap();
        use std::io::Write;
        f.write_all(b"first burst of output\n").unwrap();
        cap.drain().unwrap();
        f.write_all(b"second burst, much longer").unwrap();
        let incremental = cap.finish().unwrap().0;
        let whole = output::short_digest(sha2::Sha256::digest(fs::read(&path).unwrap()));
        assert_eq!(incremental, whole);
    }

    #[test]
    fn drain_never_reads_past_the_length_seen_at_entry() {
        // A producer that keeps appending must not trap `drain` in an unbounded
        // read loop: each drain stops at the length observed when it started, so
        // the poll loop always regains control to run the timeout / cancellation
        // checks (issue #65). The kept offset makes the next drain resume at the
        // delta, and the running digest still equals a single whole-file pass.
        use sha2::Digest;
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("grow.stdout");
        fs::write(&path, b"").unwrap();
        let mut cap = CaptureHasher::open(&path).unwrap();
        let mut f = fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(&vec![b'x'; 10_000]).unwrap();
        cap.drain().unwrap();
        assert_eq!(cap.hashed, 10_000, "drain must consume exactly the entry-time length");
        f.write_all(&vec![b'y'; 5_000]).unwrap();
        cap.drain().unwrap();
        assert_eq!(cap.hashed, 15_000, "the next drain resumes at the newly written delta");
        let incremental = cap.finish().unwrap().0;
        let whole = output::short_digest(sha2::Sha256::digest(fs::read(&path).unwrap()));
        assert_eq!(incremental, whole);
    }

    #[test]
    fn read_bounded_honours_the_frozen_length_not_the_growing_file() {
        // The finding this closes (issue #65): the module intentionally returns
        // while a background descendant may still hold the capture open, so such
        // a writer can append after `finish()` snapshots the digest's length.
        // `read_bounded` must read only up to that frozen length, so the digest,
        // the marker's byte count, and the head/tail the model sees all cover
        // the same bytes — a late append must never desync them.
        use sha2::Digest;
        use std::io::Write;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("capture.stdout");
        fs::write(&path, b"").unwrap();
        let cap = CaptureHasher::open(&path).unwrap();
        let mut f = fs::OpenOptions::new().append(true).open(&path).unwrap();
        f.write_all(&vec![b'A'; 10_000]).unwrap();
        // finish() freezes the digest at the 10_000-byte boundary...
        let (digest, frozen_len) = cap.finish().unwrap();
        assert_eq!(frozen_len, 10_000);
        // ...then a background writer appends more. The sentinel byte must be
        // one that can appear in neither the A-filled frozen prefix nor the
        // spill marker's own text — which embeds the capture's *path*, whose
        // random tempdir component is alphanumeric — so use a non-alphanumeric
        // byte (`~`); a letter/digit sentinel would collide with the path and
        // flake (issue #65).
        f.write_all(&vec![b'~'; 5_000]).unwrap();
        assert_eq!(fs::metadata(&path).unwrap().len(), 15_000, "the file kept growing after finish");
        // read_bounded must honour the frozen boundary: the digest covers
        // exactly the bytes read (the 10_000 A's), not the later `~`s. Use a
        // frozen length beyond the head window (4 * limit) so the marker's tail
        // is drawn from the frozen prefix, not the still-growing file.
        let (text, truncated) = read_bounded(&path, 1_000, &digest, frozen_len).unwrap();
        assert!(truncated, "10_000 bytes over a 1_000-char limit must spill");
        assert!(text.contains('A'), "{text}");
        // No `~` byte from the late append appears in the head or tail.
        assert!(!text.contains('~'), "the late append must not be read: {text}");
        // The marker reports the frozen byte count, not the grown file's.
        assert!(text.contains("9000 bytes truncated"), "{text}");
        assert!(!text.contains("14000 bytes truncated"), "{text}");
        // The digest matches the frozen prefix, not the grown file.
        let frozen_prefix = output::short_digest(sha2::Sha256::digest(vec![b'A'; 10_000]));
        assert_eq!(digest, frozen_prefix);
    }
}
