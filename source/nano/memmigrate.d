/// `/memory migrate` (issue #281): tag existing memories with entities and a
/// fact kind, merge duplicates and supersede stale facts — proposed by the
/// model in byte-bounded batches, applied only after the user confirms.
///
/// The flow per scope file: untagged entries not yet reviewed are split into
/// batches of at most `Options.batchBytes`; each batch, with a bounded digest
/// of the already-tagged entries, goes to the model, whose JSON proposals are
/// validated against the store and shown for review. Accepted proposals are
/// applied under the scope's lock; the batch's ids are then recorded in
/// `migrate-progress.json` so an interrupted run resumes where it stopped and
/// a re-run touches only entries that are still untagged and unreviewed.
/// Before the first change of a run the memory files are copied aside.
module nano.memmigrate;

@safe:

import nano.memory;
import nano.memsecret : looksLikeSecret, evidenceStatesLabelValue;
import nano.safeio : jsonText, readBytes, utf8Text;
import nano.clock : wallNow;
import std.algorithm : all, any, canFind, filter, map, max, sort;
import std.array : array, join;
import std.format : format;
import std.json;
import std.path : baseName, buildPath, dirName;
import std.string : strip, indexOf, lastIndexOf, split;
import std.sumtype : SumType, match;
import std.utf : byDchar;
import std.range : walkLength;

/// Default byte budget of one batch's rendered entries.
enum defaultBatchBytes = 12_000;
/// Byte budget of the already-tagged digest sent with each batch.
enum contextBytes = 6_000;
/// The progress file, beside `user.jsonl`.
enum progressFile = "migrate-progress.json";

/// Tag one entry with entities and a fact kind.
struct TagProposal { string id; string[] entities; string factKind; }
/// Merge `drop` into `keep` (optionally with better `text`).
struct MergeProposal { string keep; string[] drop; string text; string why; }
/// Mark `old` replaced by the newer entry `newer`.
struct SupersedeProposal { string old; string newer; string why; }
/// One proposed change.
alias Proposal = SumType!(TagProposal, MergeProposal, SupersedeProposal);

/// Asks the model: `(system, user)` to its reply text.
alias Ask = string delegate(string system, string user) @safe;

/// The review prompts, so the line editor and plain stdin share the flow.
struct Ui
{
    /// Pick one of `labels`; negative means cancelled.
    ptrdiff_t delegate(string prompt, const string[] labels) @safe select;
    /// Read a value, pre-filled with `initial`; null means cancelled.
    string delegate(string prompt, string initial) @safe input;
    /// Show a line.
    void delegate(string line) @safe say;
}

/// How to run a migration.
struct Options
{
    /// Write the proposals to a file instead of reviewing and applying them.
    bool dryRun;
    /// Byte budget of a batch.
    size_t batchBytes = defaultBatchBytes;
}

/// What a migration did.
struct Report
{
    size_t entriesBefore, entriesAfter, untagged, batches, tagged, merged, superseded, skipped, invalid;
    /// The backup directory (null when nothing was applied).
    string backup;
    /// The dry-run proposals file (null unless a dry run).
    string dryRunFile;
    /// The user stopped before the end; the next run resumes.
    bool stopped;

    /// A summary for the user.
    string toString() const pure
    {
        auto o = format("memory migrate: %s current entr%s before, %s after; %s untagged reviewed in %s batch%s; "
            ~ "%s tagged, %s merged, %s superseded, %s skipped, %s invalid proposal%s dropped",
            entriesBefore, entriesBefore == 1 ? "y" : "ies", entriesAfter, untagged, batches, batches == 1 ? "" : "es",
            tagged, merged, superseded, skipped, invalid, invalid == 1 ? "" : "s");
        if (stopped) o ~= "\nStopped: run it again to resume.";
        if (backup !is null) o ~= "\nBackup of the memory files: " ~ backup ~ " (copy them back to undo).";
        if (dryRunFile !is null) o ~= "\nDry run: proposals written to " ~ dryRunFile ~ "; nothing was changed.";
        return o;
    }
}

/// Whether `e` still needs tagging: current, with no entities and no fact kind.
bool untagged(const Entry e) pure
{
    return !e.isSuperseded && !e.entities.length && e.factKind is null;
}

