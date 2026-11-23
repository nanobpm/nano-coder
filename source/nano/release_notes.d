/// What changed since the version that ran last (#282). The release
/// pipeline writes `source/release-notes.json` (scripts/release-notes.mjs):
/// every recent release's user-facing changes, compiled in. On an
/// interactive start after an update, nano-coder shows "Updated X → Y" with
/// the changes in between; `/changes [version]` shows them again.
///
/// The last version that ran is recorded in `<data dir>/nano-coder/
/// last_version`. The first run ever records it and shows nothing; a
/// downgrade records the running version and shows nothing. When the
/// embedded notes don't cover the range (an old record, a local build), the
/// releases are fetched from the GitHub API in the background, falling back
/// to a compare link when that fails.
module nano.release_notes;

@safe:
import nano.option : Option, some, none;
import std.json;
import std.format : format;

/// The compiled-in notes (the release commit's `source/release-notes.json`).
enum string embeddedJson = import("release-notes.json");
enum repoUrl = "https://github.com/nanobpm/nano-coder";
enum releasesApiUrl = "https://api.github.com/repos/nanobpm/nano-coder/releases?per_page=100";
/// The most bullets a notice shows; the rest are a compare link.
enum size_t bulletCap = 15;
/// The most bytes read from the releases API.
enum size_t fetchByteCap = 4 << 20;
/// The most release pages a fallback fetch reads.
enum size_t fetchPageCap = 5;

/// One user-facing change: a `feat`, `fix` or `perf` commit (or a breaking change).
struct Item
{
    string type, scope_, title;
    long pr; /// 0 = none
    bool breaking;
}

/// One release's changes.
struct Release
{
    string version_, date;
    Item[] items;
}

/// `-1`, `0` or `1` as `a` is older than, the same as, or newer than `b`.
int compareVersions(string a, string b) pure
{
    import nano.update : isNewer;
    return isNewer(a, b) ? 1 : isNewer(b, a) ? -1 : 0;
}

unittest
{
    assert(compareVersions("1.10.0", "1.9.2") == 1);
    assert(compareVersions("v1.2.3", "1.2.3") == 0);
    assert(compareVersions("1.0.0-rc.1", "1.0.0") == -1);
    assert(compareVersions("0.9.0", "0.10.0") == -1);
    assert(compareVersions("1.0.0-rc.2", "1.0.0-rc.10") == -1);
    assert(compareVersions("1.0.0-rc.2", "1.0.0-rc.1") == 1);
}

private string str(const JSONValue j, string key) pure
{
    if (j.type != JSONType.object) return null;
    if (auto v = key in j.objectNoRef) if (v.type == JSONType.string) return v.str;
    return null;
}

/// The releases in a notes file (`{"releases": [...]}`); empty when it isn't one.
Release[] parseNotes(string json)
{
    import std.exception : collectException;
    JSONValue j;
    if (collectException(j = parseJSON(json)) !is null || j.type != JSONType.object) return null;
    auto rs = "releases" in j.objectNoRef;
    if (rs is null || rs.type != JSONType.array) return null;
    Release[] out_;
    foreach (r; rs.arrayNoRef)
    {
        auto v = str(r, "version");
        if (!v.length) continue;
        Release rel = {version_: v, date: str(r, "date")};
        if (auto items = "items" in r.objectNoRef)
            if (items.type == JSONType.array)
                foreach (it; items.arrayNoRef)
                {
                    if (it.type != JSONType.object) continue;
                    Item item = {type: str(it, "type"), scope_: str(it, "scope"), title: str(it, "title")};
                    if (auto p = "pr" in it.objectNoRef) if (p.type == JSONType.integer) item.pr = p.integer;
                    if (auto b = "breaking" in it.objectNoRef) item.breaking = b.type == JSONType.true_;
                    if (item.title.length) rel.items ~= item;
                }
        out_ ~= rel;
    }
    return out_;
}

/// The compiled-in releases.
Release[] embedded() { return parseNotes(embeddedJson); }

