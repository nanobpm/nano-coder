/// Output detail levels (ui.rs `Verbosity`) and the `/providers` listing
/// (turn_commands.rs `providers`, with settings.rs `key_status` and
/// `derived_endpoint_source`).
module nano.ui;

@safe:

import std.format : format;
import std.string : strip, toLower;
import nano.config : ProviderConfig, ProviderKind;

/// How much the terminal shows.
enum Verbosity { quiet, normal, verbose, debug_ }

immutable Verbosity[] allVerbosities = [Verbosity.quiet, Verbosity.normal, Verbosity.verbose, Verbosity.debug_];

string name(Verbosity v) pure nothrow
{
    final switch (v)
    {
        case Verbosity.quiet: return "quiet";
        case Verbosity.normal: return "normal";
        case Verbosity.verbose: return "verbose";
        case Verbosity.debug_: return "debug";
    }
}

string describe(Verbosity v) pure nothrow
{
    final switch (v)
    {
        case Verbosity.quiet: return "final answers only";
        case Verbosity.normal: return "streamed answers, collapsed thinking, tool calls";
        case Verbosity.verbose: return "normal + tool output previews";
        case Verbosity.debug_: return "verbose + lifecycle hook events";
    }
}

/// Parse a level (trimmed, any case), with Rust's error wording.
Verbosity parseVerbosity(string s)
{
    import nano.trajectory : serdeString;
    auto t = s.strip.toLower;
    foreach (v; allVerbosities)
        if (v.name == t) return v;
    throw new Exception(format("unknown verbosity %s (quiet, normal, verbose, debug)", serdeString(s)));
}

/// The bare `/verbosity` listing.
string verbosityListing(Verbosity current)
{
    auto out_ = format("Verbosity: %s (%s)", current.name, current.describe);
    foreach (v; allVerbosities) out_ ~= format("\n  %-8s %s", v.name, v.describe);
    return out_;
}

/// How a provider's key is found, for `/providers` and `/settings`.
/// `dataDir` overrides the credentials directory (tests).
string keyStatus(const ref ProviderConfig p, string dataDir = null) @trusted
{
    import std.process : environment;
    string envVar = p.apiKeyEnv.length ? p.apiKeyEnv : null;
    if (p.apiKey.length) return "key set";
    if (envVar !is null && environment.get(envVar, "").length) return "$" ~ envVar ~ " set";
    if (p.apiKeyCommand.length) return "key from `" ~ p.apiKeyCommand ~ "`";
    bool stored;
    string login;
    if (p.hasKind && p.kind == ProviderKind.githubCopilot)
    {
        import copilot = nano.copilot;
        copilot.StoredCredentials c;
        stored = copilot.loadCredentials(c, dataDir);
        login = "--login github-copilot";
    }
    else if (p.hasKind && p.kind == ProviderKind.muse)
    {
        import muse = nano.muse;
        muse.StoredCredentials c;
        stored = muse.loadCredentials(c, dataDir);
        login = "--login muse";
    }
    if (stored) return "logged in (unofficial)";
    if (envVar !is null) return login !is null ? format("$%s missing; %s", envVar, login) : format("$%s missing", envVar);
    return login !is null ? "not logged in; " ~ login : "no key";
}

/// Where a provider with no `base_url` gets its endpoint.
string derivedEndpointSource(const ref ProviderConfig p) @trusted
{
    import std.process : environment;
    if (p.hasKind && p.kind == ProviderKind.githubCopilot) return "(from session token)";
    if (p.hasKind && p.kind == ProviderKind.muse)
    {
        bool direct = p.apiKey.length || p.apiKeyCommand.length
            || (p.apiKeyEnv.length && environment.get(p.apiKeyEnv, "").length);
        return direct ? "(from API key)" : "(from minted key)";
    }
    return "-";
}

/// Rust prints the kind with `{:?}` lowercased (`GithubCopilot` → `githubcopilot`).
private string kindLabel(const ref ProviderConfig p)
{
    if (!p.hasKind) return "?";
    final switch (p.kind)
    {
        case ProviderKind.openai: return "openai";
        case ProviderKind.anthropic: return "anthropic";
        case ProviderKind.githubCopilot: return "githubcopilot";
        case ProviderKind.muse: return "muse";
        case ProviderKind.mock: return "mock";
    }
}

/// `/providers`: every effective provider in name order.
string providersListing(const ProviderConfig[string] providers, string defaultProvider, string dataDir = null) @trusted
{
    import std.algorithm : sort;
    auto names = providers.keys;
    names.sort();
    auto out_ = format("Providers (default: %s):", defaultProvider);
    foreach (n; names)
    {
        auto p = &providers[n];
        auto url = p.baseUrl.length ? p.baseUrl : derivedEndpointSource(*p);
        out_ ~= format("\n  %-14s %-14s %-55s %s", n, kindLabel(*p), url, keyStatus(*p, dataDir));
    }
    return out_;
}

unittest
{
    import std.exception : collectExceptionMsg;
    import std.algorithm : canFind;
    assert(parseVerbosity(" Quiet ") == Verbosity.quiet && parseVerbosity("debug") == Verbosity.debug_);
    assert(collectExceptionMsg(parseVerbosity("loud")) == `unknown verbosity "loud" (quiet, normal, verbose, debug)`);
    assert(verbosityListing(Verbosity.normal) == "Verbosity: normal (streamed answers, collapsed thinking, tool calls)\n"
        ~ "  quiet    final answers only\n  normal   streamed answers, collapsed thinking, tool calls\n"
        ~ "  verbose  normal + tool output previews\n  debug    verbose + lifecycle hook events");

    import std.file : tempDir, mkdirRecurse, rmdirRecurse;
    import std.path : buildPath;
    auto dir = buildPath(tempDir, "nano-ui-test");
    mkdirRecurse(dir);
    scope (exit) rmdirRecurse(dir);
    ProviderConfig a;
    a.apiKey = "k";
    assert(keyStatus(a, dir) == "key set");
    ProviderConfig b;
    b.apiKeyEnv = "NANO_UI_TEST_UNSET_VAR";
    assert(keyStatus(b, dir) == "$NANO_UI_TEST_UNSET_VAR missing");
    b.apiKeyCommand = "pass x";
    assert(keyStatus(b, dir) == "key from `pass x`");
    ProviderConfig c;
    c.hasKind = true;
    c.kind = ProviderKind.githubCopilot;
    assert(keyStatus(c, dir) == "not logged in; --login github-copilot");
    c.apiKeyEnv = "NANO_UI_TEST_UNSET_VAR";
    assert(keyStatus(c, dir) == "$NANO_UI_TEST_UNSET_VAR missing; --login github-copilot");
    assert(derivedEndpointSource(c) == "(from session token)");
    ProviderConfig m;
    m.hasKind = true;
    m.kind = ProviderKind.muse;
    assert(derivedEndpointSource(m) == "(from minted key)");
    m.apiKey = "x";
    assert(derivedEndpointSource(m) == "(from API key)");
    ProviderConfig o;
    o.hasKind = true;
    o.kind = ProviderKind.openai;
    o.baseUrl = "http://localhost:11434/v1";
    ProviderConfig[string] ps = ["ollama": o, "copilot": c];
    auto listing = providersListing(ps, "ollama", dir);
    assert(listing.canFind("Providers (default: ollama):\n  copilot        githubcopilot  (from session token)"));
    assert(listing.canFind("\n  ollama         openai         http://localhost:11434/v1"));
}
