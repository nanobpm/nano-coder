# Null checks on class references: prints `file:line: text` for each one.
#
# A class reference that may be null is an optional value nothing marks as
# optional; nano.option.Option!T is the marked kind (see its module comment).
# check-safe ratchets the count of these checks, so new optional references
# use Option (or an always-present object) instead of null.
#
# Run as: awk -v n=<file count> -f class-null.awk FILES FILES FILES
# (the list three times: class names, then declarations, then uses).
#
# Pass 1: class and interface names (exceptions excluded: they are thrown,
#         not stored).
# Pass 2: names declared with one of those types, per file ("Foo x;",
#         "const Foo x =", "Foo x)" for parameters), plus a global set for
#         member access ("agent.editor").
# Pass 3: `x is null`, `x !is null`, `if (x)`, `if (!x)` and
#         `if (auto y = x)` on those names.
#
# It is textual, so it can miss a check (a name declared with `auto`) and
# can't see types across modules for bare names; it is a ratchet, not a
# proof.

function strip_comment(s,    i) {
    i = index(s, "//")
    return i ? substr(s, 1, i - 1) : s
}

FNR == 1 { starts++; pass = int((starts - 1) / n) + 1 }

pass == 1 {
    line = strip_comment($0)
    if (match(line, /(^|[^A-Za-z0-9_])(class|interface)[ \t]+[A-Z][A-Za-z0-9_]*/)) {
        decl = substr(line, RSTART, RLENGTH)
        sub(/.*(class|interface)[ \t]+/, "", decl)
        if (decl !~ /(Error|Exception)$/) cls[decl] = 1
    }
    next
}

pass == 2 {
    line = strip_comment($0)
    rest = " " line
    while (match(rest, /[^A-Za-z0-9_.][A-Z][A-Za-z0-9_]*\)?[ \t]+[a-z_][A-Za-z0-9_]*[ \t]*[;=,)]/)) {
        frag = substr(rest, RSTART + 1, RLENGTH - 1)
        rest = substr(rest, RSTART + RLENGTH)
        type = frag; sub(/[^A-Za-z0-9_].*/, "", type)
        if (!(type in cls)) continue
        name = frag; sub(/^[A-Z][A-Za-z0-9_]*\)?[ \t]+/, "", name); sub(/[^A-Za-z0-9_].*/, "", name)
        local[FILENAME, name] = 1
        member[name] = 1
    }
    next
}

pass == 3 {
    if (FILENAME ~ /_test\.d$/ || FILENAME ~ /\/option\.d$/) next
    line = strip_comment($0)
    if (line ~ /^[ \t]*$/) next
    hit = 0
    rest = line
    # `x is null` / `x !is null`, x possibly a member access.
    while (match(rest, /[A-Za-z_][A-Za-z0-9_.]*[ \t]*!?is[ \t]+null/)) {
        frag = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        ref = frag; sub(/[ \t]*!?is[ \t]+null$/, "", ref)
        if (counts(ref)) hit = 1
    }
    # `if (x)`, `if (!x)`, `if (auto y = x)`.
    rest = line
    while (match(rest, /if[ \t]*\([ \t]*(!|auto[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*=)?[ \t]*[A-Za-z_][A-Za-z0-9_.]*[ \t]*\)/)) {
        frag = substr(rest, RSTART, RLENGTH)
        rest = substr(rest, RSTART + RLENGTH)
        ref = frag
        sub(/^if[ \t]*\([ \t]*(!|auto[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]*=)?[ \t]*/, "", ref)
        sub(/[ \t]*\)$/, "", ref)
        if (counts(ref)) hit = 1
    }
    if (hit) { t = $0; sub(/^[ \t]+/, "", t); print FILENAME ":" FNR ": " t }
}

function counts(ref,    last, k) {
    if (index(ref, ".")) {
        last = ref; sub(/.*\./, "", last)
        return (last in member)
    }
    return ((FILENAME, ref) in local)
}