/// The line an entry is shown to the model as.
string render(const Entry e)
{
    auto j = JSONValue(["id": JSONValue(e.id), "text": JSONValue(e.text)]);
    if (e.evidence !is null) j["evidence"] = e.evidence;
    if (e.entities.length) j["entities"] = JSONValue(e.entities);
    if (e.factKind !is null) j["fact_kind"] = e.factKind;
    j["created"] = e.created.length >= 10 ? e.created[0 .. 10] : e.created;
    return j.toString(JSONOptions.doNotEscapeSlashes);
}

/// Split `entries` into batches whose rendered lines total at most `budget`
/// bytes; an entry larger than the budget goes alone.
const(Entry)[][] batches(const Entry[] entries, size_t budget)
{
    const(Entry)[][] r;
    const(Entry)[] cur;
    size_t used;
    foreach (ref e; entries)
    {
        auto n = render(e).length + 1;
        if (cur.length && used + n > budget) { r ~= cur; cur = null; used = 0; }
        cur ~= e;
        used += n;
    }
    if (cur.length) r ~= cur;
    return r;
}

/// The instructions for the model.
enum systemPrompt = `You tidy a store of short memories (facts an agent saved across sessions).
For each NEW entry propose entities and a fact_kind. Across the NEW and TAGGED entries, propose
merges of duplicates (same fact) and supersessions of stale entries that a newer entry contradicts.
Entities are "type:name" with type one of host, service, repo, tool, person, workflow, other
(lower-case names, e.g. "repo:nanobpm/nano-coder", "host:merlin", "tool:dub").
fact_kind is one of fact, procedure, decision, pitfall, preference, pointer.
Reply with ONLY a JSON object, no prose:
{"tags":[{"id":"...","entities":["type:name"],"fact_kind":"fact"}],
 "merges":[{"keep":"<id with the better text>","drop":["<duplicate id>"],"text":"<optional improved single-line text>","why":"..."}],
 "supersedes":[{"old":"<stale id>","new":"<newer id>","why":"..."}]}
Only merge true duplicates and only supersede when the newer entry clearly replaces the old one. Omit what you are unsure of.`;

/// The user message for one batch: the batch, then a digest of tagged
/// entries capped at `contextBytes`.
string batchPrompt(const Entry[] batch, const Entry[] tagged)
{
    string o = "NEW entries (one JSON object per line):\n";
    foreach (ref e; batch) o ~= render(e) ~ "\n";
    string ctx;
    foreach (ref e; tagged)
    {
        auto line = render(e) ~ "\n";
        if (ctx.length + line.length > contextBytes) break;
        ctx ~= line;
    }
    if (ctx.length) o ~= "\nTAGGED entries (for duplicates and supersessions only):\n" ~ ctx;
    return o;
}

