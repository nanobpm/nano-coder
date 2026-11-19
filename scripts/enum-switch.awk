# Reports `switch` statements over an enum that have a `default:` (see
# check-safe.sh). A switch counts as being over an enum when one of its own
# `case` labels (not a nested switch's) is a qualified member such as
# `case Role.user:`. Such a switch must be a `final switch`, so the compiler
# rejects it when the enum gains a member nobody handled. A switch that has
# to skip members lists them in one `case A.x, A.y: break;`.
#
# Lexical: strings, character literals and `//` comments are blanked before
# braces are counted. Prints `file(line): ...` for each offender.
function strip(s,    out) {
    gsub(/\\./, "", s)                 # escaped characters inside literals
    gsub(/"[^"]*"/, "\"\"", s)
    gsub(/`[^`]*`/, "``", s)
    gsub(/'[^']*'/, "''", s)
    sub(/\/\/.*/, "", s)
    return s
}
FNR == 1 { n = 0; depth = 0; pending = 0 }
{
    s = strip($0)
    if (s ~ /(^|[^[:alnum:]_])switch[[:space:]]*\(/ && s !~ /final[[:space:]]+switch/) {
        pending = 1; pline = FNR
    }
    len = length(s)
    for (i = 1; i <= len; i++) {
        c = substr(s, i, 1)
        if (c == "{") {
            depth++
            if (pending) { n++; sd[n] = depth; sl[n] = pline; se[n] = 0; sdef[n] = 0; pending = 0 }
        } else if (c == "}") {
            if (n && sd[n] == depth) {
                if (se[n] && sdef[n]) printf "%s(%d): Error: `switch` over an enum has a `default:`; use `final switch` and list the skipped members\n", FILENAME, sl[n]
                n--
            }
            depth--
        }
    }
    # Labels belong to the innermost open switch when they sit directly in
    # its body (depth equal, or one deeper for a `case X: { ... }` block's
    # opening line, which the brace loop has already entered).
    if (n && (depth == sd[n] || depth == sd[n] + 1)) {
        if (s ~ /(^|[^[:alnum:]_])case[[:space:]]+[A-Z][[:alnum:]_]*\.[[:alnum:]_]+/) se[n] = 1
        if (s ~ /(^|[^[:alnum:]_])default[[:space:]]*:/) sdef[n] = 1
    }
}