unittest
{
    auto rs = embedded();
    assert(rs.length > 0, "the embedded notes parse");
    auto rs2 = parseNotes(`{"releases": [{"version": "1.2.0", "date": "2026-01-01", "items": [
        {"type": "feat", "scope": "ui", "title": "a", "pr": 7}, {"type": "fix", "scope": "", "title": "b", "pr": null,
        "breaking": true}]}]}`);
    assert(rs2.length == 1 && rs2[0].items.length == 2);
    assert(rs2[0].items[0] == Item("feat", "ui", "a", 7, false));
    assert(rs2[0].items[1] == Item("fix", "", "b", 0, true));
    assert(parseNotes("not json") is null);
    assert(parseNotes(`[1]`) is null);
}

/// The releases from the GitHub API's release list: each body is
/// semantic-release's markdown (`### Features`, `* **scope:** title ([#N](…))`).
Release[] parseGithubReleases(string json)
{
    import std.algorithm : startsWith, findSplit, findSplitBefore;
    import std.string : lineSplitter, strip;
    import std.conv : to;
    import std.exception : collectException;
    JSONValue j;
    if (collectException(j = parseJSON(json)) !is null || j.type != JSONType.array) return null;
    Release[] out_;
    foreach (r; j.arrayNoRef)
    {
        auto tag = str(r, "tag_name");
        if (!tag.startsWith("v") || str(r, "draft").length) continue;
        auto date = str(r, "published_at");
        Release rel = {version_: tag[1 .. $], date: date.length >= 10 ? date[0 .. 10] : date};
        string type;
        bool breaking;
        foreach (line; str(r, "body").lineSplitter)
        {
            auto l = line.strip;
            if (l.startsWith("#"))
            {
                breaking = false;
                type = null;
                if (l.findSplit("Features")[1].length) type = "feat";
                else if (l.findSplit("Bug Fixes")[1].length) type = "fix";
                else if (l.findSplit("Performance")[1].length) type = "perf";
                else if (l.findSplit("BREAKING")[1].length) { type = "feat"; breaking = true; }
                continue;
            }
            if (!type.length || !(l.startsWith("* ") || l.startsWith("- "))) continue;
            Item item = {type: type, breaking: breaking};
            auto text = l[2 .. $].strip;
            if (text.startsWith("**"))
                if (auto s = text[2 .. $].findSplit(":**"))
                {
                    item.scope_ = s[0];
                    text = s[2].strip;
                }
            if (auto p = text.findSplit("([#"))
            {
                auto n = p[2].findSplitBefore("]")[0];
                collectException(item.pr = n.to!long);
            }
            item.title = text.findSplitBefore(" ([")[0].strip;
            if (item.title.length) rel.items ~= item;
        }
        out_ ~= rel;
    }
    return out_;
}

unittest
{
    auto rs = parseGithubReleases(`[{"tag_name": "v1.11.0", "published_at": "2026-11-23T01:02:03Z", "body":
        "## [1.11.0](https://x/compare/v1.10.1...v1.11.0) (2026-11-23)\n\n### Features\n\n* **ui:** probe things ([#260](https://x/260)) ([34bb587](https://x/c))\n* plain one\n\n### Bug Fixes\n\n* fixed ([#5](u)) ([abc](u))\n\n### Performance Improvements\n\n* fast ([#6](u))\n\n### ⚠ BREAKING CHANGES\n\n* config moved\n"},
        {"tag_name": "rust-final", "body": ""}]`);
    assert(rs.length == 1);
    assert(rs[0].version_ == "1.11.0" && rs[0].date == "2026-11-23");
    assert(rs[0].items == [Item("feat", "ui", "probe things", 260), Item("feat", "", "plain one", 0),
        Item("fix", "", "fixed", 5), Item("perf", "", "fast", 6), Item("feat", "", "config moved", 0, true)]);
    assert(parseGithubReleases("{}") is null);
    assert(parseGithubReleases("<html>") is null);
}

/// The releases after `from` up to and including `to`, newest first, and
/// whether `notes` cover that whole range: they must hold `to` and reach back
/// to `from` (a version at or below it), else releases may be missing.
struct Range
{
    Release[] releases;
    bool complete;
}

/// ditto
Range selectRange(const Release[] notes, string from, string to) pure
{
    import std.algorithm : sort;
    Range r;
    bool hasTo, reachesFrom;
    foreach (rel; notes)
    {
        if (compareVersions(rel.version_, to) == 0) hasTo = true;
        if (compareVersions(rel.version_, from) <= 0) reachesFrom = true;
        if (compareVersions(rel.version_, from) > 0 && compareVersions(rel.version_, to) <= 0)
        {
            bool dup;
            foreach (x; r.releases) dup = dup || compareVersions(x.version_, rel.version_) == 0;
            if (!dup) r.releases ~= Release(rel.version_, rel.date, rel.items.dup);
        }
    }
    r.releases.sort!((a, b) => compareVersions(a.version_, b.version_) > 0);
    r.complete = hasTo && reachesFrom;
    return r;
}

