--------------------------- MODULE SessionRecovery ---------------------------
(***************************************************************************)
(* Crash recovery of the harness session log (src/session.rs) and the     *)
(* resume path of Agent::run_turn / Agent::load_session (src/agent.rs).    *)
(*                                                                         *)
(* The log is an append-only sequence of records. Only TurnEnd and Replace *)
(* records call sync_data, so:                                            *)
(*   - a process crash keeps every written record;                        *)
(*   - a power loss keeps a prefix that includes every synced record      *)
(*     (a torn final line is discarded on open, i.e. also a prefix).      *)
(* On restart the log is replayed (session::decode) and dangling tool     *)
(* calls get synthetic "interrupted" results (repair_dangling_tool_calls). *)
(* The client delivers inputs at least once, redelivering by input id.     *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Ids,            \* input ids the client submits
    MaxTools,       \* max tool calls in one model response
    MaxIter,        \* config.max_iterations
    MaxCrashes,
    MaxCancels,
    MaxCompactions,
    MaxErrors       \* model/provider errors (turn aborts, input stays pending)

ASSUME MaxIter >= 1 /\ MaxTools >= 1

\* Responses: 0 = "[turn cancelled]", 1 = max-iterations note, >= 2 = model answers.
CancelledResp == 0
MaxIterResp   == 1

\* A conversation message. `a` is the input id (user), the call count (tools),
\* the response (answer), or unused (result).
Msg(k, a) == [k |-> k, a |-> a]
User(i)   == Msg("user", i)
Summary   == Msg("user", "summary")

\* A log record. input: a = id. msg: a = message. end: a = id, b = response.
\* replace: a = messages, b = pending position (0 = none).
Rec(t, a, b) == [t |-> t, a |-> a, b |-> b]

NoPending == [id |-> "none", pos |-> 0]

VARIABLES
    log, synced,              \* durable state: records, synced prefix length
    alive,                    \* process is running
    conv, done, pend,         \* in-memory conversation, completed inputs, pending input
    pc, cur, iter, left, resp, cancel,
    acked,                    \* <<id, response>> pairs the client has received
    crashes, cancels, compactions, errors

vars == <<log, synced, alive, conv, done, pend, pc, cur, iter, left, resp,
          cancel, acked, crashes, cancels, compactions, errors>>

\* An input is only re-run after a crash or a provider error, so this
\* distinguishes every run's answer from any earlier run's.
Answer == 2 + crashes + errors

-----------------------------------------------------------------------------
(* session::decode *)

Step(st, r) ==
    CASE r.t = "input" ->
            [st EXCEPT !.pend = [id |-> r.a, pos |-> Len(st.conv) + 1]]
      [] r.t = "msg" ->
            [st EXCEPT !.conv = Append(@, r.a)]
      [] r.t = "end" ->
            [st EXCEPT !.done = @ \cup {<<r.a, r.b>>},
                       !.pend = IF @.id = r.a THEN NoPending ELSE @]
      [] r.t = "replace" ->
            [st EXCEPT !.conv = r.a,
                       !.pend = IF @ # NoPending /\ r.b # 0
                                THEN [id |-> @.id, pos |-> r.b] ELSE NoPending]

RECURSIVE Replay(_, _)
Replay(recs, st) ==
    IF recs = <<>> THEN st ELSE Replay(Tail(recs), Step(st, Head(recs)))

Decode(recs) == Replay(recs, [conv |-> <<>>, done |-> {}, pend |-> NoPending])

Response(d, i) == CHOOSE r \in {p[2] : p \in {q \in d : q[1] = i}} : TRUE
IsDone(d, i) == \E p \in d : p[1] = i

-----------------------------------------------------------------------------
(* repair_dangling_tool_calls *)

ToolsAt(c) == {j \in 1..Len(c) : c[j].k = "tools"}
Missing(c) ==
    IF ToolsAt(c) = {} THEN 0
    ELSE LET j == CHOOSE x \in ToolsAt(c) : \A y \in ToolsAt(c) : y <= x
             answered == Cardinality({l \in j + 1..Len(c) : c[l].k = "result"})
         IN IF c[j].a > answered THEN c[j].a - answered ELSE 0

RECURSIVE Results(_)
Results(n) == IF n = 0 THEN <<>> ELSE Append(Results(n - 1), Msg("result", 0))
RECURSIVE ResultRecs(_)
ResultRecs(n) == IF n = 0 THEN <<>> ELSE Append(ResultRecs(n - 1), Rec("msg", Msg("result", 0), 0))

-----------------------------------------------------------------------------

Init ==
    /\ log = <<>> /\ synced = 0 /\ alive = TRUE
    /\ conv = <<>> /\ done = {} /\ pend = NoPending
    /\ pc = "idle" /\ cur = "none" /\ iter = 0 /\ left = 0 /\ resp = 0
    /\ cancel = FALSE /\ acked = {}
    /\ crashes = 0 /\ cancels = 0 /\ compactions = 0 /\ errors = 0

\* Append records and update the in-memory conversation in one step: Agent::push
\* writes the log before the conversation, and nothing observes the gap.
Log(recs) == log' = log \o recs

\* run_turn entry for input `i`.
Deliver(i) ==
    /\ alive /\ pc = "idle"
    /\ IF IsDone(done, i)
       THEN \* Redelivered completed input: return the recorded response.
            /\ acked' = acked \cup {<<i, Response(done, i)>>}
            /\ UNCHANGED <<log, synced, conv, done, pend, pc, cur, iter, left, resp, cancel>>
       ELSE
            /\ cancel' = FALSE                    \* TurnControl::start_turn
            /\ cur' = i /\ iter' = 0 /\ left' = 0
            /\ UNCHANGED <<synced, done, acked>>
            /\ IF pend.id = i
               THEN \* Resuming the pending input.
                    IF pend.pos > Len(conv) \/ conv[pend.pos].k # "user"
                    THEN \* Input logged, user message not: re-add it.
                         /\ conv' = Append(SubSeq(conv, 1, pend.pos - 1), User(i))
                         /\ Log(<<Rec("msg", User(i), 0)>>)
                         /\ pc' = "loop" /\ UNCHANGED <<pend, resp>>
                    ELSE IF Len(conv) > pend.pos /\ conv[Len(conv)].k = "answer"
                    THEN \* Final answer recorded, turn end not: finish with it.
                         /\ resp' = conv[Len(conv)].a /\ pc' = "finish"
                         /\ UNCHANGED <<log, conv, pend>>
                    ELSE /\ pc' = "loop" /\ UNCHANGED <<log, conv, pend, resp>>
               ELSE \* A new input (any other pending input is abandoned).
                    /\ pend' = [id |-> i, pos |-> Len(conv) + 1]
                    /\ Log(<<Rec("input", i, 0)>>)
                    /\ pc' = "push_user"
                    /\ UNCHANGED <<conv, resp>>
    /\ UNCHANGED <<alive, crashes, cancels, compactions, errors>>

PushUser ==
    /\ alive /\ pc = "push_user"
    /\ conv' = Append(conv, User(cur)) /\ Log(<<Rec("msg", User(cur), 0)>>)
    /\ pc' = "loop"
    /\ UNCHANGED <<synced, alive, done, pend, cur, iter, left, resp, cancel, acked,
                   crashes, cancels, compactions, errors>>

\* Top of the iteration loop: cancelled, or out of iterations.
LoopEnd ==
    /\ alive /\ pc = "loop"
    /\ cancel \/ iter = MaxIter
    /\ resp' = IF cancel THEN CancelledResp ELSE MaxIterResp
    /\ pc' = "finish"
    /\ UNCHANGED <<log, synced, alive, conv, done, pend, cur, iter, left, cancel, acked,
                   crashes, cancels, compactions, errors>>

\* compact_with: summarize conv[1..split-1]; the kept tail starts at a user or
\* assistant message; a pending input folded into the summary is restated.
Compact ==
    /\ alive /\ (pc = "loop" \/ pc = "idle") /\ compactions < MaxCompactions
    /\ pc = "loop" => ~cancel
    /\ \E split \in {b \in 2..Len(conv) : conv[b].k # "result"} :
         LET head == IF pend # NoPending /\ pend.pos < split
                     THEN <<Summary, User(pend.id)>> ELSE <<Summary>>
             msgs == head \o SubSeq(conv, split, Len(conv))
             pp   == IF pend = NoPending THEN 0
                     ELSE IF pend.pos < split THEN 2
                     ELSE pend.pos - split + Len(head) + 1
         IN /\ conv' = msgs
            /\ pend' = IF pp = 0 THEN NoPending ELSE [id |-> pend.id, pos |-> pp]
            /\ Log(<<Rec("replace", msgs, pp)>>)
            /\ synced' = Len(log')
    /\ compactions' = compactions + 1
    /\ UNCHANGED <<alive, done, pc, cur, iter, left, resp, cancel, acked,
                   crashes, cancels, errors>>

\* One model call.
CallModel ==
    /\ alive /\ pc = "loop" /\ ~cancel /\ iter < MaxIter
    /\ iter' = iter + 1
    /\ \/ \* Final answer.
          /\ conv' = Append(conv, Msg("answer", Answer))
          /\ Log(<<Rec("msg", Msg("answer", Answer), 0)>>)
          /\ resp' = Answer
          /\ pc' = "finish" /\ UNCHANGED left
       \/ \* Tool calls.
          \E n \in 1..MaxTools :
            /\ conv' = Append(conv, Msg("tools", n))
            /\ Log(<<Rec("msg", Msg("tools", n), 0)>>)
            /\ left' = n /\ pc' = "tool"
            /\ UNCHANGED resp
    /\ UNCHANGED <<synced, alive, done, pend, cur, cancel, acked, crashes, cancels,
                   compactions, errors>>

\* The call was interrupted by cancel (tokio::select on control.cancelled()).
ModelCancelled ==
    /\ alive /\ pc = "loop" /\ cancel
    /\ resp' = CancelledResp /\ pc' = "finish"
    /\ UNCHANGED <<log, synced, alive, conv, done, pend, cur, iter, left, cancel, acked,
                   crashes, cancels, compactions, errors>>

\* Provider error: run_turn returns Err; the input stays pending, no TurnEnd.
\* The ACP reply is an error, not a completion, so it is not an ack.
ModelError ==
    /\ alive /\ pc = "loop" /\ ~cancel /\ errors < MaxErrors
    /\ pc' = "idle" /\ errors' = errors + 1
    /\ UNCHANGED <<log, synced, alive, conv, done, pend, cur, iter, left, resp, cancel,
                   acked, crashes, cancels, compactions>>

\* One tool result (a real one, or CANCELLED_TOOL_RESULT when cancelled).
ToolResult ==
    /\ alive /\ pc = "tool" /\ left > 0
    /\ conv' = Append(conv, Msg("result", 0)) /\ Log(<<Rec("msg", Msg("result", 0), 0)>>)
    /\ left' = left - 1
    /\ pc' = IF left = 1 THEN "loop" ELSE "tool"
    /\ UNCHANGED <<synced, alive, done, pend, cur, iter, resp, cancel, acked,
                   crashes, cancels, compactions, errors>>

\* finish_turn: TurnEnd is synced before the reply is sent.
Finish ==
    /\ alive /\ pc = "finish"
    /\ Log(<<Rec("end", cur, resp)>>) /\ synced' = Len(log')
    /\ done' = done \cup {<<cur, resp>>} /\ pend' = NoPending
    /\ acked' = acked \cup {<<cur, resp>>}
    /\ pc' = "idle"
    /\ UNCHANGED <<alive, conv, cur, iter, left, resp, cancel, crashes,
                   cancels, compactions, errors>>

