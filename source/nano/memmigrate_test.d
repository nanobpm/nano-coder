/// Tests for `/memory migrate` (issue #281) with a mock model and a scripted user.
module nano.memmigrate_test;

@safe:

version (unittest):

import nano.memmigrate;
import nano.memory;
import nano.safeio : readBytes, utf8Text;
import std.algorithm : canFind, count, filter, startsWith;
import std.array : array;
import std.file;
import std.format : format;
import std.json;
import std.path;
import std.sumtype : match;

private string tmp(string name)
{
    auto d = buildPath(tempDir, "nano-d-memmigrate-" ~ name);
    if (d.exists) rmdirRecurse(d);
    mkdirRecurse(d);
    return d;
}

private Store store(string dir) { return new Store(buildPath(dir, "memory"), null, defaultExpiryDays); }

/// A scripted user: `selects` answers the menus in order, `inputs` the value prompts.
private struct Script
{
    ptrdiff_t[] selects;
    string[] inputs;
    string[] said;
    size_t asked;

    Ui ui() return
    {
        Ui u;
        u.select = (string prompt, const string[] labels) {
            asked++;
            if (!selects.length) return ptrdiff_t(-1);
            auto c = selects[0];
            selects = selects[1 .. $];
            return c;
        };
        u.input = (string prompt, string initial) {
            if (!inputs.length) return string.init;
            auto v = inputs[0];
            inputs = inputs[1 .. $];
            return v;
        };
        u.say = (string line) { said ~= line; };
        return u;
    }
}

private Entry byId(Store s, string id)
{
    foreach (e; s.scopeEntries(Scope.user)) if (e.id == id) return e;
    assert(0, "no entry " ~ id);
}

unittest // batches are bounded by bytes, an oversized entry goes alone, and nothing is lost
{
    Entry[] es;
    foreach (i; 0 .. 30)
    {
        Entry e;
        e.id = format("mem-%02d", i);
        e.text = i == 7 ? "x".replicateText(700) : format("fact number %s about the build", i);
        e.created = "2026-11-01T00:00:00Z";
        es ~= e;
    }
    auto bs = batches(es, 400);
    size_t total;
    foreach (b; bs)
    {
        size_t bytes;
        foreach (ref e; b) bytes += render(e).length + 1;
        assert(bytes <= 400 || b.length == 1, "a batch stays within the byte budget");
        total += b.length;
    }
    assert(total == es.length && bs.length > 3);
    assert(bs.canFind!(b => b.length == 1 && b[0].id == "mem-07"), "the oversized entry goes alone");
}

private string replicateText(string s, size_t n)
{
    string o;
    foreach (_; 0 .. n) o ~= s;
    return o;
}

unittest // the prompt's tagged digest is capped in bytes
{
    Entry[] tagged;
    foreach (i; 0 .. 200)
    {
        Entry e;
        e.id = format("mem-t%03d", i);
        e.text = "a tagged fact that takes some room in the prompt";
        e.created = "2026-11-01T00:00:00Z";
        e.factKind = "fact";
        tagged ~= e;
    }
    auto p = batchPrompt(tagged[0 .. 1], tagged);
    assert(p.length < contextBytes + 1_000 && p.canFind("TAGGED"));
}

unittest // invalid proposals are dropped and counted
{
    size_t bad;
    auto ps = parseProposals(`noise {"tags":[{"id":"a","entities":["host:Merlin","bogus:x"],"fact_kind":"pitfall"},
        {"id":"zzz","fact_kind":"fact"}],"merges":[{"keep":"a","drop":["a"]},{"keep":"b","drop":["c","nope"],"text":"line\nbreak"}],
        "supersedes":[{"old":"b","new":"a"},{"old":"d","new":"a"}]} trailing`, ["a", "b"], ["a", "b", "c", "d"], bad);
    assert(ps.length == 3, format("%s", ps.length));
    ps[0].match!((TagProposal t) { assert(t.entities == ["host:merlin"] && t.factKind == "pitfall"); }, (_) { assert(0); });
    ps[1].match!((MergeProposal m) { assert(m.keep == "b" && m.drop == ["c"] && m.text is null); }, (_) { assert(0); });
    ps[2].match!((SupersedeProposal s) { assert(s.old == "d" && s.newer == "a"); }, (_) { assert(0); });
    // bogus entity, unknown tag id, self-merge, supersede of an id already merged
    assert(bad == 4, format("%s", bad));
    size_t bad2;
    assert(!parseProposals("not json", [], [], bad2).length && bad2 == 1);
}

