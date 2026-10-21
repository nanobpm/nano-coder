/// Memory guards, split out of memory.rs: secret detection (memories are
/// human-readable and shared across sessions, so obvious credentials are
/// refused) and git-remote normalisation for the project key (credentials are
/// stripped from the URL before it names a file).
module nano.memsecret;

import std.algorithm : all, any, canFind, filter, map, endsWith, startsWith;
import std.array : array, join, split;
import std.ascii : isAlphaNum, isAlpha, isDigit, toLower;
import std.regex : regex, matchFirst, matchAll, Regex;
import std.string : indexOf, lastIndexOf, strip, toLower;
import std.conv : to;

private Regex!char re(string pattern)
{
    auto flags = "";
    if (pattern.startsWith("(?i)")) { pattern = pattern[4 .. $]; flags = "i"; }
    return regex(pattern, flags);
}

private string trimQuotes(string s, string set)
{
    while (s.length && set.canFind(s[0])) s = s[1 .. $];
    while (s.length && set.canFind(s[$ - 1])) s = s[0 .. $ - 1];
    return s;
}

/// Why `text` looks like it contains a secret, or null.
string looksLikeSecret(string text)
{
    if (text.canFind("PRIVATE KEY-----") || text.canFind("BEGIN OPENSSH PRIVATE KEY")) return "private key block";
    static immutable string[2][] patterns = [
        [`\b(gh[pousr])_[A-Za-z0-9]{20,}`, "GitHub token"],
        [`\bgithub_pat_[A-Za-z0-9_]{20,}`, "GitHub PAT"],
        [`\bglpat-[A-Za-z0-9_-]{20,}`, "GitLab access token"],
        [`\bAKIA[0-9A-Z]{16}\b`, "AWS access key id"],
        [`\bxox[baprs]-[A-Za-z0-9-]{10,}`, "Slack token"],
        [`\bsk-[A-Za-z0-9]{20,}`, "API secret key"],
        [`\bsk-[A-Za-z0-9]+-[A-Za-z0-9-]{20,}`, "API secret key"],
        [`\bAIza[0-9A-Za-z_\-]{35}\b`, "Google API key"],
        [`\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}`, "JWT"],
        [`[A-Za-z][A-Za-z0-9+.-]*://[^\s/:]*:[^\s/@]+@`, "credential in URL authority"],
    ];
    foreach (p; patterns)
        if (!matchFirst(text, re(p[0])).empty) return p[1];
    foreach (c; matchAll(text, re(`(?i)\bauthorization\s*:\s*(?:bearer|basic)\s+(\S+)`)))
        if (!isPlaceholder(c[1])) return "authorization header value";
    enum labels = `(?:secret|password|passwd|token|credential|api[_ -]?key|access[_ -]?key|private[_ -]?key|client[_ -]?secret)`;
    foreach (c; matchAll(text, re(`(?i)(?:^|[^A-Za-z0-9])` ~ labels ~ `s?["']?\s*[:=]\s*["']?(\S+)`)))
        if (!isPlaceholder(trimQuotes(c[1], `"'`))) return "credential assignment";
    foreach (c; matchAll(text, re(`(?i)(?:^|[^A-Za-z0-9])(?:pass|pwd)\w*["']?\s*[:=]\s*["']?(\S+)`)))
        if (!isPlaceholder(trimQuotes(c[1], `"'`))) return "credential assignment";
    foreach (c; matchAll(text, re(`(?i)(?:^|[^A-Za-z0-9])` ~ labels ~ `s?\s+(?:is|was|are|be)\s+["']?(.+)`)))
        if (copularValueIsSecret(c[1])) return "credential statement";
    foreach (c; matchAll(text, re(`(?i)(?:^|[^A-Za-z0-9])(?:pass|pwd|passphrase)\w*\s+(?:is|was|are|be)\s+["']?(.+)`)))
        if (copularValueIsSecret(c[1])) return "credential statement";
    return null;
}

/// After `<label> is`: a value stated outright is a secret; a location
/// (`stored in the vault`) is not, unless a secret-shaped word or an `as <value>`
/// connective follows it.
private bool copularValueIsSecret(string rest)
{
    static immutable fillers = ["the", "a", "an", "your", "my", "our", "their", "his", "her", "its"];
    static immutable location = ["stored", "in", "at", "kept", "lives", "set", "saved", "located", "found", "defined",
        "configured", "managed", "read", "loaded", "fetched", "from", "under", "inside", "within", "into", "to", "on", "via"];
    bool inLocation;
    foreach (word; rest.split)
    {
        auto w = trimQuotes(word, `"',.;:`);
        if (!w.length) continue;
        auto lower = w.toLower;
        if (["as", "=", "equals", "equal"].canFind(lower)) { inLocation = false; continue; }
        if (fillers.canFind(lower)) continue;
        if (location.canFind(lower)) { inLocation = true; continue; }
        bool flagged = isPlaceholder(w) ? false : inLocation ? (isSecretShaped(w) && !isSecretStoreNoun(lower)) : true;
        if (flagged) return true;
        if (!inLocation) return false;
    }
    return false;
}

