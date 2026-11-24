/// Layered compaction summaries: the summary DAG (issue #274, after pi-lcm).
///
/// A flat compaction re-summarises its previous summary together with the
/// new span, so detail from early in a long session is squeezed out by each
/// pass. With layering, each compaction's summary is a *node*: an ID (`S3`),
/// a level, and the `#N` range of the originals it covers. The in-context
/// summary is the list of live nodes, oldest first, each under a header line
/// the agent can cite. A new compaction summarises only the new span into a
/// level-0 node; the older nodes are carried forward verbatim. When their
/// text outgrows a budget the oldest few are condensed into one node a level
/// up (at most one condensation per compaction), so the stack grows
/// logarithmically with session length. `history_read` expands a node back
/// to its children or its original messages.
///
/// This module is the pure core: parsing and rendering the node list,
/// choosing what to condense and the deterministic condensation. The agent
/// does the model call and the session log records the nodes.
module nano.summary_dag;

@safe:
pure:

import std.algorithm : map, startsWith;
import std.array : join;
import std.conv : to, ConvException;
import std.format : format;
import std.json : JSONType, JSONValue;
import std.string : indexOf, lineSplitter, strip;
import nano.option : Option, some, unwrap;

/// How many of the oldest nodes one condensation merges (pi-lcm uses 6).
enum size_t condenseFanIn = 6;

/// One summary node: what one compaction (level 0) or one condensation
/// (level > 0) produced.
struct SummaryNode
{
    /// The node's number; rendered and cited as `S<id>`.
    uint id;
    /// 0 for a compaction's own summary, one more than its children's for a
    /// condensed node.
    uint level;
    /// The session-log range of the originals it covers (0 when unknown).
    ulong first, last;
    /// The nodes a condensed node merged (empty for level 0).
    uint[] children;
    /// The summary prose.
    string text;
}

/// The header line that starts a node in the in-context summary.
enum string nodeOpen = "[[node ";

/// `S<id>`, how nodes are cited.
string nodeName(uint id) { return "S" ~ id.to!string; }

/// The node ID in `s` (`S7` or `s7`), or none.
Option!uint parseNodeName(string s)
{
    s = s.strip;
    if (s.length < 2 || (s[0] != 'S' && s[0] != 's')) return Option!uint.init;
    try return some(s[1 .. $].to!uint);
    catch (ConvException) return Option!uint.init; // not a node name: the caller treats it as a message ID
}

/// The header line for `n`, e.g. `[[node S7 level=1 range=#2-#300 children=S1,S2]]`.
string header(const ref SummaryNode n)
{
    auto h = nodeOpen ~ nodeName(n.id) ~ format!" level=%s"(n.level);
    if (n.first) h ~= format!" range=#%s-#%s"(n.first, n.last);
    if (n.children.length) h ~= " children=" ~ n.children.map!(c => nodeName(c)).join(",");
    return h ~ "]]";
}

/// The node list as summary text: each header followed by its prose.
string render(const SummaryNode[] nodes)
{
    string[] parts;
    foreach (ref n; nodes) parts ~= header(n) ~ "\n" ~ n.text.strip;
    return parts.join("\n\n");
}

/// The nodes rendered in `summary` (a whole summary message: lines that are
/// not inside a node, such as the prefix and the history note, are ignored
/// when they come before the first header). A summary without headers (a
/// flat one, or one written before layering) yields no nodes.
SummaryNode[] parse(string summary)
{
    SummaryNode[] nodes;
    string[] body_;
    void flush()
    {
        if (nodes.length) nodes[$ - 1].text = body_.join("\n").strip;
        body_ = null;
    }
    foreach (line; summary.lineSplitter)
    {
        // The expand note ends the node list: what follows (the history
        // note, the plan, the pinned requests) is rebuilt every compaction.
        if (line.startsWith(expandNote[0 .. 30])) break;
        auto h = parseHeader(line);
        if (h.isSome)
        {
            flush();
            nodes ~= h.unwrap("checked isSome");
        }
        else if (nodes.length) body_ ~= line;
    }
    flush();
    return nodes;
}

