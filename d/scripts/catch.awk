# Reports `catch (Exception)` handlers that swallow the exception without a
# comment saying why (see check-safe.sh), and any `catch (Throwable)` or
# `catch (Error)`.
#
# A handler swallows when it neither rethrows (`throw`) nor uses the caught
# variable (`e.msg`, passing `e` on). Swallowing is sometimes right (an
# optional title, a best-effort cleanup, a probe whose failure means "no"),
# but the reader can't tell that from a bare `catch (Exception) {}`, so it
# needs a `//` comment: on the catch line, on the line above, or inside the
# handler. Handlers that report or rethrow need none.
#
# Lexical: strings and character literals are blanked before braces are
# counted. Prints `file(line): ...` for each offender.
function strip(s) {
    gsub(/\\./, "", s)
    gsub(/"[^"]*"/, "\"\"", s)
    gsub(/`[^`]*`/, "``", s)
    gsub(/'[^']*'/, "''", s)
    return s
}
function report(    msg) {
    if (uses) return
    if (commented) return
    printf "%s(%d): Error: `catch (Exception)` swallows the exception; say why in a `//` comment (or report or rethrow it)\n", FILENAME, cline
}
FNR == 1 { inh = 0; prevComment = 0 }
{
    raw = $0
    s = strip(raw)
    isComment = (s ~ /^[[:space:]]*\/\//)
    code = s; sub(/\/\/.*/, "", code)
    hasComment = (s ~ /\/\//)
    if (inh) {
        # Inside a handler body: look for a use, a throw or a comment.
        if (hasComment) commented = 1
        if (code ~ /(^|[^[:alnum:]_])throw([^[:alnum:]_]|$)/) uses = 1
        if (var != "" && code ~ ("(^|[^[:alnum:]_.])" var "([^[:alnum:]_]|$)")) uses = 1
        len = length(code)
        for (i = 1; i <= len; i++) {
            c = substr(code, i, 1)
            if (c == "{") { depth++; opened = 1 }
            else if (c == "}") depth--
        }
        if ((opened && depth <= 0) || (!opened && code ~ /;[[:space:]]*$/)) { report(); inh = 0 }
        if (!isComment && code !~ /^[[:space:]]*$/) prevComment = 0
        if (isComment) prevComment = 1
        next
    }
    if (code ~ /catch[[:space:]]*\([[:space:]]*(Throwable|Error)([[:space:]]|\))/) {
        printf "%s(%d): Error: don't catch `Throwable` or `Error`: they mean a broken invariant or out of memory, and @safe code can't recover from them\n", FILENAME, FNR
        next
    }
    if (match(code, /catch[[:space:]]*\([[:space:]]*Exception([[:space:]]+[[:alnum:]_]+)?[[:space:]]*\)/)) {
        head = substr(code, RSTART, RLENGTH)
        var = head
        sub(/^catch[[:space:]]*\([[:space:]]*Exception[[:space:]]*/, "", var)
        sub(/[[:space:]]*\)$/, "", var)
        rest = substr(code, RSTART + RLENGTH)
        cline = FNR
        commented = prevComment || hasComment
        uses = 0
        depth = 0; opened = 0
        if (rest ~ /(^|[^[:alnum:]_])throw([^[:alnum:]_]|$)/) uses = 1
        if (var != "" && rest ~ ("(^|[^[:alnum:]_.])" var "([^[:alnum:]_]|$)")) uses = 1
        len = length(rest)
        for (i = 1; i <= len; i++) {
            c = substr(rest, i, 1)
            if (c == "{") { depth++; opened = 1 }
            else if (c == "}") depth--
        }
        if ((opened && depth <= 0) || (!opened && rest ~ /;[[:space:]]*$/)) report()
        else inh = 1
        prevComment = 0
        next
    }
    if (isComment) prevComment = 1
    else if (code !~ /^[[:space:]]*$/) prevComment = 0
}
