//! Session-scoped timers the agent sets for itself to come back to something
//! later in the session (a CI run, a deploy, a review it is waiting on),
//! alongside memory and the plan. The agent edits them with the `timer_*`
//! tools; the harness owns the clock: due timers are pushed into the
//! conversation as a user message at the start of the next agent step, and
//! every change is recorded in the session log so a `--resume` restores them.

use anyhow::{Result, bail};
use chrono::{DateTime, Duration, Local, NaiveDateTime, NaiveTime, TimeZone};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::tools::ToolDefinition;

/// A timer must be at least this far out: timers are for coming back later.
pub const MIN_DELAY: Duration = Duration::minutes(1);
/// A timer must be at most this far out; beyond that, hand the work to
/// something durable (a workflow engine, cron).
pub const MAX_DELAY: Duration = Duration::hours(24);
/// At most this many timers are active at once.
pub const MAX_TIMERS: usize = 10;
/// A fired timer reports itself as overdue once it is this late.
pub const OVERDUE_AFTER: Duration = Duration::minutes(2);
/// A `note` is clipped to this many characters.
const MAX_NOTE_CHARS: usize = 1_000;
/// A fired timer that has not been marked done nudges the agent every this
/// many steps.
pub const PENDING_NUDGE_EVERY: usize = 5;

pub const TOOL_NAMES: [&str; 4] = ["timer_set", "timer_list", "timer_cancel", "timer_done"];

/// One active timer.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Timer {
    pub id: u32,
    /// Unix seconds when the timer was set.
    pub set_at: i64,
    /// Unix seconds when the timer fires.
    pub due_at: i64,
    pub note: String,
}

/// The session's timers. Ids keep counting across fires, cancels and resume.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Timers {
    #[serde(default)]
    pub last_id: u32,
    #[serde(default)]
    pub items: Vec<Timer>,
    /// Timers that have fired but the agent has not yet marked done; they keep
    /// reminding so a note ignored mid-work is not lost. `due_at` is when the
    /// timer fired.
    #[serde(default)]
    pub pending: Vec<Timer>,
}

/// What a timer tool call did.
#[derive(Debug)]
pub struct Outcome {
    pub text: String,
    pub changed: bool,
}

impl Timers {
    pub fn is_empty(&self) -> bool {
        self.items.is_empty()
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// The soonest due time, for the status line and the `--wait-timers` sleep.
    pub fn next_due(&self) -> Option<DateTime<Local>> {
        self.items.iter().map(due_local).min()
    }

    /// Run a timer tool. A rejected call leaves the timers unchanged.
    pub fn apply(&mut self, tool: &str, args: &Value, now: DateTime<Local>) -> Result<Outcome> {
        match tool {
            "timer_set" => self.set(args, now),
            "timer_list" => Ok(Outcome { text: self.render(now), changed: false }),
            "timer_cancel" => self.cancel(args),
            "timer_done" => self.done(args),
            other => bail!("unknown timer tool {other}"),
        }
    }

    fn set(&mut self, args: &Value, now: DateTime<Local>) -> Result<Outcome> {
        let after = args.get("after").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
        let at = args.get("at").and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty());
        let due = match (after, at) {
            (Some(_), Some(_)) => {
                bail!("give exactly one of `after` (a delay like \"30m\") or `at` (a time like \"14:30\"), not both")
            }
            (Some(delay), None) => now + parse_delay(delay)?,
            (None, Some(at)) => parse_at(at, now)?,
            (None, None) => bail!("give exactly one of `after` (a delay like \"30m\") or `at` (a time like \"14:30\")"),
        };
        let note = args.get("note").and_then(Value::as_str).map(str::trim).unwrap_or_default();
        if note.is_empty() {
            bail!("timer_set needs a `note`: what to do when it fires, written for your future self");
        }
        let delay = due - now;
        if delay < MIN_DELAY {
            bail!(
                "a timer must be at least a minute out: timers are for coming back later; for a command that waits, \
                 run it with bash (e.g. sleep) instead"
            );
        }
        if delay > MAX_DELAY {
            return Err(too_far_ahead());
        }
        if self.items.len() >= MAX_TIMERS {
            bail!("at most {MAX_TIMERS} timers can be active; cancel one with timer_cancel first");
        }
        let id = self.last_id + 1;
        self.last_id = id;
        self.items.push(Timer {
            id,
            set_at: now.timestamp(),
            due_at: due.timestamp(),
            note: clip(note, MAX_NOTE_CHARS),
        });
        Ok(Outcome {
            text: format!(
                "Timer {id} set for {} (in {}). When it fires you'll get its note back as a message.",
                due.format("%H:%M"),
                format_delay(delay)
            ),
            changed: true,
        })
    }

