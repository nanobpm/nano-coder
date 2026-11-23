/+ Benchmark for issue #280: replay a realistic session's tool calls through
 + both recall modes over one memory store and report recalled bytes per call
 + and per turn, and how many recalled notes were about an entity the call
 + touched. Run: dub run --single dev/recall_bench.d  (from the repo root)
 +/
import nano.memory;
import std.algorithm : canFind, any, map, sum;
import std.array : array, join;
import std.format : format;
import std.json : parseJSON, JSONValue;
import std.stdio : writeln, writefln;
import std.file : tempDir, mkdirRecurse, rmdirRecurse, exists;
import std.path : buildPath;

struct Call { string tool; string args; }

// A session heavy on merlin/ssh/gh calls, like a fleet-operator shift.
immutable Call[] sessionCalls = [
    Call("bash", `{"command":"ssh merlin.local systemctl status workforce"}`),
    Call("bash", `{"command":"ssh merlin.local journalctl -u workforce -n 50"}`),
    Call("bash", `{"command":"curl -s http://merlin.local:8080/api/health"}`),
    Call("bash", `{"command":"gh issue view 280 -R nanobpm/nano-coder"}`),
    Call("bash", `{"command":"ssh merlin.local df -h"}`),
    Call("read_file", `{"path":"source/app.d"}`),
    Call("bash", `{"command":"ssh omarchy.local uptime"}`),
    Call("bash", `{"command":"gh pr list -R nanobpm/nano-coder"}`),
    Call("bash", `{"command":"ssh merlin.local tail -f /var/log/workforce.log"}`),
    Call("bash", `{"command":"curl -s http://merlin.local:8080/console/app"}`),
    Call("edit_file", `{"path":"source/nano/memory.d"}`),
    Call("bash", `{"command":"ssh merlin.local free -g"}`),
    Call("bash", `{"command":"gh run list -R nanobpm/nano-coder"}`),
    Call("bash", `{"command":"scp deploy@merlin.local:/var/log/w.log ."}`),
    Call("bash", `{"command":"ssh merlin.local ls /srv"}`),
    Call("bash", `{"command":"git -C /home/u/nano-coder status"}`),
];

void main()
{
    auto dir = buildPath(tempDir, "nano-recall-bench");
    if (dir.exists) rmdirRecurse(dir);
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    auto store = new Store(buildPath(dir, "memory"), "github.com/nanobpm/nano-coder", 0);

    // Seed a noisy store: many memories mention merlin.local (the problem the
    // issue names — one hostname brings back every note that mentions it).
    // Entity-tagged facts about several hosts/repos, plus untagged legacy notes.
    void tag(string text, string[] entities, string factKind, string kind = null)
    {
        SaveOptions o; o.entities = entities; o.factKind = factKind; o.distinct = true;
        store.saveFact(Scope.user, text, null, null, kind, null, false, o);
    }
    // Facts about merlin (the call's target) — these are the relevant ones.
    tag("merlin OOMs under more than 8 workers; keep it at 6", ["host:merlin"], "pitfall");
    tag("deploy merlin with `just deploy` from ~/Work/merlin", ["host:merlin"], "procedure");
    tag("the workforce service runs_on merlin and listens on 8080", ["service:workforce"], "fact");
    // Facts about OTHER entities that happen to mention merlin.local — the noise.
    tag("merlin.local mirrors the omarchy pacman cache", ["host:omarchy"], "fact");
    tag("merlin.local is where the old wiki used to run", ["other:wiki"], "fact");
    tag("backups rsync off merlin.local nightly to coldstore", ["host:coldstore"], "fact");
    tag("merlin.local DNS is managed in the router, not tailscale", ["other:dns"], "fact");
    tag("nano-coder builds with dub, not make", ["repo:nanobpm/nano-coder"], "decision");
    tag("omarchy.local is the Arch dev box", ["host:omarchy"], "fact");
    tag("gh is aliased to the wrapper in ~/bin on omarchy", ["tool:gh"], "fact");
    // Untagged legacy notes that mention merlin.local (anchor fallback).
    store.saveWith(Scope.user, "legacy note mentioning merlin.local by name", null, null, null, ["merlin.local"], true);
    store.saveWith(Scope.user, "another legacy merlin.local note about disk space", null, null, null, ["merlin.local"], true);

    size_t anchorBytes, anchorNotes, anchorRelevant;
    size_t entityBytes, entityNotes, entityRelevant;
    bool[string] anchorDistinct, entityDistinct;
    // A note is relevant when one of its entry's tagged entities resolves to
    // an entity the call touched (untagged entries count as relevant by name).
    bool relevant(Call c, string id)
    {
        auto touched = resolveCallEntities(store.allEntities(), entitiesFromCall(c.tool, parseJSON(c.args), ""));
        foreach (x; store.all())
            if (x.e.id == id)
            {
                if (!x.e.entities.length) return true; // legacy fallback: count as on-topic
                foreach (en; x.e.entities)
                    if (touched.canFind(resolveEntity(store.allEntities(), en))) return true;
                return false;
            }
        return false;
    }
    {
        Recall st; bool[string] shown;
        foreach (c; sessionCalls)
        {
            auto notes = recall(store, c.tool, parseJSON(c.args), st, shown, 100);
            foreach (n; notes)
            {
                anchorNotes++;
                anchorBytes += n.text.length;
                anchorDistinct[n.id] = true;
                if (relevant(c, n.id)) anchorRelevant++;
            }
        }
    }
    {
        Recall st; bool[string] shown;
        foreach (c; sessionCalls)
        {
            auto notes = recallEntities(store, c.tool, parseJSON(c.args), "", st, shown, 100);
            foreach (n; notes)
            {
                entityNotes++;
                entityBytes += n.text.length;
                entityDistinct[n.id] = true;
                if (relevant(c, n.id)) entityRelevant++;
            }
        }
    }
    auto ncalls = sessionCalls.length;
    writeln("== recall replay (issue #280): ", ncalls, " tool calls, 13 memories (many mention merlin.local) ==");
    writefln!"mode    notes  distinct  bytes/call  bytes/turn  relevant-notes  relevant-%%"();
    writefln!"anchor  %5d  %8d  %10.1f  %10d  %14d  %10.0f"(anchorNotes, anchorDistinct.length, double(anchorBytes)/ncalls, anchorBytes, anchorRelevant, anchorNotes ? 100.0*anchorRelevant/anchorNotes : 0);
    writefln!"entity  %5d  %8d  %10.1f  %10d  %14d  %10.0f"(entityNotes, entityDistinct.length, double(entityBytes)/ncalls, entityBytes, entityRelevant, entityNotes ? 100.0*entityRelevant/entityNotes : 0);
}

import std.string : indexOf, startsWith;