private bool isSecretShaped(string value)
{
    auto v = trimQuotes(value, `"',.;:`);
    return v.length >= 6 && v.any!(c => c >= '0' && c <= '9');
}

private bool isSecretStoreNoun(string lower)
{
    return ["1password", "onepassword", "route53", "keepassxc"].canFind(lower);
}

private bool endsWithCredentialLabel(string text)
{
    auto normalised = text.toLower.map!(c => c == '_' || c == '-' ? ' ' : c).to!string;
    auto words = normalised.split;
    if (words.length >= 2 && ["api key", "access key", "private key", "client secret"].canFind(words[$ - 2] ~ " " ~ words[$ - 1]))
        return true;
    if (words.length)
    {
        auto w = words[$ - 1].filter!(c => c < 0x80 && isAlphaNum(cast(char) c)).to!string;
        if (["secret", "password", "passwd", "token", "credential", "credentials", "pass", "pwd", "passphrase"].canFind(w))
            return true;
    }
    return false;
}

/// `text` ends with a credential label and `evidence` is that label's value.
bool evidenceStatesLabelValue(string text, string evidence)
{
    if (!endsWithCredentialLabel(text)) return false;
    auto first = evidence.split;
    auto fw = first.length ? trimQuotes(first[0], `"',.;:`).toLower : "";
    if (fw.length && isSecretStoreNoun(fw)) return false;
    return looksLikeSecret(text ~ " is " ~ evidence) !is null;
}

private bool isPlaceholder(string value)
{
    if (value.length >= 2 && value[0] == '<' && value[$ - 1] == '>')
    {
        auto inner = value[1 .. $ - 1];
        if (!inner.canFind('<') && !inner.canFind('>') && isPlaceholderFiller(inner)) return true;
    }
    if (value.startsWith("$"))
    {
        auto rest = value[1 .. $];
        if (rest.startsWith("{") && rest.endsWith("}") && rest.length >= 2) return isShellVarName(rest[1 .. $ - 1]);
        return isShellVarName(rest);
    }
    return isPlaceholderFiller(value);
}

private bool isShellVarName(string name)
{
    if (!name.length || !(isAlpha(name[0]) || name[0] == '_')) return false;
    return name.all!(c => c < 0x80 && (isAlphaNum(cast(char) c) || c == '_'));
}

private bool isMask(string s)
{
    import std.utf : byDchar;
    return s.byDchar.all!(c => c == 'x' || c == 'X' || c == '*' || c == '•');
}

private bool isPlaceholderFiller(string value)
{
    size_t a = 0, b = value.length;
    while (a < b && !(value[a] < 0x80 && isAlphaNum(value[a]))) a++;
    while (b > a && !(value[b - 1] < 0x80 && isAlphaNum(value[b - 1]))) b--;
    auto trimmed = value[a .. b];
    if (!trimmed.length)
    {
        auto masked = value.strip;
        return !masked.length || isMask(masked);
    }
    auto lower = trimmed.toLower;
    if (["none", "null", "nil", "todo", "tbd", "changeme", "change_me", "redacted", "placeholder", "example"].canFind(lower)
            || isMask(value.strip))
        return true;
    static immutable filler = ["your", "my", "our", "some", "the", "a", "an", "example", "sample", "placeholder",
        "dummy", "fake", "token", "secret", "key", "keys", "password", "passwd", "apikey", "api", "access", "private",
        "client", "value", "val", "here", "goes", "change", "changeme", "me", "redacted", "todo", "tbd", "foo", "bar"];
    auto segs = lower.split!(c => c == '-' || c == '_').filter!(s => s.length).array;
    return segs.length > 1 && segs.all!(s => filler.canFind(s));
}

// ---- remote normalisation ----

private bool dosDrivePrefix(string s)
{
    return s.length >= 2 && isAlpha(s[0]) && s[1] == ':';
}

private bool scpAuthority(string s)
{
    auto colon = s.indexOf(':');
    if (colon < 0) return false;
    auto auth = s[0 .. colon];
    return !auth.any!(c => c == '/' || c == '?' || c == '#' || c == ' ' || c == '\t' || c == '\n' || c == '\r');
}

/// A relative local path remote (`../repo.git`), as opposed to a URI, SCP or absolute path.
bool isRelativeLocalPath(string url)
{
    if (url.startsWith("/")) return false;
    if (!matchFirst(url, re(`^[A-Za-z][A-Za-z0-9+.-]*://`)).empty) return false;
    if (scpAuthority(url)) return false;
    return true;
}