/// The model's proposals, validated: ids must name current entries of this
/// scope (`current`), tags only batch entries (`batchIds`), entities and
/// kinds must parse. `invalid` counts the items dropped.
Proposal[] parseProposals(string reply, const string[] batchIds, const string[] current, out size_t invalid)
{
    Proposal[] r;
    auto a = reply.indexOf('{'), b = reply.lastIndexOf('}');
    if (a < 0 || b <= a) { invalid = 1; return r; }
    JSONValue j;
    if (!tryParseJson(reply[a .. b + 1], j) || j.type != JSONType.object) { invalid = 1; return r; }
    JSONValue[] list(string k)
    {
        if (auto v = k in j)
        {
            if (v.type == JSONType.array) return v.arrayNoRef;
            invalid++; // a present but non-array collection is schema-invalid, not an empty one
        }
        return null;
    }
    string str(JSONValue v, string k)
    {
        if (v.type == JSONType.object) if (auto x = k in v) if (x.type == JSONType.string) return x.str.strip;
        return null;
    }
    string[] strs(JSONValue v, string k)
    {
        string[] o;
        if (v.type == JSONType.object) if (auto x = k in v) if (x.type == JSONType.array)
            foreach (s; x.arrayNoRef) if (s.type == JSONType.string) o ~= s.str.strip;
        return o;
    }
    bool[string] used; // an id in at most one merge or supersession
    foreach (t; list("tags"))
    {
        auto id = str(t, "id");
        if (!batchIds.canFind(id)) { invalid++; continue; }
        string[] ents;
        bool bad;
        foreach (raw; strs(t, "entities"))
        {
            string error;
            // Check the raw value: lower-casing can hide a case-sensitive token shape (as saveFact does).
            auto ne = looksLikeSecret(raw) !is null ? null : normalizeEntityOr(raw, error);
            if (ne is null) bad = true; // a secret-like, unknown-type or bad name drops just that entity
            else if (!ents.canFind(ne)) ents ~= ne;
        }
        if (ents.length > maxAnchors) ents = ents[0 .. maxAnchors];
        string kind = str(t, "fact_kind");
        if (kind !is null && !factKinds.canFind(kind)) kind = null;
        if (!ents.length && kind is null) { invalid++; continue; }
        if (bad) invalid++;
        r ~= Proposal(TagProposal(id, ents, kind));
    }
    foreach (m; list("merges"))
    {
        auto keep = str(m, "keep");
        string[] drop;
        foreach (d; strs(m, "drop")) if (d != keep && current.canFind(d) && d !in used && !drop.canFind(d)) drop ~= d;
        if (!current.canFind(keep) || keep in used || !drop.length) { invalid++; continue; }
        auto text = str(m, "text");
        if (text !is null && !validText(text)) text = null;
        used[keep] = true;
        foreach (d; drop) used[d] = true;
        r ~= Proposal(MergeProposal(keep, drop, text, str(m, "why")));
    }
    foreach (s; list("supersedes"))
    {
        auto old = str(s, "old"), newer = str(s, "new");
        if (old == newer || !current.canFind(old) || !current.canFind(newer) || old in used) { invalid++; continue; }
        used[old] = true;
        r ~= Proposal(SupersedeProposal(old, newer, str(s, "why")));
    }
    return r;
}

/// Whether `text` may replace a memory's text: non-empty, one line, within
/// the save limit and not secret-looking (as `memory_save` checks).
bool validText(string text)
{
    import std.algorithm : any;
    if (!text.length || text.byDchar.walkLength > maxTextChars) return false;
    if (text.byDchar.any!isLineBreak) return false;
    return looksLikeSecret(text) is null;
}

/// Whether `e`, as it would be rendered (text, evidence, valid_while and
/// entity names together), trips the secret checks `memory_save` applies:
/// each field alone and every split-field join. `apply` refuses a change
/// whose result fails this, so migration never persists what a save refuses.
bool entryLooksSecret(const Entry e)
{
    if (looksLikeSecret(e.text) !is null) return true;
    string[] others;
    if (e.evidence !is null) others ~= e.evidence;
    if (e.validWhile !is null) others ~= e.validWhile;
    foreach (o; others)
        if (looksLikeSecret(o) !is null || looksLikeSecret(e.text ~ o) !is null || looksLikeSecret(e.text ~ " " ~ o) !is null
                || evidenceStatesLabelValue(e.text, o))
            return true;
    if (e.evidence !is null && e.validWhile !is null
            && (looksLikeSecret(e.evidence ~ e.validWhile) !is null || looksLikeSecret(e.evidence ~ " " ~ e.validWhile) !is null
                || evidenceStatesLabelValue(e.evidence, e.validWhile)))
        return true;
    foreach (j; entitiesJoined(e.text, e.evidence, e.validWhile, e.entities)) if (looksLikeSecret(j) !is null) return true;
    foreach (en; e.entities)
    {
        if (looksLikeSecret(en) !is null) return true;
        foreach (o; [e.text] ~ others) if (evidenceStatesLabelValue(o, en)) return true;
    }
    return false;
}

/// Counts from `apply`.
struct Applied { size_t tagged, merged, superseded, skipped; }