/// A store with two duplicates, a stale fact and its replacement, all untagged.
private struct Fixture { Store s; string dupA, dupB, stale, fresh; }

private Fixture fixture(string name)
{
    Fixture f;
    f.s = store(tmp(name));
    f.dupA = f.s.save(Scope.user, "run the tests with dub test", "dub.json", null).id;
    f.dupB = f.s.save(Scope.user, "tests: dub test runs them", "AGENTS.md", null).id;
    f.stale = f.s.save(Scope.user, "merlin runs the worker on port 8080", null, null).id;
    f.fresh = f.s.save(Scope.user, "merlin runs the worker on port 9090 since November", null, null).id;
    return f;
}

private Ask model(Fixture f, ref size_t calls)
{
    return (string system, string user) {
        calls++;
        assert(system.canFind("fact_kind") && user.canFind(f.dupA));
        return format(`{"tags":[{"id":%s,"entities":["tool:dub"],"fact_kind":"procedure"},`
            ~ `{"id":%s,"entities":["host:merlin"],"fact_kind":"fact"}],`
            ~ `"merges":[{"keep":%s,"drop":[%s],"text":"run the tests with dub test (see AGENTS.md)","why":"same fact"}],`
            ~ `"supersedes":[{"old":%s,"new":%s,"why":"port changed"}]}`,
            JSONValue(f.dupA), JSONValue(f.fresh), JSONValue(f.dupA), JSONValue(f.dupB), JSONValue(f.stale), JSONValue(f.fresh));
    };
}

unittest // accept all: tags, merge semantics, supersede hides from listing and recall, backup made
{
    auto f = fixture("accept");
    size_t calls;
    auto u = new Script;
    u.selects = [0];
    auto rep = migrate(f.s, model(f, calls), u.ui, Options.init);
    assert(calls == 1 && rep.batches == 1 && rep.tagged == 2 && rep.merged == 1 && rep.superseded == 1, rep.toString);
    assert(rep.entriesBefore == 4 && rep.entriesAfter == 2, rep.toString);
    auto a = byId(f.s, f.dupA);
    assert(a.text == "run the tests with dub test (see AGENTS.md)");
    assert(a.evidence == "dub.json; AGENTS.md", a.evidence);
    assert(a.entities == ["tool:dub"] && a.factKind == "procedure" && a.supersedes == [f.dupB]);
    auto b = byId(f.s, f.dupB);
    assert(b.supersededBy == f.dupA, "the merged duplicate stays on disk, marked replaced");
    auto st = byId(f.s, f.stale);
    assert(st.supersededBy == f.fresh && byId(f.s, f.fresh).supersedes == [f.stale]);
    assert(!f.s.all().canFind!(x => x.e.id == f.stale || x.e.id == f.dupB));
    assert(!f.s.allForRecall().canFind!(x => x.e.id == f.stale), "superseded entries are not recalled");
    assert(f.s.entities(Scope.user).canFind!(r => r.id == "host:merlin"), "new entities are registered");
    assert(rep.backup !is null && buildPath(rep.backup, "user.jsonl").exists);
    auto saved = utf8Text(readBytes(buildPath(rep.backup, "user.jsonl")));
    assert(!saved.canFind("superseded_by"), "the backup is the state before the change");
}

