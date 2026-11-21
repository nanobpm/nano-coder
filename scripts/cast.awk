# Prints `file:line:text` for each `cast(` outside `unittest` blocks (a
# block starts at a line beginning with `unittest` and ends when its braces
# balance). Braces inside string/char literals and `//` comments are ignored
# when balancing (block comments and multi-line strings are not parsed).
FNR == 1 { inut = 0; depth = 0 }
{
    line = $0
    if (!inut && line ~ /^[[:space:]]*(@[a-z]+[[:space:]]+)*unittest([[:space:]{]|$)/) { inut = 1; depth = 0; opened = 0 }
    if (inut) {
        gsub(/\\./, "", line)
        gsub(/"[^"]*"/, "", line); gsub(/`[^`]*`/, "", line); gsub(/'[^']*'/, "", line)
        sub(/\/\/.*/, "", line)
        n = gsub(/\{/, "{", line); m = gsub(/\}/, "}", line)
        depth += n - m; if (n) opened = 1
        if (opened && depth <= 0) inut = 0
        next
    }
    if (line ~ /^[[:space:]]*\/\//) next
    c = gsub(/cast\(/, "cast(", line)
    for (i = 0; i < c; i++) print FILENAME ":" FNR ":" $0
}