    fn cancel(&mut self, args: &Value) -> Result<Outcome> {
        let Some(id) = args.get("id").and_then(id_of) else {
            bail!("timer_cancel needs the timer `id`");
        };
        if let Some(index) = self.items.iter().position(|t| t.id == id) {
            let timer = self.items.remove(index);
            return Ok(Outcome { text: format!("Cancelled timer {} ({}).", timer.id, timer.note), changed: true });
        }
        // A fired-but-pending timer can also be dropped (the agent won't handle it).
        if let Some(index) = self.pending.iter().position(|t| t.id == id) {
            let timer = self.pending.remove(index);
            return Ok(Outcome {
                text: format!("Cancelled timer {} ({}); it had already fired.", timer.id, timer.note),
                changed: true,
            });
        }
        let ids: Vec<String> = self.items.iter().chain(self.pending.iter()).map(|t| t.id.to_string()).collect();
        if ids.is_empty() {
            bail!("no timer {id}: no timers are set");
        }
        bail!("no timer {id}; active timers are {}", ids.join(", "));
    }

    /// Mark a fired (pending) timer as handled, stopping its reminders.
    fn done(&mut self, args: &Value) -> Result<Outcome> {
        let Some(id) = args.get("id").and_then(id_of) else {
            bail!("timer_done needs the timer `id`");
        };
        if let Some(index) = self.pending.iter().position(|t| t.id == id) {
            let timer = self.pending.remove(index);
            return Ok(Outcome { text: format!("Timer {} marked done.", timer.id), changed: true });
        }
        // Not pending: it may still be ticking (not fired yet) or unknown.
        if self.items.iter().any(|t| t.id == id) {
            bail!("timer {id} hasn't fired yet; to drop it, use timer_cancel");
        }
        let ids: Vec<String> = self.pending.iter().map(|t| t.id.to_string()).collect();
        if ids.is_empty() {
            bail!("no fired timer {id}; none are waiting to be done");
        }
        bail!("no fired timer {id}; waiting to be done: {}", ids.join(", "));
    }

    /// Whether any fired timer is waiting to be marked done.
    pub fn has_pending(&self) -> bool {
        !self.pending.is_empty()
    }

    /// The mid-turn nudge listing fired timers not yet marked done, or `None`.
    pub fn pending_nudge(&self, now: DateTime<Local>) -> Option<String> {
        if self.pending.is_empty() {
            return None;
        }
        let mut pending: Vec<&Timer> = self.pending.iter().collect();
        pending.sort_by_key(|t| t.due_at);
        let mut text = String::from("Fired timers you haven't marked done:");
        for t in pending {
            text.push_str(&format!("\n- {} (fired {} ago): {}", t.id, format_delay(now - due_local(t)), t.note));
        }
        text.push_str(
            "\nHandle them (now, or once the current step is finished) and call timer_done; timer_cancel drops one.",
        );
        Some(text)
    }

    /// One line per timer, pending (fired, not done) first then active, or
    /// `No timers set.`. Notes are rendered verbatim: this feeds the
    /// `timer_list` tool result back to the model, so the model must see the
    /// note exactly as it set it (a sanitizing pass could drop a legitimate
    /// newline). The terminal-facing `/timers` listing sanitizes instead — see
    /// [`render_command`](Self::render_command).
    pub fn render(&self, now: DateTime<Local>) -> String {
        self.render_with(now, |note| note.to_string())
    }

    /// One line per timer with each model-controlled `note` passed through
    /// `note_fmt`. Callers choose the policy: the model-facing [`render`] keeps
    /// notes verbatim; the terminal-facing [`render_command`] sanitizes them.
    fn render_with(&self, now: DateTime<Local>, note_fmt: impl Fn(&str) -> String) -> String {
        if self.items.is_empty() && self.pending.is_empty() {
            return "No timers set.".to_string();
        }
        let mut lines = Vec::new();
        let mut pending: Vec<&Timer> = self.pending.iter().collect();
        pending.sort_by_key(|t| t.due_at);
        for t in pending {
            lines.push(format!(
                "{}. fired at {}, not done yet: {}",
                t.id,
                due_local(t).format("%H:%M"),
                note_fmt(&t.note)
            ));
        }
        let mut timers: Vec<&Timer> = self.items.iter().collect();
        timers.sort_by_key(|t| t.due_at);
        for t in timers {
            lines.push(format!(
                "{}. {} (in {}): {}",
                t.id,
                due_local(t).format("%H:%M"),
                format_delay(due_local(t) - now),
                note_fmt(&t.note)
            ));
        }
        lines.join("\n")
    }

    /// The `/timers` listing: the timers, or how they get set.
    ///
    /// This output reaches the terminal verbatim (`Renderer::print_block` →
    /// `println!` on the plain path), and each `note` is model-controlled, so
    /// sanitize every displayed note — dropping ANSI/OSC control and escape
    /// bytes a terminal would otherwise interpret — exactly as the firing
    /// notification does. The stored note is left intact; only this displayed
    /// copy is sanitized (issue #150).
    pub fn render_command(&self, now: DateTime<Local>) -> String {
        if self.items.is_empty() && self.pending.is_empty() {
            "No timers set. The agent sets one with the timer_set tool.".to_string()
        } else {
            self.render_with(now, crate::sanitize_terminal_line)
        }
    }