/// Apply accepted proposals to one scope's entries. A proposal whose ids
/// are no longer current (changed since it was made) is skipped. Merges keep
/// `keep` with the better text and the union of anchors, evidence and
/// entities; the dropped entries stay on disk, superseded by `keep`.
Applied apply(ref Entry[] entries, const Proposal[] accepted, const EntityRecord[] records)
{
    Applied n;
    ptrdiff_t at(string id)
    {
        foreach (i, ref e; entries) if (e.id == id && !e.isSuperseded) return i;
        return -1;
    }
    foreach (p; accepted)
    {
        // Each change is checked as a whole: a result that a save would refuse
        // as secret-like (in any field or split across fields) is rolled back.
        auto before = entries.dup;
        auto counts = n;
        bool rollback; // a merge that can't keep every dropped entry's evidence
        p.match!(
            (const TagProposal t) {
                auto i = at(t.id);
                if (i < 0) { n.skipped++; return; }
                auto e = &entries[i];
                foreach (en; t.entities)
                {
                    auto id = resolveEntity(records, en);
                    if (e.entities.canFind(id) || e.entities.length >= maxAnchors) continue;
                    e.entities ~= id;
                    if (entryLooksSecret(*e)) e.entities = e.entities[0 .. $ - 1]; // drop just that entity
                }
                if (e.factKind is null && t.factKind !is null) e.factKind = t.factKind;
                n.tagged++;
            },
            (const MergeProposal m) {
                auto k = at(m.keep);
                ptrdiff_t[] ds;
                foreach (d; m.drop) { auto i = at(d); if (i >= 0 && i != k) ds ~= i; }
                if (k < 0 || !ds.length) { n.skipped++; return; }
                auto keep = &entries[k];
                // anchorsOf gives explicit anchors or, failing those, the ones inferred
                // from text and evidence: keep the union so no trigger is lost.
                string[] anchors = anchorsOf(*keep);
                bool rule = keep.isRule;
                foreach (i; ds)
                {
                    auto d = &entries[i];
                    // Different validity conditions are different facts: merging would silently
                    // keep only one condition, so roll the whole merge back.
                    if (d.validWhile != keep.validWhile) { rollback = true; return; }
                    foreach (an; anchorsOf(*d)) if (!anchors.canFind(an)) anchors ~= an;
                    rule = rule || d.isRule;
                    foreach (en; d.entities) if (!keep.entities.canFind(en)) keep.entities ~= en;
                    if (d.evidence !is null && d.evidence != keep.evidence)
                    {
                        auto joined = keep.evidence is null ? d.evidence : keep.evidence ~ "; " ~ d.evidence;
                        // Superseding an entry whose evidence can't be kept would lose its
                        // verification source: roll the whole merge back instead.
                        if (joined.byDchar.walkLength > maxEvidenceChars || looksLikeSecret(joined) !is null)
                        {
                            rollback = true;
                            return;
                        }
                        keep.evidence = joined;
                    }
                    if (keep.factKind is null) keep.factKind = d.factKind;
                    if (keep.kind is null && d.kind !is null) keep.kind = d.kind;
                    if (d.lastUsedTime > keep.lastUsedTime) { keep.lastUsedTime = d.lastUsedTime; keep.lastUsed = d.lastUsed; }
                    d.supersededBy = keep.id;
                    if (!keep.supersedes.canFind(d.id)) keep.supersedes ~= d.id;
                }
                if (rule) keep.kind = "rule"; // a rule stays recalled on every matching call
                if (keep.entities.length > maxAnchors) keep.entities = keep.entities[0 .. maxAnchors];
                if (m.text !is null && validText(m.text)) keep.text = m.text;
                // Pin the union as explicit anchors when the merged entry would no longer infer them all.
                auto now_ = anchorsOf(*keep);
                if (anchors.any!(a => !now_.canFind(a)))
                {
                    keep.hasAnchors = true;
                    keep.anchors = anchors.length > maxAnchors ? anchors[0 .. maxAnchors] : anchors;
                }
                n.merged += ds.length;
            },
            (const SupersedeProposal s) {
                auto o = at(s.old), w = at(s.newer);
                if (o < 0 || w < 0 || o == w) { n.skipped++; return; }
                entries[o].supersededBy = entries[w].id;
                if (!entries[w].supersedes.canFind(entries[o].id)) entries[w].supersedes ~= entries[o].id;
                n.superseded++;
            });
        bool refused = rollback;
        foreach (i, ref e; entries) if (e != before[i] && entryLooksSecret(e)) refused = true;
        if (refused)
        {
            entries = before;
            n = counts;
            n.skipped++;
        }
    }
    return n;
}