private string stripUriPassword(string scheme, string authority)
{
    auto at = authority.lastIndexOf('@');
    if (at < 0) return authority;
    auto userinfo = authority[0 .. at], host = authority[at + 1 .. $];
    if (scheme == "http" || scheme == "https") return host;
    auto colon = userinfo.indexOf(':');
    auto user = colon >= 0 ? userinfo[0 .. colon] : userinfo;
    if (!user.length || looksLikeSecret(percentDecodeLossy(user)) !is null) return host;
    return user ~ "@" ~ host;
}

private string sanitizeUriQuery(string query)
{
    string[] kept;
    foreach (param; query.split('&'))
    {
        if (!param.length) continue;
        auto eq = param.indexOf('=');
        auto key = eq >= 0 ? param[0 .. eq] : param;
        if (isCredentialQueryKey(percentDecodeLossy(key))) continue;
        auto ok = eq >= 0 ? looksLikeSecret(percentDecodeLossy(param[eq + 1 .. $])) is null : looksLikeSecret(param) is null;
        if (ok) kept ~= param;
    }
    return kept.join("&");
}

private string percentDecodeLossy(string s)
{
    import nano.tools : lossyUtf8;
    ubyte[] out_;
    for (size_t i = 0; i < s.length;)
    {
        if (s[i] == '%' && i + 2 < s.length)
        {
            int hex(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }
            auto hi = hex(s[i + 1]), lo = hex(s[i + 2]);
            if (hi >= 0 && lo >= 0) { out_ ~= cast(ubyte)(hi * 16 + lo); i += 3; continue; }
        }
        out_ ~= cast(ubyte) s[i++];
    }
    return lossyUtf8(out_);
}

private bool isCredentialQueryKey(string key)
{
    static immutable substr = ["password", "passwd", "pwd", "apikey", "accesskey", "privatekey", "credential", "signature", "oauth"];
    static immutable affix = ["token", "secret", "auth"];
    static immutable whole = ["auth", "authorization", "authz", "token", "secret"];
    static immutable short_ = ["key", "sig", "pat", "sso", "pass", "passphrase"];
    auto k = key.filter!(c => c < 0x80 && isAlphaNum(cast(char) c)).to!string.toLower;
    if (substr.any!(n => k.canFind(n))) return true;
    if (short_.canFind(k)) return true;
    foreach (segment; key.toLower.split!(c => c == '-' || c == '_' || c == '.'))
    {
        if (!segment.length) continue;
        auto seg = segment.filter!(c => c < 0x80 && isAlphaNum(cast(char) c)).to!string;
        if (whole.canFind(seg) || short_.canFind(seg)) return true;
        foreach (n; affix)
        {
            if (seg == n || seg == n ~ "s") return true;
            bool joined(string rest) { return rest.length && (affix.canFind(rest) || short_.canFind(rest) || substr.canFind(rest)); }
            if ((seg.startsWith(n) && joined(seg[n.length .. $])) || (seg.endsWith(n) && joined(seg[0 .. $ - n.length])))
                return true;
        }
    }
    return false;
}

/// A stable project key from a git remote: scheme lowercased, credentials,
/// fragments and credential query params dropped, SCP `host:path` as `host/path`.
string normalizeRemote(string url)
{
    auto s = url.strip;
    string scheme;
    auto m = matchFirst(s, re(`^([A-Za-z][A-Za-z0-9+.-]*)://`));
    bool uri = !m.empty;
    if (uri) { scheme = m[1].toLower; s = s[m[0].length .. $]; }
    bool scp = !uri && !dosDrivePrefix(s) && scpAuthority(s);
    if (uri)
    {
        auto hash = s.indexOf('#');
        auto noFrag = hash >= 0 ? s[0 .. hash] : s;
        auto q = noFrag.indexOf('?');
        if (q >= 0)
        {
            auto sanitized = sanitizeUriQuery(noFrag[q + 1 .. $]);
            s = sanitized.length ? noFrag[0 .. q] ~ "?" ~ sanitized : noFrag[0 .. q];
        }
        else s = noFrag;
    }
    if (scp)
    {
        auto colon = s.indexOf(':');
        s = stripUriPassword(null, s[0 .. colon]) ~ "/" ~ s[colon + 1 .. $];
    }
    else if (uri)
    {
        size_t at = s.length;
        foreach (i, c; s) if (c == '/' || c == '?') { at = i; break; }
        s = stripUriPassword(scheme, s[0 .. at]) ~ s[at .. $];
    }
    while (s.endsWith("/")) s = s[0 .. $ - 1];
    return scheme.length ? scheme ~ "://" ~ s : s;
}