    /// Take the timers due at `now` (they fire once), soonest first. Each fired
    /// timer moves into `pending` so it keeps reminding until marked done.
    pub fn take_due(&mut self, now: DateTime<Local>) -> Vec<Timer> {
        let (due, keep): (Vec<Timer>, Vec<Timer>) = self.items.drain(..).partition(|t| t.due_at <= now.timestamp());
        self.items = keep;
        let mut due = due;
        due.sort_by_key(|t| t.due_at);
        self.pending.extend(due.iter().cloned());
        due
    }

    /// The user message one fired timer is wrapped in.
    pub fn fired_message(timer: &Timer, now: DateTime<Local>) -> String {
        let due = due_local(timer);
        let mut text =
            format!("Timer {}, set at {}, fired: {}", timer.id, local_at(timer.set_at).format("%H:%M"), timer.note);
        let late = now - due;
        if late >= OVERDUE_AFTER {
            text.push_str(&format!(
                " (overdue by {}: nano-coder wasn't running when it came due)",
                format_overdue(late)
            ));
        }
        crate::reminders::wrap(&text)
    }

    /// The user message carrying every timer that fired at one step.
    pub fn fired_batch_message(fired: &[Timer], now: DateTime<Local>) -> String {
        let mut text = fired.iter().map(|t| Self::fired_message(t, now)).collect::<Vec<_>>().join("\n");
        text.push_str(
            "\nAct on it now, as the note says, then call timer_done with its id. Until you do, you'll be reminded \
             every few steps.",
        );
        text
    }

    /// The status-line segment: `⏰ HH:MM` for one timer, `⏰ N next HH:MM`
    /// for several; empty when no timer is set.
    pub fn status_segment(&self) -> String {
        match self.next_due() {
            None => String::new(),
            Some(due) if self.items.len() == 1 => format!("⏰ {}", due.format("%H:%M")),
            Some(due) => format!("⏰ {} next {}", self.items.len(), due.format("%H:%M")),
        }
    }
}

/// The due time of a timer as a local timestamp.
fn due_local(timer: &Timer) -> DateTime<Local> {
    local_at(timer.due_at)
}

/// A unix-seconds timestamp as a local timestamp.
fn local_at(secs: i64) -> DateTime<Local> {
    Local.timestamp_opt(secs, 0).single().unwrap_or_else(Local::now)
}

/// Models sometimes send the id as a string ("3"); accept both.
fn id_of(value: &Value) -> Option<u32> {
    match value {
        Value::Number(n) => n.as_u64().and_then(|n| u32::try_from(n).ok()),
        Value::String(s) => s.trim().trim_start_matches('#').parse().ok(),
        _ => None,
    }
}

/// A delay like `90s`, `30m`, `1h30m`, `1.5h`, `2 hours` or a bare number of
/// minutes (`120`).
pub fn parse_delay(text: &str) -> Result<Duration> {
    let text = text.trim().to_ascii_lowercase();
    if text.is_empty() {
        return Err(bad_delay(&text));
    }
    // A bare number is minutes ("120").
    let total = if let Ok(minutes) = text.parse::<f64>() {
        delay_from(minutes, "m", &text)?
    } else {
        let mut total = Duration::zero();
        let mut rest = text.as_str();
        let mut parts = 0;
        while !rest.is_empty() {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit() || *c == '.').collect();
            if digits.is_empty() {
                return Err(bad_delay(&text));
            }
            let amount: f64 = digits.parse().map_err(|_| bad_delay(&text))?;
            rest = &rest[digits.len()..];
            let unit_len = rest.find(char::is_numeric).unwrap_or(rest.len());
            let unit = rest[..unit_len].trim();
            rest = &rest[unit_len..];
            // Accumulate with a checked add so a compound delay far past
            // chrono's range returns the too-far error instead of panicking.
            total = total.checked_add(&delay_from(amount, unit, &text)?).ok_or_else(too_far_ahead)?;
            parts += 1;
        }
        if parts == 0 {
            return Err(bad_delay(&text));
        }
        total
    };
    // Bound the result to 24 hours here, before `now + delay` can overflow
    // chrono's date range (a value like "1000000000000h" would otherwise
    // panic rather than return a tool error).
    if total > MAX_DELAY {
        return Err(too_far_ahead());
    }
    Ok(total)
}