private Option!SummaryNode parseHeader(string line)
{
    if (!line.startsWith(nodeOpen) || line.length < nodeOpen.length + 2 || line[$ - 2 .. $] != "]]")
        return Option!SummaryNode.init;
    SummaryNode n;
    bool named;
    try
        foreach (i, w; line[nodeOpen.length .. $ - 2].split(' '))
        {
            if (i == 0)
            {
                auto id = parseNodeName(w);
                if (id.isNone) return Option!SummaryNode.init;
                n.id = id.unwrap("checked isSome");
                named = true;
            }
            else if (w.startsWith("level=")) n.level = w["level=".length .. $].to!uint;
            else if (w.startsWith("range=#"))
            {
                auto r = w["range=#".length .. $];
                auto dash = r.indexOf("-#");
                if (dash < 0) return Option!SummaryNode.init;
                n.first = r[0 .. dash].to!ulong;
                n.last = r[dash + 2 .. $].to!ulong;
            }
            else if (w.startsWith("children="))
                foreach (c; w["children=".length .. $].split(','))
                {
                    auto id = parseNodeName(c);
                    if (id.isNone) return Option!SummaryNode.init;
                    n.children ~= id.unwrap("checked isSome");
                }
        }
    catch (ConvException) return Option!SummaryNode.init; // a malformed header is prose, not a node
    return named ? some(n) : Option!SummaryNode.init;
}

private string[] split(string s, char sep)
{
    string[] r;
    size_t start;
    foreach (i, c; s)
        if (c == sep)
        {
            if (i > start) r ~= s[start .. i];
            start = i + 1;
        }
    if (start < s.length) r ~= s[start .. $];
    return r;
}

/// The next unused node ID: one past the largest in `nodes` (a condensed
/// node's ID is larger than its children's, so the live nodes hold the max).
uint nextId(const SummaryNode[] nodes) nothrow @nogc
{
    uint m;
    foreach (ref n; nodes)
        if (n.id > m) m = n.id;
    return m + 1;
}

/// The total prose of `nodes`, in bytes.
size_t textBytes(const SummaryNode[] nodes) nothrow @nogc
{
    size_t t;
    foreach (ref n; nodes) t += n.text.length;
    return t;
}

/// How many of the oldest nodes to condense, or 0 when the node text fits
/// `budgetBytes` (or there are fewer than two nodes to merge). The newest
/// node, just written, is never condensed in the same compaction.
size_t condenseCount(const SummaryNode[] nodes, size_t budgetBytes) nothrow @nogc
{
    if (nodes.length < 3 || textBytes(nodes) <= budgetBytes) return 0;
    auto k = nodes.length - 1;
    return k < condenseFanIn ? k : condenseFanIn;
}

/// A condensed node over `children` with `text` (the caller writes it, by
/// model or by `deterministicText`).
SummaryNode condensed(const SummaryNode[] children, uint id, string text)
{
    SummaryNode n;
    n.id = id;
    n.text = text;
    foreach (ref c; children)
    {
        if (c.level + 1 > n.level) n.level = c.level + 1;
        if (c.first && (!n.first || c.first < n.first)) n.first = c.first;
        if (c.last > n.last) n.last = c.last;
        n.children ~= c.id;
    }
    return n;
}

/// A condensation built in code, with no model call: each child's opening
/// lines under its name and range, the whole capped at `maxBytes`, so the
/// agent sees where things are and expands a child for the detail.
string deterministicText(const SummaryNode[] children, size_t maxBytes)
{
    import nano.context : clipBytes;
    if (!children.length) return "";
    auto share = maxBytes / children.length;
    if (share < 80) share = 80;
    string[] parts;
    foreach (ref c; children)
    {
        auto head = c.first ? format!"%s (#%s-#%s): "(nodeName(c.id), c.first, c.last) : nodeName(c.id) ~ ": ";
        parts ~= head ~ clipBytes(c.text.strip, share);
    }
    return parts.join("\n");
}

/// The request text asking a model to condense `children` into one node.
string condenseRequest(const SummaryNode[] children)
{
    return "Summaries to condense, oldest first:\n\n" ~ render(children);
}

/// The system prompt for a condensation request.
enum string condenseSystemPrompt = "You condense several consecutive summaries of a coding session into one shorter "
    ~ "summary. Keep the decisions, outcomes, file paths, commands and open problems; drop narration. Keep every (#N) "
    ~ "citation and node name (S<n>) attached to the facts it supports, so the agent can expand them later. Do not "
    ~ "invent anything. Output only the condensed summary, under about 600 words.";

/// The note after a layered summary telling the agent how to expand nodes.
enum string expandNote = "[The summary above is layered: each [[node S<n> …]] header names a summary node and the "
    ~ "#N range it covers. history_read with node \"S<n>\" expands a node to the nodes it condensed or, for level 0, "
    ~ "to its original messages; history_search with node \"S<n>\" searches only that node's range.]";

/// The node record persisted in a `replace` record's `summary_nodes`.
JSONValue toJson(const ref SummaryNode n)
{
    JSONValue j = ["id": JSONValue(n.id), "level": JSONValue(n.level), "text": JSONValue(n.text)];
    if (n.first) j["range"] = JSONValue([JSONValue(n.first), JSONValue(n.last)]);
    if (n.children.length)
    {
        JSONValue[] cs;
        foreach (c; n.children) cs ~= JSONValue(c);
        j["children"] = cs;
    }
    return j;
}

