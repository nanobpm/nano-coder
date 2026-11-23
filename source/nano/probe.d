/// Capability-probe state with generations (port of `agent/probe.rs`).
///
/// The endpoint reports what the current model supports (`Capabilities`):
/// its context window, thinking levels, vision and output-token limit. A
/// blocking probe runs at startup and on a direct `/model`; a mid-turn switch
/// probes on a background thread whose result is published when it lands.
///
/// Invariant owned here: a probe result is published only if no model change
/// has happened since the probe started. Every change goes through
/// `beginDetect`, which bumps the generation and clears every report;
/// `publishIfCurrent` drops a result from an older generation, so a slow
/// probe for a superseded model never overwrites the current model's reports.
///
/// The state lives on the agent's thread: background probes hand their
/// results back through a `Join`, and the agent publishes them here.
module nano.probe;
@safe:

import nano.llm : Capabilities;

struct ProbeState
{
    /// What the endpoint reported for the current model.
    Capabilities caps;
    /// Monotonic model-change counter; a probe captures the generation it
    /// started under and is discarded once a later change bumps it.
    private ulong generation;
    /// The newest generation a probe is wanted for. A switch that finds a
    /// probe still running records its generation here without starting a
    /// second thread; the running probe adopts it when it finishes, so rapid
    /// switches cost one probe thread, not one per switch (nano-coder#270).
    /// `ulong.max` is "no want recorded": generations count up from 1.
    private ulong wanted_ = ulong.max;

    /// Invalidate any in-flight probe and clear every report (the previous
    /// model's reports must not leak onto the new one). Returns the new
    /// generation, which a probe started now publishes under.
    ulong beginDetect() pure
    {
        ++generation;
        caps = Capabilities.init;
        return generation;
    }

    /// Whether `g` is still the live generation.
    bool isCurrent(ulong g) pure const { return generation == g; }

    /// Record that the newest generation wants a probe even though one is
    /// still running (see `wanted_`).
    void wantNewest() pure { wanted_ = generation; }

    /// The generation a probe that finishes now should run for next: the
    /// recorded want, or the live generation when nothing was recorded.
    ulong newestWanted() pure { return wanted_ == ulong.max ? generation : wanted_; }

    /// Whether a switch recorded a want while a probe was still running (so
    /// its finisher must start that probe). The want is cleared here: a
    /// finisher that takes it owns starting the probe.
    bool takeWant() pure
    {
        if (wanted_ == ulong.max) return false;
        wanted_ = ulong.max;
        return true;
    }

    /// Publish a blocking probe's result: every report is replaced.
    void store(Capabilities c) pure { caps = c; }

    /// Publish a configured-window probe (thinking, vision and output limit
    /// only), leaving the window slot untouched.
    void storeWithoutWindow(Capabilities c) pure
    {
        caps.thinking = c.thinking;
        caps.vision = c.vision;
        caps.maxOutput = c.maxOutput;
    }

    /// Publish a background probe's result if `g` is still current: thinking,
    /// vision and output limit land together, and the window slot is written
    /// only when the probe found a window. False when the result was stale
    /// and discarded. `window = false` (a configured context window) never
    /// publishes window metadata, even if a shared response carried some.
    bool publishIfCurrent(ulong g, Capabilities c, bool window = true) pure
    {
        if (!isCurrent(g)) return false;
        storeWithoutWindow(c);
        if (window && c.window)
        {
            caps.window = c.window;
            caps.windowSource = c.windowSource;
            caps.promptCap = c.promptCap;
            caps.totalWindow = c.totalWindow;
        }
        return true;
    }
}

private Capabilities windowOnly(size_t tokens, string source) pure
{
    Capabilities c;
    c.window = tokens;
    c.windowSource = source;
    return c;
}

// A switch that finds a probe still running records its want instead of
// starting a second thread; the finisher adopts the newest wanted generation.
unittest
{
    ProbeState probe;
    auto first = probe.beginDetect();
    probe.wantNewest();
    auto second = probe.beginDetect();
    probe.wantNewest();
    assert(probe.newestWanted == second);
    assert(!probe.isCurrent(first) && probe.isCurrent(second));
    // A recorded want is taken once: the finisher owns starting its probe.
    assert(probe.takeWant() && !probe.takeWant());
    // No recorded want: the live generation is what a finisher should probe.
    ProbeState idle;
    auto g = idle.beginDetect();
    assert(idle.newestWanted == g && !idle.takeWant());
}

// rust: agent/probe.rs::a_stale_generation_publishes_nothing
unittest
{
    ProbeState probe;
    auto stale = probe.beginDetect();
    auto live = probe.beginDetect();
    assert(!probe.publishIfCurrent(stale, windowOnly(1, "stale")));
    assert(probe.caps.window == 0);
    assert(probe.publishIfCurrent(live, windowOnly(2, "live")));
    assert(probe.caps.window == 2 && probe.caps.windowSource == "live");
}

// rust: agent/probe.rs::begin_detect_clears_every_report_and_invalidates_in_flight_probes
unittest
{
    ProbeState probe;
    auto g = probe.beginDetect();
    auto c = windowOnly(3, "x");
    c.maxOutput = 7;
    probe.store(c);
    auto next = probe.beginDetect();
    assert(!probe.isCurrent(g) && probe.isCurrent(next));
    assert(probe.caps.window == 0 && probe.caps.maxOutput == 0);
}

// rust: agent/probe.rs::a_windowless_result_keeps_the_window_slot_but_publishes_the_rest
unittest
{
    ProbeState probe;
    auto g = probe.beginDetect();
    probe.caps.window = 5;
    probe.caps.windowSource = "earlier";
    Capabilities c;
    c.maxOutput = 9;
    assert(probe.publishIfCurrent(g, c));
    assert(probe.caps.window == 5 && probe.caps.windowSource == "earlier");
    assert(probe.caps.maxOutput == 9);
}

// A configured context window: a background result's window metadata is ignored.
unittest
{
    ProbeState probe;
    auto g = probe.beginDetect();
    auto c = windowOnly(4, "props");
    c.maxOutput = 11;
    assert(probe.publishIfCurrent(g, c, false));
    assert(probe.caps.window == 0 && probe.caps.windowSource == "");
    assert(probe.caps.maxOutput == 11);
}