/// The ids of the entries `p` changes.
const(string)[] touchedIds(const Proposal p) pure
{
    return p.match!(
        (const TagProposal t) => [t.id],
        (const MergeProposal m) => [m.keep] ~ m.drop.dup,
        (const SupersedeProposal s) => [s.old, s.newer]);
}

/// Whether `a` and `b` hold the same memory content (usage stamps aside).
bool sameContent(const Entry a, const Entry b) pure
{
    return a.id == b.id && a.text == b.text && a.evidence == b.evidence && a.kind == b.kind
        && a.anchors == b.anchors && a.hasAnchors == b.hasAnchors && a.entities == b.entities
        && a.factKind == b.factKind && a.supersedes == b.supersedes && a.validWhile == b.validWhile
        && a.supersededBy == b.supersededBy && a.verifiedAt == b.verifiedAt;
}

/// The proposals of `accepted` whose touched entries are unchanged between
/// the `reviewed` snapshot and `current`; `stale` counts the rest.
Proposal[] freshOnly(Proposal[] accepted, const Entry[] reviewed, const Entry[] current, out size_t stale)
{
    string[] ignored;
    return freshOnly(accepted, reviewed, current, stale, ignored);
}

/// Ditto, also collecting the ids touched by stale proposals so the caller can leave them
/// unreviewed in the progress file (they must be offered again on the next run).
Proposal[] freshOnly(Proposal[] accepted, const Entry[] reviewed, const Entry[] current, out size_t stale,
    out string[] staleIds)
{
    bool same(string id)
    {
        ptrdiff_t r = -1, c = -1;
        foreach (i, ref e; reviewed) if (e.id == id) r = i;
        foreach (i, ref e; current) if (e.id == id) c = i;
        return r >= 0 && c >= 0 && sameContent(reviewed[r], current[c]);
    }
    // A proposal is deferred when its entries changed or when it overlaps (transitively)
    // a deferred one: applying it alone would tag an entry whose merge is still pending,
    // and the next run would then filter that entry out and never re-offer the merge.
    auto deferred = new bool[accepted.length];
    foreach (i, p; accepted)
        if (!touchedIds(p).all!(id => same(id)))
        {
            deferred[i] = true;
            foreach (id; touchedIds(p)) if (!staleIds.canFind(id)) staleIds ~= id;
        }
    for (bool grew = true; grew;)
    {
        grew = false;
        foreach (i, p; accepted)
            if (!deferred[i] && touchedIds(p).any!(id => staleIds.canFind(id)))
            {
                deferred[i] = grew = true;
                foreach (id; touchedIds(p)) if (!staleIds.canFind(id)) staleIds ~= id;
            }
    }
    Proposal[] o;
    foreach (i, p; accepted)
    {
        if (deferred[i]) stale++;
        else o ~= p;
    }
    return o;
}

/// One line describing a proposal, quoting the entries it touches.
string describe(const Proposal p, const Entry[] entries)
{
    import nano.trajectory : terminalSafe;
    string show(string id)
    {
        foreach (ref e; entries) if (e.id == id) return format("[%s] %s", terminalSafe(id), terminalSafe(e.text));
        return "[" ~ terminalSafe(id) ~ "]";
    }
    return p.match!(
        (const TagProposal t) => format("tag %s\n      entities: %s; kind: %s", show(t.id),
            t.entities.length ? t.entities.join(", ") : "(none)", t.factKind is null ? "(unchanged)" : t.factKind),
        (const MergeProposal m) => format("merge into %s\n%s%s%s", show(m.keep),
            m.drop.map!(d => "      duplicate " ~ show(d)).join("\n"),
            m.text !is null ? "\n      new text: " ~ terminalSafe(m.text) : "",
            m.why.length ? "\n      why: " ~ terminalSafe(m.why) : ""),
        (const SupersedeProposal s) => format("supersede %s\n      by %s%s", show(s.old), show(s.newer),
            s.why.length ? "\n      why: " ~ terminalSafe(s.why) : ""));
}

/// The ids reviewed so far, per scope file name.
struct Progress
{
    bool[string][string] done;