unittest
{
    auto notes = [Release("1.3.0", "", [Item("feat", "", "c")]), Release("1.2.0", "", [Item("fix", "", "b")]),
        Release("1.1.0", "", [Item("feat", "", "a")])];
    auto r = selectRange(notes, "1.1.0", "1.3.0");
    assert(r.complete);
    assert(r.releases.length == 2 && r.releases[0].version_ == "1.3.0" && r.releases[1].version_ == "1.2.0");
    assert(!selectRange(notes, "1.0.0", "1.3.0").complete, "the record is older than the oldest embedded version");
    assert(!selectRange(notes, "1.1.0", "1.4.0").complete, "the running version is missing (a local build)");
    assert(selectRange(notes, "1.2.0", "1.2.0").releases.length == 0);
    assert(selectRange(notes ~ notes, "1.1.0", "1.3.0").releases.length == 2, "no duplicates after a merge");
}

/// `https://github.com/nanobpm/nano-coder/compare/vX...vY`.
string compareUrl(string from, string to) pure { return format("%s/compare/v%s...v%s", repoUrl, from, to); }

/// The notice for an update from `from` to `to`: a heading, then the changes
/// grouped as Features, Fixes and Performance (newest release first), at most
/// `cap` bullets and then "…and N more" with the compare link.
string[] renderNotes(const Release[] releases, string from, string to, size_t cap = bulletCap) pure
{
    string[] lines = [format("Updated %s → %s", from, to)];
    static immutable groups = [["feat", "Features"], ["fix", "Fixes"], ["perf", "Performance"]];
    size_t total, shown;
    foreach (rel; releases) total += rel.items.length;
    if (!total)
    {
        lines ~= "No user-facing changes: " ~ compareUrl(from, to);
        return lines;
    }
    foreach (g; groups)
    {
        bool headed;
        foreach (rel; releases)
            foreach (it; rel.items)
            {
                if (it.type != g[0] || shown >= cap) continue;
                if (!headed) { lines ~= g[1] ~ ":"; headed = true; }
                // Titles come from commit subjects and GitHub release bodies: no escapes or frame markers.
                import nano.trajectory : terminalSafe;
                string text = terminalSafe((it.breaking ? "BREAKING: " : "") ~ (it.scope_.length ? it.scope_ ~ ": " : "") ~ it.title);
                if (it.pr) text ~= format(" (%s/pull/%s)", repoUrl, it.pr);
                lines ~= "  • " ~ text;
                shown++;
            }
    }
    // Items of an unknown type are counted, not shown.
    if (shown < total) lines ~= format("…and %s more: %s", total - shown, compareUrl(from, to));
    return lines;
}

unittest
{
    import std.algorithm : canFind;
    auto rels = [Release("1.3.0", "", [Item("fix", "ui", "two", 2), Item("perf", "", "three", 0)]),
        Release("1.2.0", "", [Item("feat", "", "one", 1, true)])];
    auto l = renderNotes(rels, "1.1.0", "1.3.0");
    assert(l == ["Updated 1.1.0 → 1.3.0", "Features:", "  • BREAKING: one (https://github.com/nanobpm/nano-coder/pull/1)",
        "Fixes:", "  • ui: two (https://github.com/nanobpm/nano-coder/pull/2)", "Performance:", "  • three"], format("%s", l));
    // The cap: 20 items show 15 and a link for the rest.
    Item[] many;
    foreach (i; 0 .. 20) many ~= Item("fix", "", format("f%s", i), i + 1);
    auto c = renderNotes([Release("2.0.0", "", many)], "1.0.0", "2.0.0");
    size_t bullets;
    foreach (x; c) if (x.canFind("•")) bullets++;
    assert(bullets == 15);
    assert(c[$ - 1] == "…and 5 more: https://github.com/nanobpm/nano-coder/compare/v1.0.0...v2.0.0", c[$ - 1]);
    assert(renderNotes([Release("1.0.1", "", null)], "1.0.0", "1.0.1")[1].canFind("No user-facing changes"));
    // Escapes in a title or scope are stripped.
    auto e = renderNotes([Release("1.0.1", "", [Item("fix", "\x1b[31mui", "a\x1b]52;c;Zm8=\x07b")])], "1.0.0", "1.0.1");
    assert(e[2] == "  • ui: ab", e[2]);
}