Cancel ==
    /\ alive /\ pc \in {"push_user", "loop", "tool"} /\ ~cancel /\ cancels < MaxCancels
    /\ cancel' = TRUE /\ cancels' = cancels + 1
    /\ UNCHANGED <<log, synced, alive, conv, done, pend, pc, cur, iter, left, resp,
                   acked, crashes, compactions, errors>>

Crash ==
    /\ alive /\ crashes < MaxCrashes
    /\ alive' = FALSE /\ crashes' = crashes + 1
    /\ \E keep \in synced..Len(log) :            \* keep = Len(log): process crash
         /\ log' = SubSeq(log, 1, keep) /\ synced' = keep
    /\ UNCHANGED <<conv, done, pend, pc, cur, iter, left, resp, cancel, acked,
                   cancels, compactions, errors>>

\* Agent::load_session: replay, then repair dangling tool calls.
Restart ==
    /\ ~alive
    /\ LET st == Decode(log)
           n  == Missing(st.conv)
       IN /\ conv' = st.conv \o Results(n)
          /\ Log(ResultRecs(n))
          /\ done' = st.done /\ pend' = st.pend
    /\ alive' = TRUE /\ pc' = "idle" /\ cur' = "none" /\ cancel' = FALSE
    /\ UNCHANGED <<synced, iter, left, resp, acked, crashes, cancels,
                   compactions, errors>>