    /// Load from `root`; empty when there is no (readable) file.
    static Progress load(string root)
    {
        import std.file : exists;
        Progress p;
        auto path = buildPath(root, progressFile);
        if (!path.exists) return p;
        // A corrupt progress file restarts the review; tagged entries are skipped anyway.
        JSONValue j;
        if (!tryParseJson(utf8Text(readBytes(path)), j) || j.type != JSONType.object) return p;
        if (auto d = "done" in j)
            if (d.type == JSONType.object)
                foreach (k, v; d.objectNoRef)
                    if (v.type == JSONType.array)
                        foreach (id; v.arrayNoRef) if (id.type == JSONType.string) p.done[k][id.str] = true;
        return p;
    }

    /// Write to `root` atomically, under a lock, unioned with the ids on disk
    /// so concurrent migrations never drop each other's progress.
    void save(string root)
    {
        import std.string : representation;
        auto path = buildPath(root, progressFile);
        auto lock = FileLock(path);
        foreach (k, ids; load(root).done)
            foreach (id, _; ids) done[k][id] = true;
        JSONValue[string] d;
        foreach (k, ids; done)
        {
            auto list = ids.keys;
            sort(list);
            d[k] = JSONValue(list);
        }
        auto j = JSONValue(["done": JSONValue(d)]);
        writeBody(path, j.toString.representation);
    }

    /// Whether `id` in `file` was reviewed.
    bool has(string file, string id) const pure
    {
        if (auto m = file in done) return (id in *m) !is null;
        return false;
    }
}

/// Copy the memory files (scope files, registries, recall log) under
/// `root/backups/migrate-<stamp>/`; returns that directory.
string backup(string root)
{
    import std.file : dirEntries, SpanMode, exists, isFile, mkdir, mkdirRecurse, FileException;
    import std.string : startsWith, endsWith;
    auto t = wallNow;
    auto base = buildPath(root, "backups", format("migrate-%04d%02d%02d-%02d%02d%02d", t.year, t.month, t.day,
        t.hour, t.minute, t.second));
    // Reserve the directory atomically: mkdir fails when it exists, so two
    // migrations starting in the same second never share (and overwrite) a backup.
    mkdirRecurse(dirName(base));
    string dir;
    for (int i = 1; ; i++)
    {
        dir = i == 1 ? base : format("%s-%s", base, i);
        try { mkdir(dir); break; }
        catch (FileException e) { if (!dir.exists) throw e; }
    }
    foreach (string p; dirEntries(root, SpanMode.depth))
    {
        auto rel = p[root.length .. $];
        while (rel.startsWith("/")) rel = rel[1 .. $];
        if (rel.startsWith("backups") || !p.isFile || !p.endsWith(".jsonl")) continue;
        writeBody(buildPath(dir, rel), readBytes(p));
    }
    return dir;
}

/// Review `ps` with the user: the accepted (possibly edited) proposals, or
/// null with `stop` set when the user stops; `skipped` counts declined ones.
Proposal[] review(Proposal[] ps, const Entry[] entries, Ui ui, out bool stop, ref size_t skipped)
{
    foreach (i, p; ps) ui.say(format("  %s. %s", i + 1, describe(p, entries)));
    auto choice = ui.select(format("%s proposal%s", ps.length, ps.length == 1 ? "" : "s"),
        ["Accept all", "Review each", "Skip this batch", "Stop (resume later)"]);
    if (choice < 0 || choice == 3) { stop = true; return null; }
    if (choice == 0) return ps;
    if (choice == 2) { skipped += ps.length; return null; }
    Proposal[] r;
    foreach (i, p; ps)
    {
        ui.say(format("  %s. %s", i + 1, describe(p, entries)));
        bool canEdit = p.match!((const SupersedeProposal _) => false, _ => true);
        string[] labels = canEdit ? ["Accept", "Skip", "Edit", "Stop (resume later)"] : ["Accept", "Skip", "Stop (resume later)"];
        auto c = ui.select("This change?", labels);
        if (c < 0 || labels[c].canFind("Stop")) { stop = true; return null; }
        if (labels[c] == "Skip") { skipped++; continue; }
        if (labels[c] == "Edit")
        {
            auto edited = edit(p, ui);
            if (edited.length) r ~= edited[0];
            else skipped++;
            continue;
        }
        r ~= p;
    }
    return r;
}