/// The notice when the changes are unknown: a heading and the compare link.
string[] renderFallback(string from, string to) pure
{
    return [format("Updated %s → %s", from, to), "See what changed: " ~ compareUrl(from, to)];
}

/// Fetches a URL's body (null on failure); tests pass a fake.
alias Fetcher = string delegate(string url) @safe;

/// The notice for `from` → `to`: from `notes` when they cover the range,
/// else from `fetch`ed releases (when given), else the compare link.
string[] notesFor(const Release[] notes, string from, string to, scope Fetcher fetch = null)
{
    auto r = selectRange(notes, from, to);
    if (!r.complete && fetch !is null)
    {
        // Page back until the range is covered, within `fetchPageCap` pages
        // and `fetchByteCap` bytes in all.
        Release[] got;
        size_t bytes;
        foreach (page; 1 .. fetchPageCap + 1)
        {
            auto body_ = fetch(format("%s&page=%s", releasesApiUrl, page));
            bytes += body_.length;
            if (!body_.length || bytes > fetchByteCap) break;
            auto rels = parseGithubReleases(body_);
            if (!rels.length) break;
            got ~= rels;
            r = selectRange(got ~ notes, from, to);
            if (r.complete) break;
        }
    }
    return r.complete ? renderNotes(r.releases, from, to) : renderFallback(from, to);
}

unittest
{
    import std.algorithm : canFind;
    auto notes = [Release("1.2.0", "", [Item("feat", "", "two", 2)]), Release("1.1.0", "", null)];
    assert(notesFor(notes, "1.1.0", "1.2.0")[1] == "Features:");
    int calls;
    // Missing notes and a failing fetch: the compare link.
    auto failing = delegate(string url) @safe { calls++; return string.init; };
    assert(notesFor(notes, "1.0.0", "1.2.0", failing) == renderFallback("1.0.0", "1.2.0"));
    assert(calls == 1);
    // No fetcher at all (ACP): the compare link too.
    assert(notesFor(notes, "1.2.0", "1.3.0") == renderFallback("1.2.0", "1.3.0"));
    // A fetch that fills the gap.
    auto good = delegate(string url) @safe {
        assert(url == releasesApiUrl ~ "&page=1");
        return `[{"tag_name": "v1.3.0", "body": "### Bug Fixes\n\n* fixed it ([#9](u))\n"}]`;
    };
    auto l = notesFor(notes, "1.1.0", "1.3.0", good);
    assert(l.canFind("  • fixed it (https://github.com/nanobpm/nano-coder/pull/9)") && l.canFind("  • two (https://github.com/nanobpm/nano-coder/pull/2)"), format("%s", l));
    // A baseline older than the first page: later pages are fetched, up to the cap.
    string[] urls;
    auto paged = delegate(string url) @safe {
        urls ~= url;
        if (url.canFind("&page=1")) return `[{"tag_name": "v1.3.0", "body": "### Bug Fixes\n\n* new ([#9](u))\n"}]`;
        if (url.canFind("&page=2")) return `[{"tag_name": "v1.0.0", "body": "### Features\n\n* old ([#1](u))\n"}]`;
        return string.init;
    };
    l = notesFor(notes, "1.0.0", "1.3.0", paged);
    assert(urls.length == 2 && l.canFind("  • new (https://github.com/nanobpm/nano-coder/pull/9)"), format("%s %s", urls, l));
    urls = null;
    auto endless = delegate(string url) @safe { urls ~= url; return `[{"tag_name": "v1.3.0", "body": ""}]`; };
    assert(notesFor(notes, "0.1.0", "1.3.0", endless) == renderFallback("0.1.0", "1.3.0"));
    assert(urls.length == fetchPageCap, "bounded");
}

/// What a start does about the notes: show them (from `from`) and/or record
/// the running version.
struct Startup
{
    bool show, record;
    string from;
}