Next ==
    \/ \E i \in Ids : Deliver(i)
    \/ PushUser \/ LoopEnd \/ Compact \/ CallModel \/ ModelCancelled \/ ModelError
    \/ ToolResult \/ Finish \/ Cancel \/ Crash \/ Restart

\* The client keeps redelivering unacknowledged inputs; the harness keeps running.
Fairness ==
    /\ \A i \in Ids : WF_vars(Deliver(i) /\ ~\E p \in acked : p[1] = i)
    /\ WF_vars(PushUser) /\ WF_vars(LoopEnd) /\ WF_vars(CallModel)
    /\ WF_vars(ModelCancelled) /\ WF_vars(ToolResult) /\ WF_vars(Finish)
    /\ WF_vars(Restart)

Spec == Init /\ [][Next]_vars /\ Fairness

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ synced \in 0..Len(log)
    /\ alive \in BOOLEAN /\ cancel \in BOOLEAN
    /\ pc \in {"idle", "push_user", "loop", "tool", "finish"}
    /\ pend = NoPending \/ (pend.id \in Ids /\ pend.pos \in 1..Len(conv) + 1)

\* Replaying the log reproduces the in-memory state, so resume loses nothing
\* that was written.
LogFaithful ==
    alive => Decode(log) = [conv |-> conv, done |-> done, pend |-> pend]