fn delay_from(amount: f64, unit: &str, text: &str) -> Result<Duration> {
    let seconds = match unit {
        "s" | "sec" | "secs" | "second" | "seconds" => amount,
        "m" | "min" | "mins" | "minute" | "minutes" => amount * 60.0,
        "h" | "hr" | "hrs" | "hour" | "hours" => amount * 3_600.0,
        _ => return Err(bad_delay(text)),
    };
    // Accept a zero component (e.g. the `00m` in `1h00m`, the exact form
    // `format_delay` emits for one hour): only a negative, non-finite, or
    // out-of-range value is unparsable. The minimum is enforced by `set` on
    // the *total*, so an all-zero delay still gets the actionable too-soon
    // error rather than a confusing "could not parse" one.
    if !seconds.is_finite() || seconds < 0.0 || seconds > i64::MAX as f64 / 1_000.0 {
        return Err(bad_delay(text));
    }
    Ok(Duration::milliseconds((seconds * 1_000.0).round() as i64))
}

fn bad_delay(text: &str) -> anyhow::Error {
    anyhow::anyhow!(
        "could not parse {text:?} as a delay; use e.g. \"90s\", \"30m\", \"1h30m\", \"1.5h\" or \"2 hours\""
    )
}

/// The "too far ahead" error, shared by delay parsing and the `set` bound.
fn too_far_ahead() -> anyhow::Error {
    anyhow::anyhow!(
        "a timer can be at most 24 hours out; for something further ahead, hand the work to something \
         durable, such as a workflow engine or cron"
    )
}

/// A fire time: `HH:MM` (the next occurrence in local time — tomorrow when
/// already past today) or an ISO date-time; one without an offset is local.
pub fn parse_at(text: &str, now: DateTime<Local>) -> Result<DateTime<Local>> {
    let text = text.trim();
    // HH:MM — the next occurrence in local time.
    if let Ok(time) = NaiveTime::parse_from_str(text, "%H:%M") {
        let today = now.date_naive().and_time(time);
        let day = if now.time() < time { today } else { today + Duration::days(1) };
        return local_naive(day, text);
    }
    // An ISO date-time without an offset is local time; one with an offset
    // (or `Z`) is taken as given. Accept both minute- and second-precision.
    if let Ok(naive) = NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M:%S") {
        return local_naive(naive, text);
    }
    if let Ok(naive) = NaiveDateTime::parse_from_str(text, "%Y-%m-%dT%H:%M") {
        return local_naive(naive, text);
    }
    if let Ok(naive) = NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S") {
        return local_naive(naive, text);
    }
    if let Ok(naive) = NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M") {
        return local_naive(naive, text);
    }
    // ISO date-times carrying an explicit offset. `parse_from_rfc3339` below
    // requires *seconds* and a colon in the offset, so valid forms like
    // `2026-10-26T14:30+02:00` (minute precision), `...+0200` (compact
    // offset), or `2026-10-26T14:30:00+0200` (seconds, compact offset) would
    // otherwise be rejected. A trailing `Z`/`z` is UTC; normalize it to a
    // numeric zero offset so the minute-precision `...Z` form parses too (the
    // original text, including a fractional-second `Z`, still falls through to
    // the RFC3339 fallback below).
    let offset_text = match text.strip_suffix(['Z', 'z']) {
        Some(head) => format!("{head}+0000"),
        None => text.to_string(),
    };
    for fmt in ["%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M%z"] {
        if let Ok(fixed) = DateTime::parse_from_str(&offset_text, fmt) {
            return Ok(fixed.with_timezone(&Local));
        }
    }
    if let Ok(fixed) = DateTime::parse_from_rfc3339(text) {
        return Ok(fixed.with_timezone(&Local));
    }
    Err(anyhow::anyhow!(
        "could not parse {text:?} as a time; use \"HH:MM\" (the next occurrence, local time) or an ISO date-time \
         like \"2026-10-25T14:30\" (local time; append an offset such as \"+02:00\" or \"Z\" to pin the zone)"
    ))
}

/// A naive date-time in local time, rejecting the unresolvable (DST) cases.
fn local_naive(naive: NaiveDateTime, text: &str) -> Result<DateTime<Local>> {
    match naive.and_local_timezone(Local) {
        chrono::LocalResult::Single(local) => Ok(local),
        _ => Err(anyhow::anyhow!("{text:?} is not a valid local time here (a daylight-saving gap or fold)")),
    }
}

/// `30m`, `1h30m`, `2h05m`, `45s` — a delay as the tools render it.
pub fn format_delay(delay: Duration) -> String {
    let seconds = delay.num_seconds().max(0);
    let (hours, minutes, seconds) = (seconds / 3600, seconds % 3600 / 60, seconds % 60);
    let mut out = String::new();
    if hours > 0 {
        out.push_str(&format!("{hours}h"));
        out.push_str(&format!("{minutes:02}m"));
    } else if minutes > 0 {
        out.push_str(&format!("{minutes}m"));
    }
    if hours == 0 && (seconds > 0 || minutes == 0) {
        out.push_str(&format!("{seconds}s"));
    }
    out
}