/// The first run ever records and shows nothing; an upgrade shows the notes
/// (unless `enabled` is off) and records; a downgrade only records; the same
/// version does nothing.
Startup decide(Option!string recorded, string running, bool enabled) pure
{
    import nano.option : match;
    return recorded.match!((string last) {
        auto c = compareVersions(running, last);
        if (c == 0) return Startup.init;
        return Startup(c > 0 && enabled, true, last);
    }, () => Startup(false, true, null));
}

unittest
{
    assert(decide(Option!string(none), "1.2.0", true) == Startup(false, true, null), "first run");
    assert(decide(some("1.1.0"), "1.2.0", true) == Startup(true, true, "1.1.0"), "upgrade");
    assert(decide(some("1.1.0"), "1.2.0", false) == Startup(false, true, "1.1.0"), "setting off");
    assert(decide(some("1.3.0"), "1.2.0", true) == Startup(false, true, "1.3.0"), "downgrade");
    assert(decide(some("1.2.0"), "1.2.0", true) == Startup.init, "same version");
}

/// `<data dir>/nano-coder/last_version`, next to the update check's state.
string lastVersionPath()
{
    import std.path : buildPath, dirName;
    import nano.update : defaultStatePath;
    return buildPath(defaultStatePath().dirName, "last_version");
}

/// The recorded version, if any.
Option!string readLastVersion(string path)
{
    import std.file : readText;
    import std.string : strip;
    import std.exception : collectException;
    string text;
    if (collectException(text = readText(path)) !is null || !text.strip.length) return Option!string(none);
    return some(text.strip);
}

/// Records `version_` (atomically; best-effort: a failure means the notes may show again).
void writeLastVersion(string path, string version_)
{
    import std.file : mkdirRecurse, rename, remove, write;
    import std.path : dirName;
    import std.process : thisProcessID;
    import std.exception : collectException;
    auto tmp = format("%s.%s.tmp", path, thisProcessID);
    if (collectException({ mkdirRecurse(path.dirName); write(tmp, version_ ~ "\n"); rename(tmp, path); }()) !is null)
        collectException(remove(tmp));
}

unittest
{
    import std.file : tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-release-notes-%s", thisProcessID));
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto path = buildPath(dir, "nano-coder", "last_version");
    assert(readLastVersion(path).isNone);
    writeLastVersion(path, "1.2.3");
    assert(readLastVersion(path) == some("1.2.3"));
}

/// The start-up notice for an interactive session, or null: reads and
/// updates the record at `path`. Notes the embedded ones lack come from
/// `fetch` when given (call it off the UI thread); without one, a compare link.
string[] startupNotice(string path, string running, bool enabled, const Release[] notes, scope Fetcher fetch = null)
{
    auto d = decide(readLastVersion(path), running, enabled);
    if (d.record) writeLastVersion(path, running);
    return d.show ? notesFor(notes, d.from, running, fetch) : null;
}

/// The start-up notice without updating the record at `path`: the caller
/// records the running version (`writeLastVersion`) once it has shown it, so
/// quitting before a background fetch lands keeps the notice for next start.
string[] pendingNotice(string path, string running, const Release[] notes, scope Fetcher fetch = null)
{
    auto d = decide(readLastVersion(path), running, true);
    return d.show ? notesFor(notes, d.from, running, fetch) : null;
}

/// Whether the start-up notice needs the network: an upgrade the embedded notes don't cover.
bool needsFetch(string path, string running, bool enabled, const Release[] notes)
{
    auto d = decide(readLastVersion(path), running, enabled);
    return d.show && !selectRange(notes, d.from, running).complete;
}

unittest
{
    import std.file : tempDir, rmdirRecurse, exists;
    import std.path : buildPath;
    import std.process : thisProcessID;
    auto dir = buildPath(tempDir, format("nano-release-startup-%s", thisProcessID));
    scope (exit) if (dir.exists) rmdirRecurse(dir);
    auto path = buildPath(dir, "last_version");
    auto notes = [Release("1.2.0", "", [Item("feat", "", "two", 2)]), Release("1.1.0", "", null)];
    assert(startupNotice(path, "1.1.0", true, notes) is null, "first run shows nothing");
    assert(readLastVersion(path) == some("1.1.0"), "…and records");
    assert(!needsFetch(path, "1.2.0", true, notes));
    assert(startupNotice(path, "1.2.0", true, notes)[0] == "Updated 1.1.0 → 1.2.0");
    assert(startupNotice(path, "1.2.0", true, notes) is null, "shown once");
    assert(startupNotice(path, "1.1.0", true, notes) is null, "downgrade shows nothing");
    assert(readLastVersion(path) == some("1.1.0"), "…and records the running version");
    writeLastVersion(path, "0.9.0");
    assert(needsFetch(path, "1.2.0", true, notes));
    assert(!needsFetch(path, "1.2.0", false, notes), "setting off");
    // The background path leaves the record until the notice is shown.
    assert(pendingNotice(path, "1.2.0", notes, delegate string(string url) => null).length);
    assert(readLastVersion(path) == some("0.9.0"), "not recorded before it is shown");
}

