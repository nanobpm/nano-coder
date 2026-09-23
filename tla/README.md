# TLA+ specifications

Model-checked specifications of the harness's concurrency and crash-recovery
behaviour. Each spec follows the code closely enough that a change to the
modelled code should come with a change to the spec.

| Spec | Models | Properties |
|------|--------|------------|
| `AgentLoop.tla` (+ `MCAgentLoop.tla`) | One ACP session: `acp::run_acp`/`acp::run_turn` routing cancels, steers and other messages into a running `Agent::run_turn` | `AtMostOneReply`, `SendOrder`, `NoSteerAfterCancel`, `AllAnswered` (liveness) |
| `SessionRecovery.tla` | The JSONL session log (`session.rs`: only `TurnEnd`/`Replace` are synced, torn tails dropped), process crash and power loss, `load_session` replay + dangling-tool-call repair, compaction with a pending input, provider errors, cancel, and at-least-once redelivery by input id | `LogFaithful`, `WellFormedAtModelCall`, `PendingIsCurrent`, `AcksDurable`, `AcksConsistent`, `SingleTurnEnd`, `AllAnswered` (liveness) |

## Running

```sh
tla/check.sh          # AgentLoop + SessionRecovery (~1 min)
tla/check.sh --deep   # also SessionRecoveryDeep.cfg: two crashes (~2 min more)
```

The script needs Java and `tla2tools.jar` (set `TLA2TOOLS`, default
`~/bin/tla2tools.jar`; download it from the TLA+ releases page). To run one spec:
`java -cp tla2tools.jar tlc2.TLC -workers auto -config AgentLoop.cfg MCAgentLoop`.

## Findings

- **Leftover steers ran ahead of earlier deferred messages (fixed).** A steer
  that arrived too late to join the turn was pushed to the *front* of the
  deferred queue, so it ran before a slash command (or other message) the
  client had sent earlier. `acp::requeue_steers` now inserts each at its
  arrival position. `FixedLeftover = FALSE` in `AgentLoop.cfg` reproduces the
  old behaviour (`SendOrder` is violated).
- **An abandoned input is re-run from scratch (accepted).** The harness tracks
  one pending input. If input A is interrupted (crash or provider error) and a
  different input B is delivered before A is redelivered, A later runs again as
  a new input, repeating its tool calls. Completed inputs are still answered
  exactly once (`AcksConsistent`, `SingleTurnEnd`): delivery of an unfinished
  input is at-least-once.
- A cancel that races a final answer does not cancel the turn: the answer wins
  and the turn ends `end_turn`, so late steers then run as prompts.

## Checking the checks

Each property has been seen to fail against a deliberately broken model, e.g.
not syncing `TurnEnd` (`AcksDurable`), skipping dangling-call repair
(`WellFormedAtModelCall`), skipping completed-input dedup (`SingleTurnEnd`),
dropping the compaction pending position (`LogFaithful`), no restart fairness
(`AllAnswered`), dropping late steers on cancel without a reply
(`AllAnswered`), re-running absorbed steers (`AtMostOneReply`), and absorbing
steers after a cancel (`NoSteerAfterCancel`).