\* Every tool call has exactly one result before anything else follows it.
WellFormed(c) ==
    \A j \in 1..Len(c) :
        /\ c[j].k = "tools" =>
              /\ j + c[j].a <= Len(c)
              /\ \A l \in j + 1..j + c[j].a : c[l].k = "result"
        /\ c[j].k = "result" =>
              \E t \in 1..j - 1 : c[t].k = "tools" /\ j - t <= c[t].a
                                  /\ \A l \in t + 1..j : c[l].k = "result"

\* The provider is only ever sent a well-formed conversation.
WellFormedAtModelCall == alive /\ pc = "loop" => WellFormed(conv)

\* During a turn the pending input points at its own user message.
PendingIsCurrent ==
    alive /\ pc \in {"loop", "tool", "finish"} =>
        pend.id = cur /\ pend.pos <= Len(conv) /\ conv[pend.pos] = User(cur)

\* An acknowledged response is durable: it survives any crash.
AcksDurable ==
    \A p \in acked : p \in Decode(SubSeq(log, 1, synced)).done

\* The client never sees two different responses for one input.
AcksConsistent == \A p, q \in acked : p[1] = q[1] => p[2] = q[2]

\* An input's turn ends at most once in the log.
SingleTurnEnd ==
    \A x, y \in 1..Len(log) :
        x # y /\ log[x].t = "end" /\ log[y].t = "end" => log[x].a # log[y].a

\* With finitely many crashes, cancels and errors, every input is answered.
AllAnswered == <>(\A i \in Ids : \E p \in acked : p[1] = i)
=============================================================================