unittest // nothing changes without confirmation: skip and stop leave the store as it was
{
    auto f = fixture("skip");
    auto before = utf8Text(readBytes(f.s.path(Scope.user)));
    size_t calls;
    auto u = new Script;
    u.selects = [2]; // skip this batch
    auto rep = migrate(f.s, model(f, calls), u.ui, Options.init);
    assert(rep.skipped == 4 && rep.backup is null && rep.tagged == 0);
    assert(utf8Text(readBytes(f.s.path(Scope.user))) == before);
    assert(!buildPath(f.s.root, "backups").exists, "no backup without an applied change");

    auto g = fixture("stop");
    auto beforeG = utf8Text(readBytes(g.s.path(Scope.user)));
    auto v = new Script; // no answers: the menu is cancelled
    auto rep2 = migrate(g.s, model(g, calls), v.ui, Options.init);
    assert(rep2.stopped && utf8Text(readBytes(g.s.path(Scope.user))) == beforeG);
}

unittest // review each: accept, skip and edit per item
{
    auto f = fixture("each");
    size_t calls;
    auto u = new Script;
    // review each; tag 1 edit; tag 2 skip; merge accept; supersede skip
    u.selects = [1, 2, 1, 0, 1];
    u.inputs = ["tool:dub, repo:nanobpm/nano-coder", "pitfall"];
    auto rep = migrate(f.s, model(f, calls), u.ui, Options.init);
    assert(rep.tagged == 1 && rep.merged == 1 && rep.superseded == 0 && rep.skipped == 2, rep.toString);
    auto a = byId(f.s, f.dupA);
    assert(a.entities == ["tool:dub", "repo:nanobpm/nano-coder"] && a.factKind == "pitfall", a.toJson);
    assert(byId(f.s, f.fresh).factKind is null && !byId(f.s, f.stale).isSuperseded);
}

unittest // resume after an interruption, then an idempotent re-run
{
    auto s = store(tmp("resume"));
    string[] ids;
    foreach (i; 0 .. 6) ids ~= s.save(Scope.user, format("fact %s about host alpha%s", i, i), null, null).id;
    size_t calls;
    Ask ask = (string system, string user) {
        calls++;
        JSONValue[] tags;
        foreach (id; ids) if (user.canFind(id) && user.canFind("NEW"))
            tags ~= JSONValue(["id": JSONValue(id), "fact_kind": JSONValue("fact")]);
        return JSONValue(["tags": JSONValue(tags)]).toString;
    };
    Options o;
    o.batchBytes = 2 * (render(byId(s, ids[0])).length + 1); // two entries per batch
    auto u = new Script;
    u.selects = [0, 3]; // accept the first batch, stop at the second
    auto r1 = migrate(s, ask, u.ui, o);
    assert(r1.stopped && r1.tagged == 2 && calls == 2, r1.toString);
    auto v = new Script;
    v.selects = [0, 0];
    auto r2 = migrate(s, ask, v.ui, o);
    assert(!r2.stopped && r2.untagged == 4 && r2.tagged == 4 && calls == 4, r2.toString);
    foreach (id; ids) assert(byId(s, id).factKind == "fact");
    // Re-run: nothing left; a newly saved entry is the only one sent.
    auto w = new Script;
    auto r3 = migrate(s, ask, w.ui, o);
    assert(r3.untagged == 0 && r3.batches == 0 && calls == 4 && w.asked == 0);
    ids ~= s.save(Scope.user, "a new fact about host beta", null, null).id;
    auto x = new Script;
    x.selects = [0];
    auto r4 = migrate(s, ask, x.ui, o);
    assert(r4.untagged == 1 && r4.tagged == 1 && calls == 5, r4.toString);
}

unittest // a batch the user skipped is not offered again; proposals for gone entries are skipped
{
    auto f = fixture("rerun-skip");
    size_t calls;
    auto u = new Script;
    u.selects = [2];
    migrate(f.s, model(f, calls), u.ui, Options.init);
    auto v = new Script;
    auto rep = migrate(f.s, model(f, calls), v.ui, Options.init);
    assert(rep.batches == 0 && calls == 1);

    Entry[] es = [byId(f.s, f.dupA)];
    auto got = apply(es, [Proposal(SupersedeProposal("gone", f.dupA, null))], null);
    assert(got.skipped == 1 && !es[0].isSuperseded);
}