/// The default fetcher: the GitHub API with short timeouts, at most
/// `fetchByteCap` bytes; null on any failure.
string fetchUrl(string url)
{
    import core.time : seconds;
    import nano.http : Request, perform;
    import std.exception : collectException;
    Request req;
    req.method = "GET";
    req.url = url;
    req.headers = ["Accept": "application/vnd.github+json", "User-Agent": "nano-coder (" ~ repoUrl ~ ")"];
    req.connectTimeout = 5.seconds;
    req.idleTimeout = 5.seconds;
    req.maxBytes = fetchByteCap; // the transfer aborts past the cap
    string body_;
    int status;
    if (collectException(status = perform(req, body_)) !is null) return null;
    return status == 200 ? body_ : null;
}

/// The background notice thread: computes the start-up notice (fetching what
/// the embedded notes lack) and sends it, as one text, to `out_`. The record
/// is left for the receiver to update once the notice is on screen.
void runNotice(string path, string running, Chan!string out_)
{
    import std.array : join;
    auto lines = pendingNotice(path, running, embedded(), (string url) => fetchUrl(url));
    if (lines.length) out_.put(lines.join("\n"));
    else writeLastVersion(path, running); // nothing to show, nothing to lose
}

import nano.safeio : Chan;

/// `/changes [version]`: the changes since `arg` (default: the release
/// before `running`) up to `running`, as lines. Notes the embedded ones lack
/// come from `fetch` when given, else a compare link.
string[] changesCommand(string arg, string running, const Release[] notes, scope Fetcher fetch = null)
{
    import std.string : strip;
    import std.regex : matchFirst, ctRegex;
    auto from = arg.strip;
    while (from.length && (from[0] == 'v' || from[0] == 'V')) from = from[1 .. $];
    if (!from.length)
    {
        foreach (rel; notes)
            if (compareVersions(rel.version_, running) < 0
                && (!from.length || compareVersions(rel.version_, from) > 0))
                from = rel.version_;
        if (!from.length) return ["No release notes before " ~ running ~ ": " ~ repoUrl ~ "/releases"];
    }
    else if (!matchFirst(from, ctRegex!`^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$`))
        return ["usage: /changes [version], e.g. /changes 1.2.0"];
    if (compareVersions(from, running) >= 0)
        return [format("%s is not older than this version (%s)", from, running)];
    auto lines = notesFor(notes, from, running, fetch);
    lines[0] = format("Changes since %s (now %s)", from, running);
    return lines;
}

unittest
{
    import std.algorithm : canFind;
    auto notes = [Release("1.3.0", "", [Item("fix", "", "three", 3)]), Release("1.2.0", "", [Item("feat", "", "two", 2)]),
        Release("1.1.0", "", null)];
    auto l = changesCommand("", "1.3.0", notes);
    assert(l[0] == "Changes since 1.2.0 (now 1.3.0)" && l.canFind("  • three (https://github.com/nanobpm/nano-coder/pull/3)")
        && !l.canFind!(x => x.canFind("two")), format("%s", l));
    l = changesCommand("v1.1.0", "1.3.0", notes);
    assert(l[0] == "Changes since 1.1.0 (now 1.3.0)" && l.canFind!(x => x.canFind("two")));
    assert(changesCommand("1.3.0", "1.3.0", notes)[0].canFind("not older"));
    assert(changesCommand("bogus", "1.3.0", notes)[0].canFind("usage"));
    assert(changesCommand("", "1.1.0", notes)[0].canFind("No release notes"));
    assert(changesCommand("0.5.0", "1.3.0", notes)[1].canFind("/compare/v0.5.0...v1.3.0"), "missing notes: the compare link");
}
