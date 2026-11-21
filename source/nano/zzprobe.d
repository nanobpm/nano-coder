module nano.zzprobe;
version (unittest):

import nano.frame;
import std.stdio;
import std.array : replace;

private void show(string label, string[] rows) {
    write(label, ": ");
    foreach (r; rows) write("[", r.replace("\uE002", "<SW>").replace("\uE003", "<VB>").replace("\uE004", "<SP>"), "]");
    writeln();
}

unittest {
    show("verbatim 'aaaa bbbb cccc' w=5", wrapAnsi(verbatimMark ~ "aaaa bbbb cccc", 5));
    show("verbatim 'ab中cd' w=3", wrapAnsi(verbatimMark ~ "ab中cd", 3));
    show("verbatim '中ab' w=3", wrapAnsi(verbatimMark ~ "中ab", 3));
    show("verbatim 'ab中' w=4", wrapAnsi(verbatimMark ~ "ab中", 4));
    show("prose 'ab 中' w=4", wrapAnsi("ab 中", 4));
    show("prose 'a b 中' w=4", wrapAnsi("a b 中", 4));
    show("prose 'abc 中' w=4", wrapAnsi("abc 中", 4));
    show("verbatim '' w=5", wrapAnsi(verbatimMark, 5));
    show("verbatim ' ' w=5", wrapAnsi(verbatimMark ~ " ", 5));
    show("prose 'abcde f' w=5", wrapAnsi("abcde f", 5));
    show("prose 'a  b' w=3", wrapAnsi("a  b", 3));
    show("prose 'cmd 中 中' w=4", wrapAnsi("cmd 中 中", 4));
    show("verbatim 'abc中' w=4", wrapAnsi(verbatimMark ~ "abc中", 4));
    show("prose '中' w=1", wrapAnsi("中", 1));
    show("verbatim '中' w=1", wrapAnsi(verbatimMark ~ "中", 1));
    show("prose 'ab中 cd' w=3", wrapAnsi("ab中 cd", 3));
    show("prose 'ab中 cd' w=5", wrapAnsi("ab中 cd", 5));
    // joins/emitRows interactions
    show("prose 'the quick brown fox' w=9", wrapAnsi("the quick brown fox", 9));
}
