/// The status line's view of the agent (the REPL refreshes it after each
/// step and between turns).
module nano.agent_status;
@safe:

import nano.agent : Agent;
import nano.status : Stats;

/// Copy the agent's live state into the status line's stats.
void statusFromAgent(ref Stats s, Agent agent, string cwdShown)
{
    import nano.context : CompactionMode;
    s.provider = agent.client.providerName;
    s.model = agent.client.modelName;
    s.cwd = cwdShown;
    bool calibrated;
    s.tokens = agent.estimateContextTokens(calibrated);
    s.calibrated = calibrated;
    string source;
    s.window = agent.contextWindow(source);
    s.messages = agent.messages.length;
    auto progress = agent.plan.progress;
    s.hasPlan = progress[1] > 0;
    s.planDone = progress[0];
    s.planTotal = progress[1];
    s.timers = agent.timers.items.length;
    s.nextTimer = s.timers ? imported!"nano.timers".clock(agent.timers.nextDue) : null;
    s.mode = agent.control.mode;
    s.thinking = agent.shownThinking;
    s.sessionInputTokens = agent.sessionInputTokens;
    s.sessionOutputTokens = agent.sessionOutputTokens;
    s.hasAic = agent.hasSessionAic;
    s.aic = agent.sessionAic;
    s.autoCompact = agent.autoCompact;
    s.threshold = agent.effectiveAutoCompactThreshold;
    s.smartCompact = agent.compactionMode == CompactionMode.smart;
    s.compactions = agent.compactions;
}
