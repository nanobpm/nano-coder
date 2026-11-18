/// Status-row rendering (status.rs tests).
module nano.status_test;
@safe:

version (unittest):

import std.algorithm : all, canFind;
import std.regex : regex, replaceAll;
import nano.status;

private:

string visible(string s) { return s.replaceAll(regex(`\x1b\[[0-9;]*m`), ""); }

Stats stats()
{
    Stats s = {provider: "work", model: "llama-b", tokens: 96_500, calibrated: true, window: 128_000, messages: 42,
        sessionInputTokens: 310_000, sessionOutputTokens: 12_400, compactions: 1, autoCompact: true, threshold: 0.8,
        activity: Activity.tool, tool: "bash", hasPlan: true, planDone: 2, planTotal: 5, cwd: "/tmp/project"};
    return s;
}

// rust: status.rs::drops_output_rate_first_on_narrow_widths
unittest
{
    import std.utf : count;
    auto s = stats();
    s.activity = Activity.thinking;
    s.tokensPerSec = 2.0;
    auto line = visible(render(s, 50));
    assert(line.count == 50, line);
    assert(line.canFind("work/llama-b") && !line.canFind("tok/s"), line);
}

// rust: status.rs::home_is_shown_as_tilde
unittest
{
    import std.file : exists, mkdirRecurse, rmdirRecurse, symlink, tempDir;
    import std.path : buildPath;
    import nano.safeio : realPath;
    assert(tildePath("/Users/joshua", "/Users/joshua") == "~");
    assert(tildePath("/Users/joshua/workspace/nano", "/Users/joshua") == "~/workspace/nano");
    assert(tildePath("/Users/joshua2/x", "/Users/joshua") == "/Users/joshua2/x");
    assert(tildePath("/tmp/project", "/Users/joshua") == "/tmp/project");
    assert(tildePath("/tmp", null) == "/tmp");
    assert(tildePath("/tmp", "/") == "/tmp");
    auto dir = buildPath(tempDir, "nano-status-tilde");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto target = buildPath(realPath(dir), "real-home");
    mkdirRecurse(buildPath(target, "proj"));
    auto link = buildPath(dir, "link-home");
    symlink(target, link);
    assert(tildePath(buildPath(target, "proj"), link) == "~/proj", "a symlinked home matches its target");
    auto rootLink = buildPath(dir, "root-home");
    symlink("/", rootLink);
    assert(tildePath("/tmp", rootLink) == "/tmp" && tildePath("/any/where", rootLink) == "/any/where");
}

// rust: status.rs::marks_uncalibrated_estimates
unittest
{
    auto s = stats();
    s.calibrated = false;
    assert(visible(render(s, 140)).canFind("ctx ~96.5k"));
}

// rust: status.rs::names_smart_compaction
unittest
{
    auto s = stats();
    s.smartCompact = true;
    auto line = visible(render(s, 140));
    assert(line.canFind("smart-compact 80% (1×)") && !line.canFind("auto-compact"), line);
    s.autoCompact = false;
    assert(visible(render(s, 140)).canFind("smart-compact off"));
}

// rust: status.rs::shows_history_usage_only_when_used
unittest
{
    auto s = stats();
    assert(!visible(render(s, 140)).canFind("hist "));
    s.historySearches = 3;
    s.historyReads = 1;
    assert(visible(render(s, 200)).canFind("hist 3s 1r"));
}

// rust: status.rs::shows_the_thinking_level_only_when_one_is_sent
unittest
{
    auto s = stats();
    assert(!visible(render(s, 160)).canFind("think "));
    s.thinking = "high";
    assert(visible(render(s, 160)).canFind("think high"));
    auto narrow = visible(render(s, 50));
    assert(!narrow.canFind("think high") && narrow.canFind("work/llama-b"), narrow);
}

// rust: status.rs::shows_timers_only_when_set
unittest
{
    auto s = stats();
    assert(!visible(render(s, 200)).canFind("⏰"));
    s.timers = 1;
    s.nextTimer = "12:30";
    assert(visible(render(s, 200)).canFind("⏰ 12:30"));
    s.timers = 2;
    assert(visible(render(s, 200)).canFind("⏰ 2 next 12:30"));
}

// rust: status.rs::status_row_never_exceeds_cols_with_wide_glyphs
unittest
{
    auto s = stats();
    s.cwd = "/项目/工作目录/深层/路径";
    foreach (cols; 10 .. 141)
    {
        auto line = visible(render(s, cols));
        assert(cellWidth(line) <= cols, line);
    }
}

// rust: status.rs::strips_control_chars_from_segments
unittest
{
    import std.uni : isControl;
    auto s = stats();
    s.cwd = "/tmp/a\nb\r\x1b[2Jc\td";
    auto line = render(s, 140);
    assert(!line.canFind('\n') && !line.canFind('\r') && !line.canFind('\t'), line);
    auto shown = visible(line);
    assert(shown.all!(c => !isControl(c)), shown);
    assert(shown.canFind("abcd") || shown.canFind("/tmp/a"), shown);
}