/// Edit a tag (entities, kind) or a merge (its text); empty when cancelled or invalid.
private Proposal[] edit(Proposal p, Ui ui)
{
    return p.match!(
        (TagProposal t) {
            auto ents = ui.input("Entities (comma-separated type:name)", t.entities.join(", "));
            if (ents is null) return Proposal[].init;
            auto kind = ui.input("Fact kind (" ~ factKinds.join("/") ~ ")", t.factKind is null ? "" : t.factKind);
            if (kind is null) return Proposal[].init;
            TagProposal o;
            o.id = t.id;
            foreach (raw; ents.split(","))
            {
                if (!raw.strip.length) continue;
                string error;
                if (looksLikeSecret(raw) !is null) { ui.say("  ignored: an entity name looks like a secret"); continue; }
                auto ne = normalizeEntityOr(raw, error);
                if (error !is null) ui.say("  ignored: " ~ error);
                else if (!o.entities.canFind(ne)) o.entities ~= ne;
            }
            kind = kind.strip;
            o.factKind = factKinds.canFind(kind) ? kind : null;
            if (!o.entities.length && o.factKind is null) return Proposal[].init;
            return [Proposal(o)];
        },
        (MergeProposal m) {
            auto text = ui.input("Merged text (empty keeps the kept entry's)", m.text is null ? "" : m.text);
            if (text is null) return Proposal[].init;
            text = text.strip;
            if (text.length && !validText(text)) { ui.say("  text refused (multi-line, too long or secret-like)"); return Proposal[].init; }
            m.text = text.length ? text : null;
            return [Proposal(m)];
        },
        (SupersedeProposal s) => [Proposal(s)]);
}

/// The proposals as JSON for a dry run.
JSONValue toJson(const Proposal p)
{
    return p.match!(
        (const TagProposal t) => JSONValue(["action": JSONValue("tag"), "id": JSONValue(t.id),
            "entities": JSONValue(t.entities.dup), "fact_kind": t.factKind is null ? JSONValue(null) : JSONValue(t.factKind)]),
        (const MergeProposal m) => JSONValue(["action": JSONValue("merge"), "keep": JSONValue(m.keep),
            "drop": JSONValue(m.drop.dup), "text": m.text is null ? JSONValue(null) : JSONValue(m.text), "why": JSONValue(m.why)]),
        (const SupersedeProposal s) => JSONValue(["action": JSONValue("supersede"), "old": JSONValue(s.old),
            "new": JSONValue(s.newer), "why": JSONValue(s.why)]));
}