/// `2:05` — how late a fired timer is, as `H:MM` (or `M:SS` under an hour).
fn format_overdue(late: Duration) -> String {
    let seconds = late.num_seconds().max(0);
    if seconds >= 3600 {
        format!("{}:{:02}", seconds / 3600, seconds % 3600 / 60)
    } else {
        format!("{}:{:02}", seconds / 60, seconds % 60)
    }
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max - 1).collect();
    out.push('…');
    out
}

pub fn is_timer_tool(name: &str) -> bool {
    TOOL_NAMES.contains(&name)
}

pub fn definitions() -> Vec<ToolDefinition> {
    vec![
        ToolDefinition::new(
            "timer_set",
            "Set a timer to come back to something later in this session (a CI run, a deploy, a review you are \
             waiting on). When it fires, its note comes back to you as a message. Timers do not repeat; the session \
             keeps at most 10, from 1 minute to 24 hours out.",
            json!({
                "type": "object",
                "properties": {
                    "after": {
                        "type": "string",
                        "description": "Delay until it fires, e.g. \"30m\", \"1h30m\", \"90s\", \"2 hours\", \"1.5h\". Exactly one of `after`/`at`."
                    },
                    "at": {
                        "type": "string",
                        "description": "Fire time: \"HH:MM\" (next occurrence, local time) or an ISO date-time like \"2026-10-25T14:30\" (local; append an offset such as \"+02:00\" or \"Z\" to pin the zone). Exactly one of `after`/`at`."
                    },
                    "note": {
                        "type": "string",
                        "description": "What to do when it fires, written for your future self"
                    }
                },
                "required": ["note"]
            }),
        ),
        ToolDefinition::new(
            "timer_list",
            "List this session's active timers, soonest first.",
            json!({ "type": "object", "properties": {} }),
        ),
        ToolDefinition::new(
            "timer_cancel",
            "Cancel a timer by its id (one not yet fired, or a fired one you won't handle).",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "description": "The timer id (a string like \"3\" works too)" }
                },
                "required": ["id"]
            }),
        ),
        ToolDefinition::new(
            "timer_done",
            "Mark a fired timer as handled, which stops its reminders.",
            json!({
                "type": "object",
                "properties": {
                    "id": { "type": "integer", "description": "The timer id (a string like \"3\" works too)" }
                },
                "required": ["id"]
            }),
        ),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn at(hour: u32, minute: u32) -> DateTime<Local> {
        let date = Local::now().date_naive();
        Local.from_local_datetime(&date.and_hms_opt(hour, minute, 0).unwrap()).single().unwrap()
    }

    fn set(timers: &mut Timers, args: Value) -> Result<Outcome> {
        timers.apply("timer_set", &args, at(12, 0))
    }

    #[test]
    fn parses_delays() {
        assert_eq!(parse_delay("90s").unwrap(), Duration::seconds(90));
        assert_eq!(parse_delay("30m").unwrap(), Duration::minutes(30));
        assert_eq!(parse_delay("1h30m").unwrap(), Duration::minutes(90));
        assert_eq!(parse_delay("1.5h").unwrap(), Duration::minutes(90));
        // A bare number is minutes.
        assert_eq!(parse_delay("120").unwrap(), Duration::hours(2));
        assert_eq!(parse_delay("2 hours").unwrap(), Duration::hours(2));
        assert_eq!(parse_delay(" 1h 30m ").unwrap(), Duration::minutes(90));
        // Zero-valued components are accepted; the minimum is enforced by
        // `set` on the total, not here. `1h00m` is the exact form
        // `format_delay` emits for one hour, so it must round-trip.
        assert_eq!(parse_delay("1h00m").unwrap(), Duration::hours(1));
        assert_eq!(parse_delay("0h30m").unwrap(), Duration::minutes(30));
        assert_eq!(parse_delay("1h30m0s").unwrap(), Duration::minutes(90));
        // An all-zero delay parses to zero; `set` then rejects it as too soon.
        assert_eq!(parse_delay("0h0m0s").unwrap(), Duration::zero());
        assert_eq!(parse_delay("0").unwrap(), Duration::zero());
    }

    #[test]
    fn rejects_unparsable_delays() {
        for bad in ["soon", "5d", "", "abc", "10x", "h", "1h2"] {
            assert!(parse_delay(bad).is_err(), "{bad}");
        }
        // "5d" parses as a number followed by an unknown unit, not as 5 days.
        assert!(parse_delay("5d").unwrap_err().to_string().contains("5d"));
    }

    #[test]
    fn parses_at_times() {
        // 14:30 later today when it is still ahead.
        let due = parse_at("14:30", at(12, 0)).unwrap();
        assert_eq!(due, at(14, 30));
        // 09:00 is already past at noon, so it means tomorrow. Compare the
        // naive local calendar values (tomorrow's date at 09:00), NOT
        // `at(9, 0) + Duration::days(1)`: that is 24 *elapsed* hours, which a
        // daylight-saving transition shifts off the wall-clock 09:00 the parser
        // correctly returns (e.g. over the Europe/Berlin October fold).
        let now = at(12, 0);
        let due = parse_at("09:00", now).unwrap();
        assert_eq!(due.date_naive(), now.date_naive() + Duration::days(1));
        assert_eq!(due.time(), NaiveTime::from_hms_opt(9, 0, 0).unwrap());
        // An ISO date-time without an offset is local time.
        let due = parse_at("2026-10-25T14:30", at(12, 0)).unwrap();
        assert_eq!(due.format("%Y-%m-%dT%H:%M").to_string(), "2026-10-25T14:30");
        // Seconds-bearing ISO values (with `T` or a space) are accepted too.
        let due = parse_at("2026-10-25T14:30:45", at(12, 0)).unwrap();
        assert_eq!(due.format("%Y-%m-%dT%H:%M:%S").to_string(), "2026-10-25T14:30:45");
        let due = parse_at("2026-10-25 14:30:00", at(12, 0)).unwrap();
        assert_eq!(due.format("%Y-%m-%dT%H:%M:%S").to_string(), "2026-10-25T14:30:00");
        // Offset-bearing ISO date-times (RFC3339 requires seconds and a colon
        // in the offset, so these would otherwise be rejected). The instant is
        // taken as given, so compare in UTC.
        let utc = |t| parse_at(t, at(12, 0)).unwrap().with_timezone(&chrono::Utc);
        // Minute precision, colon offset.
        assert_eq!(utc("2026-10-26T14:30+02:00").format("%Y-%m-%dT%H:%MZ").to_string(), "2026-10-26T12:30Z");
        // Minute precision, compact offset.
        assert_eq!(utc("2026-10-26T14:30+0200").format("%Y-%m-%dT%H:%MZ").to_string(), "2026-10-26T12:30Z");
        // Seconds precision, compact offset.
        assert_eq!(utc("2026-10-26T14:30:00+0200").format("%Y-%m-%dT%H:%M:%SZ").to_string(), "2026-10-26T12:30:00Z");
        // Minute precision with a `Z` (UTC) suffix.
        assert_eq!(utc("2026-10-26T14:30Z").format("%Y-%m-%dT%H:%MZ").to_string(), "2026-10-26T14:30Z");
        // A seconds-and-colon-offset RFC3339 value still works.
        assert_eq!(utc("2026-10-26T14:30:00+02:00").format("%Y-%m-%dT%H:%M:%SZ").to_string(), "2026-10-26T12:30:00Z");
        assert!(parse_at("noon", at(12, 0)).is_err());
    }

    #[test]
    fn set_list_and_cancel() {
        let mut timers = Timers::default();
        let out = set(&mut timers, json!({"after": "30m", "note": "check CI"})).unwrap();
        assert!(out.changed);
        assert_eq!(out.text, "Timer 1 set for 12:30 (in 30m). When it fires you'll get its note back as a message.");
        set(&mut timers, json!({"at": "13:00", "note": "deploy done?"})).unwrap();

        let list = timers.apply("timer_list", &json!({}), at(12, 0)).unwrap();
        assert!(!list.changed);
        assert_eq!(list.text, "1. 12:30 (in 30m): check CI\n2. 13:00 (in 1h00m): deploy done?");

        let out = timers.apply("timer_cancel", &json!({"id": "1"}), at(12, 0)).unwrap();
        assert!(out.changed);
        assert_eq!(out.text, "Cancelled timer 1 (check CI).");
        assert_eq!(timers.render(at(12, 0)), "2. 13:00 (in 1h00m): deploy done?");

        // Ids keep counting across cancels.
        set(&mut timers, json!({"after": "1h", "note": "third"})).unwrap();
        assert_eq!(timers.items.last().unwrap().id, 3);
    }

    #[test]
    fn timers_listing_sanitizes_model_controlled_notes() {
        // A model-controlled note can carry ANSI/OSC escapes (e.g. from
        // prompt-injected content). The `/timers` terminal listing must drop
        // them so they never reach the terminal, while the model-facing
        // `timer_list` tool result keeps the note verbatim (issue #150).
        let mut timers = Timers::default();
        // An active timer whose note embeds ESC + a CSI clear-screen and a
        // newline that would forge an extra listing row.
        set(&mut timers, json!({"after": "30m", "note": "evil\u{1b}[2Jline\ninjected"})).unwrap();
        // Fire a second timer into `pending` so the pending branch is covered
        // too; give it an escape as well.
        set(&mut timers, json!({"at": "12:10", "note": "done?\u{1b}]0;title\u{7}"})).unwrap();
        timers.take_due(at(12, 15));

        // Terminal listing (`/timers`): no control bytes survive, and the
        // forged newline is gone, so each timer stays on exactly one row.
        let shown = timers.render_command(at(12, 20));
        assert!(!shown.contains('\u{1b}'), "escape leaked into /timers: {shown:?}");
        assert!(!shown.contains('\u{7}'), "BEL leaked into /timers: {shown:?}");
        assert_eq!(shown.lines().count(), 2, "forged newline added a row: {shown:?}");
        // The CSI/OSC sequences are stripped whole, leaving clean note text with
        // no visible `[2J` / `]0;title` bodies eating listing width.
        assert!(shown.contains("evillineinjected"), "{shown:?}");
        assert!(!shown.contains("[2J"), "CSI body left visible: {shown:?}");
        assert!(!shown.contains("]0;title"), "OSC body left visible: {shown:?}");

        // Model-facing tool result keeps the note exactly as the model set it.
        let raw = timers.render(at(12, 20));
        assert!(raw.contains("evil\u{1b}[2Jline\ninjected"), "model note was altered: {raw:?}");
        assert!(raw.contains("done?\u{1b}]0;title\u{7}"), "model note was altered: {raw:?}");
    }

    #[test]
    fn rejects_bad_calls_without_changing_the_timers() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "check CI"})).unwrap();
        let before = timers.clone();

        let err = set(&mut timers, json!({"after": "20s", "note": "x"})).unwrap_err().to_string();
        assert!(err.contains("at least a minute") && err.contains("bash"), "{err}");
        // An all-zero compound delay parses, then fails the minimum with the
        // same actionable too-soon error (not a "could not parse" one).
        let err = set(&mut timers, json!({"after": "0h0m0s", "note": "x"})).unwrap_err().to_string();
        assert!(err.contains("at least a minute") && err.contains("bash"), "{err}");
        let err = set(&mut timers, json!({"after": "25h", "note": "x"})).unwrap_err().to_string();
        assert!(err.contains("at most 24 hours") && err.contains("cron"), "{err}");
        assert!(set(&mut timers, json!({"after": "30m"})).is_err());
        assert!(set(&mut timers, json!({"note": "x"})).is_err());
        assert!(set(&mut timers, json!({"after": "30m", "at": "14:30", "note": "x"})).is_err());
        assert!(
            timers
                .apply("timer_cancel", &json!({"id": 9}), at(12, 0))
                .unwrap_err()
                .to_string()
                .contains("active timers are 1")
        );
        assert_eq!(timers, before);

        // At most 10 active timers.
        for _ in 1..10 {
            set(&mut timers, json!({"after": "1h", "note": "n"})).unwrap();
        }
        assert!(
            set(&mut timers, json!({"after": "1h", "note": "one too many"}))
                .unwrap_err()
                .to_string()
                .contains("at most 10")
        );
        assert_eq!(timers.items.len(), 10);
    }

    #[test]
    fn takes_due_timers_once_soonest_first() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "1h", "note": "later"})).unwrap();
        set(&mut timers, json!({"after": "30m", "note": "sooner"})).unwrap();
        assert!(timers.take_due(at(12, 20)).is_empty());
        let due = timers.take_due(at(12, 35));
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].note, "sooner");
        // It fired once: taking again at the same time finds nothing.
        assert!(timers.take_due(at(12, 35)).is_empty());
        let due = timers.take_due(at(13, 0));
        assert_eq!(due.len(), 1);
        assert_eq!(due[0].note, "later");
        assert!(timers.is_empty());
    }

    #[test]
    fn fired_message_marks_an_overdue_timer() {
        let timer =
            Timer { id: 2, set_at: at(9, 15).timestamp(), due_at: at(9, 45).timestamp(), note: "check CI".into() };
        let on_time = Timers::fired_message(&timer, at(9, 46));
        assert_eq!(on_time, "<system-reminder>\nTimer 2, set at 09:15, fired: check CI\n</system-reminder>");
        let late = Timers::fired_message(&timer, at(11, 50));
        assert!(
            late.contains(
                "Timer 2, set at 09:15, fired: check CI (overdue by 2:05: nano-coder wasn't running when it came due)"
            ),
            "{late}"
        );
        let batch = Timers::fired_batch_message(std::slice::from_ref(&timer), at(9, 46));
        assert!(batch.ends_with("Until you do, you'll be reminded every few steps."), "{batch}");
        assert!(batch.contains("call timer_done with its id"), "{batch}");
    }

    #[test]
    fn fired_timers_stay_pending_until_done() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "check CI"})).unwrap();
        set(&mut timers, json!({"after": "1h", "note": "deploy"})).unwrap();
        // The first fires and becomes pending (not dropped).
        let fired = timers.take_due(at(12, 31));
        assert_eq!(fired.len(), 1);
        assert!(timers.has_pending());
        assert_eq!(timers.pending.len(), 1);
        // It shows in listings, pending first.
        let list = timers.render(at(12, 40));
        assert!(list.starts_with("1. fired at 12:30, not done yet: check CI"), "{list}");
        assert!(list.contains("2. 13:00 (in 20m): deploy"), "{list}");
        // A nudge lists it.
        let nudge = timers.pending_nudge(at(12, 40)).unwrap();
        assert!(nudge.contains("Fired timers you haven't marked done:"), "{nudge}");
        assert!(nudge.contains("- 1 (fired 10m ago): check CI"), "{nudge}");
        assert!(nudge.contains("call timer_done"), "{nudge}");
        // timer_done stops the reminders.
        let out = timers.apply("timer_done", &json!({"id": 1}), at(12, 40)).unwrap();
        assert!(out.changed);
        assert_eq!(out.text, "Timer 1 marked done.");
        assert!(!timers.has_pending());
        assert!(timers.pending_nudge(at(12, 40)).is_none());
    }

    #[test]
    fn timer_done_and_cancel_handle_pending_and_errors() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "a"})).unwrap();
        set(&mut timers, json!({"after": "45m", "note": "b"})).unwrap();
        // timer_done on a not-yet-fired timer points to timer_cancel.
        let err = timers.apply("timer_done", &json!({"id": 1}), at(12, 0)).unwrap_err().to_string();
        assert!(err.contains("hasn't fired yet") && err.contains("timer_cancel"), "{err}");
        // Nothing pending yet.
        let err = timers.apply("timer_done", &json!({"id": 9}), at(12, 0)).unwrap_err().to_string();
        assert!(err.contains("none are waiting to be done"), "{err}");
        // Fire both; now they are pending.
        timers.take_due(at(13, 0));
        assert_eq!(timers.pending.len(), 2);
        let err = timers.apply("timer_done", &json!({"id": 7}), at(13, 0)).unwrap_err().to_string();
        assert!(err.contains("waiting to be done: 1, 2"), "{err}");
        // timer_cancel drops a pending timer with the fired wording.
        let out = timers.apply("timer_cancel", &json!({"id": 1}), at(13, 0)).unwrap();
        assert_eq!(out.text, "Cancelled timer 1 (a); it had already fired.");
        assert_eq!(timers.pending.len(), 1);
    }

    #[test]
    fn pending_survives_a_json_round_trip() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "one"})).unwrap();
        timers.take_due(at(12, 31));
        assert!(timers.has_pending());
        let json = serde_json::to_value(&timers).unwrap();
        let restored: Timers = serde_json::from_value(json).unwrap();
        assert_eq!(restored, timers);
        assert!(restored.has_pending());
    }

    #[test]
    fn rejects_oversized_delays_without_overflowing() {
        // A delay far past chrono's date range is a tool error, not a panic.
        assert!(parse_delay("1000000000000h").unwrap_err().to_string().contains("24 hours"));
        assert!(parse_delay("25h").unwrap_err().to_string().contains("24 hours"));
        // Compound accumulation is bounded too.
        assert!(parse_delay("13h13h").unwrap_err().to_string().contains("24 hours"));
        // The 24-hour boundary itself is still accepted.
        assert!(parse_delay("24h").is_ok());
        assert!(parse_delay("23h59m59s").is_ok());
        // Setting such a timer returns the tool error instead of panicking.
        let mut timers = Timers::default();
        let err = set(&mut timers, json!({"after": "1000000000000h", "note": "x"})).unwrap_err().to_string();
        assert!(err.contains("24 hours"), "{err}");
    }

    #[test]
    fn a_json_round_trip_keeps_ids_counting() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "one"})).unwrap();
        set(&mut timers, json!({"after": "1h", "note": "two"})).unwrap();
        timers.apply("timer_cancel", &json!({"id": 1}), at(12, 0)).unwrap();
        let json = serde_json::to_value(&timers).unwrap();
        assert_eq!(json["last_id"], 2);
        let mut restored: Timers = serde_json::from_value(json).unwrap();
        assert_eq!(restored, timers);
        set(&mut restored, json!({"after": "2h", "note": "three"})).unwrap();
        assert_eq!(restored.items.last().unwrap().id, 3);
    }

    #[test]
    fn renders_the_status_segment() {
        let mut timers = Timers::default();
        assert_eq!(timers.status_segment(), "");
        set(&mut timers, json!({"after": "30m", "note": "one"})).unwrap();
        assert_eq!(timers.status_segment(), "⏰ 12:30");
        set(&mut timers, json!({"after": "1h", "note": "two"})).unwrap();
        assert_eq!(timers.status_segment(), "⏰ 2 next 12:30");
    }

    #[test]
    fn clips_a_long_note() {
        let mut timers = Timers::default();
        set(&mut timers, json!({"after": "30m", "note": "x".repeat(1200)})).unwrap();
        assert_eq!(timers.items[0].note.chars().count(), 1000);
    }
}