/// A node from its log record, or none when it is malformed.
Option!SummaryNode fromJson(const JSONValue j)
{
    static Option!ulong num(const JSONValue v)
    {
        if (v.type == JSONType.integer && v.integer >= 0) return some(v.integer.to!ulong);
        if (v.type == JSONType.uinteger) return some(v.uinteger);
        return Option!ulong.init;
    }
    if (j.type != JSONType.object) return Option!SummaryNode.init;
    auto o = j.objectNoRef;
    SummaryNode n;
    auto id = "id" in o;
    if (id is null) return Option!SummaryNode.init;
    auto idv = num(*id);
    if (idv.isNone || idv.unwrap("checked") > uint.max) return Option!SummaryNode.init;
    n.id = idv.unwrap("checked").to!uint;
    if (auto l = "level" in o)
        foreach (v; num(*l)) n.level = v > uint.max ? uint.max : v.to!uint;
    if (auto t = "text" in o)
        if (t.type == JSONType.string) n.text = t.str;
    if (auto r = "range" in o)
        if (r.type == JSONType.array && r.arrayNoRef.length == 2)
        {
            foreach (v; num(r.arrayNoRef[0])) n.first = v;
            foreach (v; num(r.arrayNoRef[1])) n.last = v;
        }
    if (auto cs = "children" in o)
        if (cs.type == JSONType.array)
            foreach (c; cs.arrayNoRef)
                foreach (v; num(c))
                    if (v <= uint.max) n.children ~= v.to!uint;
    return some(n);
}

unittest // render and parse round-trip, ignoring prose outside nodes
{
    auto a = SummaryNode(1, 0, 2, 40, null, "fixed the auth bug (#12)\nsecond line");
    auto b = SummaryNode(3, 1, 41, 400, [2, 4], "condensed");
    auto text = "[prefix]\n" ~ render([a, b]);
    auto got = parse(text);
    assert(got.length == 2);
    assert(got[0] == a);
    assert(got[1] == b);
    assert(header(b) == "[[node S3 level=1 range=#41-#400 children=S2,S4]]");
    assert(parse("a flat summary\n[[node nonsense]]").length == 0);
    auto tail = parse(render([a]) ~ "\n\n" ~ expandNote ~ "\n\n[pinned requests]\nfoo");
    assert(tail.length == 1 && tail[0] == a, "the notes after the nodes are not node prose");
    assert(parse("[[node S2 level=x]]").length == 0);
}

unittest // node names
{
    assert(parseNodeName("S7").unwrap("valid") == 7);
    assert(parseNodeName("s12").unwrap("valid") == 12);
    assert(parseNodeName("12").isNone);
    assert(parseNodeName("Sx").isNone);
    assert(nodeName(4) == "S4");
}

unittest // condensation picks the oldest nodes, never the newest
{
    SummaryNode[] ns;
    foreach (uint i; 1 .. 4) ns ~= SummaryNode(i, 0, i * 10, i * 10 + 9, null, "x".replicate(100));
    assert(condenseCount(ns, 1_000) == 0, "fits the budget");
    assert(condenseCount(ns, 100) == 2, "all but the newest");
    foreach (uint i; 4 .. 12) ns ~= SummaryNode(i, 0, i * 10, i * 10 + 9, null, "x".replicate(100));
    assert(condenseCount(ns, 100) == condenseFanIn);
    auto c = condensed(ns[0 .. 6], nextId(ns), deterministicText(ns[0 .. 6], 600));
    assert(c.id == 12 && c.level == 1 && c.first == 10 && c.last == 69);
    assert(c.children == [1, 2, 3, 4, 5, 6]);
    assert(c.text.length <= 6 * 120);
    assert(c.text.indexOf("S1 (#10-#19): ") == 0);
    auto up = condensed([c, ns[7]], 13, "y");
    assert(up.level == 2 && up.first == 10 && up.last == 89);
}

unittest // JSON round trip, and a malformed record is rejected
{
    import std.json : parseJSON;
    auto n = SummaryNode(5, 1, 3, 9, [1, 2], "t");
    assert(fromJson(toJson(n)).unwrap("round trip") == n);
    auto leaf = SummaryNode(1, 0, 0, 0, null, "t");
    assert(fromJson(toJson(leaf)).unwrap("round trip") == leaf);
    assert(fromJson(parseJSON(`{"level":1}`)).isNone);
    assert(fromJson(parseJSON(`[1]`)).isNone);
}

version (unittest) private string replicate(string s, size_t n)
{
    string r;
    foreach (_; 0 .. n) r ~= s;
    return r;
}