/// Run a migration over every scope of `store` (see the module comment).
Report migrate(Store store, Ask ask, Ui ui, Options opts)
{
    import std.string : representation;
    Report rep;
    auto progress = Progress.load(store.root);
    JSONValue[] dry;
    size_t current(Scope s) { return store.scopeEntries(s).filter!(e => !e.isSuperseded).walkLength; }
    foreach (s; [Scope.user, Scope.project])
        if (store.hasScope(s)) rep.entriesBefore += current(s);
    scopes: foreach (s; [Scope.user, Scope.project])
    {
        if (!store.hasScope(s)) continue;
        auto file = store.path(s).baseName;
        auto all = store.scopeEntries(s);
        auto pending = all.filter!(e => untagged(e) && !progress.has(file, e.id)).array;
        rep.untagged += pending.length;
        foreach (batch; batches(pending, opts.batchBytes))
        {
            // Re-read: an earlier batch (or another session) may have changed the scope.
            auto now = store.scopeEntries(s);
            progress = Progress.load(store.root); // another session may have reviewed some meanwhile
            string[] cur, ids, want;
            foreach (ref e; now) if (!e.isSuperseded) cur ~= e.id;
            foreach (ref b; batch) want ~= b.id;
            // Ask about the entries as they are now, and only those still untagged and unreviewed.
            const(Entry)[] live = now.filter!(e => !e.isSuperseded && want.canFind(e.id) && untagged(e)
                && !progress.has(file, e.id)).array;
            foreach (ref e; live) ids ~= e.id;
            if (!live.length) continue;
            rep.batches++;
            auto tagged = now.filter!(e => !e.isSuperseded && !untagged(e)).array;
            size_t bad;
            ui.say(format("Asking the model about %s scope batch %s (%s entr%s)…", name(s), rep.batches, live.length,
                live.length == 1 ? "y" : "ies"));
            auto ps = parseProposals(ask(systemPrompt, batchPrompt(live, tagged)), ids, cur, bad);
            rep.invalid += bad;
            if (opts.dryRun)
            {
                foreach (p; ps)
                {
                    auto j = toJson(p);
                    j["scope"] = name(s);
                    dry ~= j;
                }
                continue;
            }
            Proposal[] accepted;
            string[] staleIds;
            if (ps.length)
            {
                ui.say(format("%s scope, batch %s (%s entr%s):", name(s), rep.batches, live.length, live.length == 1 ? "y" : "ies"));
                bool stop;
                accepted = review(ps, now, ui, stop, rep.skipped);
                if (stop) { rep.stopped = true; break scopes; }
            }
            if (accepted.length)
            {
                if (rep.backup is null) { rep.backup = backup(store.root); ui.say("Backed up the memory files to " ~ rep.backup); }
                Applied got;
                size_t stale;
                store.editEntries(s, (ref Entry[] es, const EntityRecord[] records) {
                    // Apply only what the user reviewed: a proposal whose entries changed since
                    // (another migration or session) would overwrite newer content.
                    got = apply(es, freshOnly(accepted, now, es, stale, staleIds), records);
                });
                if (stale) ui.say(format("Skipped %s proposal%s whose entries changed since review; re-run to review them again.",
                    stale, stale == 1 ? "" : "s"));
                got.skipped += stale;
                rep.tagged += got.tagged;
                rep.merged += got.merged;
                rep.superseded += got.superseded;
                rep.skipped += got.skipped;
            }
            // A wholly invalid reply (malformed, truncated) reviewed nothing: leave the batch pending.
            if (!ps.length && bad) continue;
            // Entries of proposals skipped as stale stay pending so the next run offers them again.
            foreach (id; ids) if (!staleIds.canFind(id)) progress.done[file][id] = true;
            progress.save(store.root);
        }
    }
    if (opts.dryRun)
    {
        auto t = wallNow;
        rep.dryRunFile = buildPath(store.root, format("migrate-dry-run-%04d%02d%02d-%02d%02d%02d.json", t.year, t.month,
            t.day, t.hour, t.minute, t.second));
        writeBody(rep.dryRunFile, JSONValue(["proposals": JSONValue(dry)]).toPrettyString(JSONOptions.doNotEscapeSlashes).representation);
    }
    foreach (s; [Scope.user, Scope.project])
        if (store.hasScope(s)) rep.entriesAfter += current(s);
    return rep;
}

unittest // a fresh proposal overlapping a stale one is deferred too, transitively
{
    auto a = Entry("a", "alpha fact"), b = Entry("b", "beta fact"), c = Entry("c", "gamma fact"), d = Entry("d", "delta fact");
    auto reviewed = [a, b, c, d];
    auto b2 = b; b2.text = "beta changed";
    Proposal[] ps = [Proposal(TagProposal("a")), Proposal(MergeProposal("a", ["b"])),
        Proposal(SupersedeProposal("c", "a")), Proposal(TagProposal("d"))];
    size_t stale;
    string[] ids;
    auto fresh = freshOnly(ps, reviewed, [a, b2, c, d], stale, ids);
    assert(stale == 3);
    assert(fresh.length == 1);
    assert(ids.canFind("a") && ids.canFind("b") && ids.canFind("c"));
}

unittest // merges across differing validity conditions are rolled back
{
    auto a = Entry("a", "use flag x"), b = Entry("b", "use flag x");
    a.validWhile = "v1"; b.validWhile = "v2";
    auto es = [a, b];
    auto n = apply(es, [Proposal(MergeProposal("a", ["b"]))], null);
    assert(n.merged == 0 && n.skipped == 1);
    assert(!es[1].isSuperseded);
}

unittest // entry ids are sanitised for the terminal
{
    auto e = Entry("x\x1b[2J", "t");
    assert(!describe(Proposal(TagProposal("x\x1b[2J")), [e]).canFind('\x1b'));
    assert(!describe(Proposal(TagProposal("y\x1b[2J")), []).canFind('\x1b'));
}