unittest // dry run: proposals go to a file and nothing changes
{
    auto f = fixture("dry");
    auto before = utf8Text(readBytes(f.s.path(Scope.user)));
    size_t calls;
    auto u = new Script;
    Options o;
    o.dryRun = true;
    auto rep = migrate(f.s, model(f, calls), u.ui, o);
    assert(rep.dryRunFile !is null && rep.dryRunFile.exists && u.asked == 0);
    auto j = parseJSON(utf8Text(readBytes(rep.dryRunFile)));
    assert(j["proposals"].arrayNoRef.length == 4);
    assert(utf8Text(readBytes(f.s.path(Scope.user))) == before);
    assert(!buildPath(f.s.root, progressFile).exists && rep.backup is null);
    assert(rep.toString.canFind("nothing was changed"));
}

unittest // merging unions explicit anchors and entities
{
    Entry k, d;
    k.id = "k"; k.text = "use the release build for benchmarks"; k.entities = ["tool:dub"];
    d.id = "d"; d.text = "benchmarks need dub build -b release"; d.hasAnchors = true; d.anchors = ["dub build -b release"];
    d.entities = ["repo:nanobpm/nano-coder"]; d.factKind = "pitfall";
    Entry[] es = [k, d];
    auto got = apply(es, [Proposal(MergeProposal("k", ["d"], null, null))], null);
    assert(got.merged == 1 && es[0].hasAnchors && es[0].anchors.canFind("dub build -b release"));
    assert(es[0].entities == ["tool:dub", "repo:nanobpm/nano-coder"] && es[0].factKind == "pitfall");
    assert(es[0].text == k.text && es[1].supersededBy == "k");
}

unittest // secret-like raw entity names are dropped before lower-casing hides them
{
    size_t bad;
    auto ps = parseProposals(`{"tags":[{"id":"a","entities":["other:AKIAIOSFODNN7EXAMPLE","host:merlin"]}]}`, ["a"], ["a"], bad);
    assert(ps.length == 1 && bad == 1);
    ps[0].match!((TagProposal t) { assert(t.entities == ["host:merlin"]); }, (_) { assert(0); });
}

unittest // a tag whose entity completes a secret split with the evidence is not applied
{
    Entry e;
    e.id = "a"; e.text = "database access notes"; e.evidence = "the admin password:";
    Entry[] es = [e];
    apply(es, [Proposal(TagProposal("a", ["other:hunter2xyz"], null))], null);
    assert(!es[0].entities.canFind("other:hunter2xyz"));
}

unittest // a merge whose final entry reads as a secret is rolled back as a whole
{
    Entry k, d;
    k.id = "k"; k.text = "database access notes"; k.evidence = "hunter2";
    d.id = "d"; d.text = "db notes";
    Entry[] es = [k, d];
    auto got = apply(es, [Proposal(MergeProposal("k", ["d"], "database password", null))], null);
    assert(got.merged == 0 && got.skipped == 1);
    assert(es[0].text == "database access notes" && !es[1].isSuperseded);
}

unittest // merging keeps rule mode and the anchors inferred from the dropped entry
{
    Entry k, d;
    k.id = "k"; k.text = "benchmarks need a release build"; k.kind = "hint";
    d.id = "d"; d.text = "never benchmark ./nano-coder from `dub build`"; d.kind = "rule";
    Entry[] es = [k, d];
    auto inferred = anchorsOf(d);
    assert(inferred.length);
    apply(es, [Proposal(MergeProposal("k", ["d"], null, null))], null);
    assert(es[0].isRule);
    foreach (a; inferred) assert(anchorsOf(es[0]).canFind(a), a);
}

unittest // progress saves merge with the ids another session wrote
{
    auto root = tmp("progress-merge");
    Progress a, b;
    a.done["user.jsonl"]["x"] = true;
    b.done["user.jsonl"]["y"] = true;
    a.save(root);
    b.save(root);
    auto p = Progress.load(root);
    assert(p.has("user.jsonl", "x") && p.has("user.jsonl", "y"));
}

unittest // a wholly invalid model reply leaves the batch pending
{
    auto f = fixture("invalid-reply");
    auto u = new Script;
    auto rep = migrate(f.s, delegate string(string a, string b) => "not json at all", u.ui, Options.init);
    assert(rep.invalid > 0);
    assert(!Progress.load(f.s.root).has("user.jsonl", f.dupA));
}
