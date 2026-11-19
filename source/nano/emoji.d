/// GitHub-style emoji shortcodes (`:seedling:` → 🌱) for rendered markdown
/// prose (port of `markdown.rs` `expand_shortcodes`, Rust #181).
module nano.emoji;

import nano.emoji_table : emojiShortcodes;

@safe:

/// The emoji for a shortcode name (without colons), or null.
string emojiFor(string name) pure nothrow @nogc
{
    size_t lo = 0, hi = emojiShortcodes.length;
    while (lo < hi)
    {
        auto mid = (lo + hi) / 2;
        auto k = emojiShortcodes[mid][0];
        if (k == name) return emojiShortcodes[mid][1];
        if (k < name) lo = mid + 1;
        else hi = mid;
    }
    return null;
}

private bool nameChar(char c) pure nothrow @nogc
{
    return (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '+' || c == '-';
}

/// Replace `:name:` shortcodes with their emoji. Unknown names, and colons
/// that don't delimit a `[a-z0-9_+-]` name (times like `12:30:45`, `a::b`
/// paths), stay as written.
string expandShortcodes(string text) pure
{
    import std.array : appender;
    import std.string : indexOf;
    if (text.indexOf(':') < 0) return text;
    auto out_ = appender!string;
    auto rest = text;
    for (;;)
    {
        auto open = rest.indexOf(':');
        if (open < 0) break;
        out_ ~= rest[0 .. open];
        auto after = rest[open + 1 .. $];
        size_t n;
        while (n < after.length && nameChar(after[n])) ++n;
        if (n && n < after.length && after[n] == ':')
            if (auto e = emojiFor(after[0 .. n]))
            {
                out_ ~= e;
                rest = after[n + 1 .. $];
                continue;
            }
        // Not a shortcode: keep this colon and rescan from the next character,
        // so a non-match's closing colon can still open a real one.
        out_ ~= ':';
        rest = after;
    }
    out_ ~= rest;
    return out_[];
}

unittest
{
    import std.algorithm : isSorted;
    import std.algorithm : map;
    assert(emojiShortcodes.map!(p => p[0]).isSorted);
    assert(emojiFor("seedling") == "🌱" && emojiFor("+1") == "👍" && emojiFor("nope_xyz") is null);
    assert(expandShortcodes("Grow :seedling: now") == "Grow 🌱 now");
    assert(expandShortcodes("at 12:30:45 in a::b") == "at 12:30:45 in a::b");
    assert(expandShortcodes("v1:zz:seedling:") == "v1:zz🌱");
    assert(expandShortcodes("trailing:") == "trailing:");
}
