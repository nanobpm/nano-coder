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

use crate::output::{self, MAX_OUTPUT_LENGTH};
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
}

impl Default for BashConfig {
    fn default() -> Self {
        Self {
            shell: "bash".into(),
            working_dir: None,
            output_dir: output::spill_dir(),
            default_timeout: Duration::from_secs(DEFAULT_TIMEOUT_SECS),
            cancel: None,
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
    let object = args
        .as_object()
        .ok_or_else(|| format!("bash arguments must be a JSON object, got {args}"))?;
    let limit = output::parse_max_output_length(object.get("max_output_length")).map_err(|e| format!("bash argument: {e}"))?;
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
    let arguments = match validate(config, args) {
        Ok(arguments) => arguments,
        Err(message) => return format!("Error: {}", output::bound_output(&message, output::DEFAULT_MAX_OUTPUT_LENGTH).0),
    };
    match execute(config, &arguments) {
        Ok(text) => text,
        Err(message) => format!("Error: {message}"),
    }
}

fn execute(config: &BashConfig, arguments: &Arguments) -> Result<String, String> {
    fs::create_dir_all(&config.output_dir)
        .map_err(|e| format!("create output directory {}: {e}", config.output_dir.display()))?;
    let call = CALL_COUNTER.fetch_add(1, Ordering::SeqCst) + 1;
    let out_path = config.output_dir.join(format!("bash-{call}.stdout"));
    let err_path = config.output_dir.join(format!("bash-{call}.stderr"));
    let create = |path: &Path| File::create(path).map_err(|e| format!("create {}: {e}", path.display()));

    let mut command = Command::new(&config.shell);
    command
        .arg("-c")
        .arg(&arguments.command)
        .stdin(Stdio::null())
        .stdout(create(&out_path)?)
        .stderr(create(&err_path)?)
        // Own process group so a timeout kills the whole pipeline.
        .process_group(0);
    if let Some(dir) = &config.working_dir {
        command.current_dir(dir);
    }
    let mut child = command.spawn().map_err(|e| format!("spawn {}: {e}", config.shell))?;

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
                std::thread::sleep(poll);
                poll = (poll * 2).min(Duration::from_millis(50));
            }
            Err(e) => return Err(format!("wait: {e}")),
        }
    };

    let (stdout, out_truncated) = read_bounded(&out_path, arguments.limit)?;
    let (stderr, err_truncated) = read_bounded(&err_path, arguments.limit)?;
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
    if was_cancelled {
        parts.push("Error: the turn was cancelled; the command was killed".into());
    } else if timed_out {
        parts.push(format!(
            "Error: command timed out after {}s and was killed",
            arguments.timeout.as_secs()
        ));
    } else if let Some(code) = status.code() {
        if code != 0 {
            parts.push(format!("Exit code: {code}"));
        }
    } else if let Some(signal) = status.signal() {
        parts.push(format!("Terminated by signal {signal}"));
    }
    if parts.is_empty() {
        return Ok("(no output)".into());
    }
    Ok(parts.join("\n"))
}

/// Read a capture file, reading only its head and tail when it is large.
fn read_bounded(path: &Path, limit: usize) -> Result<(String, bool), String> {
    let describe = |e: std::io::Error| format!("read {}: {e}", path.display());
    let mut file = File::open(path).map_err(describe)?;
    let size = file.metadata().map_err(describe)?.len();
    let window = (limit as u64).saturating_mul(4); // UTF-8 is at most 4 bytes per char.
    let display = path.display().to_string();
    if size <= window.saturating_mul(2) {
        let mut bytes = Vec::with_capacity(size as usize);
        file.read_to_end(&mut bytes).map_err(describe)?;
        let text = String::from_utf8_lossy(&bytes);
        if text.chars().count() <= limit {
            return Ok((text.into_owned(), false));
        }
        return Ok(output::bound_parts(&text, Some(&text), size, limit, Some(&display)));
    }
    let mut head = vec![0; window as usize];
    file.read_exact(&mut head).map_err(describe)?;
    file.seek(SeekFrom::End(-(window as i64))).map_err(describe)?;
    let mut tail = Vec::with_capacity(window as usize);
    file.read_to_end(&mut tail).map_err(describe)?;
    Ok(output::bound_parts(
        &String::from_utf8_lossy(&head),
        Some(&String::from_utf8_lossy(&tail)),
        size,
        limit,
        Some(&display),
    ))
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
        let path = result
            .split("complete output in ")
            .nth(1)
            .and_then(|rest| rest.split("...").next())
            .unwrap();
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
}
