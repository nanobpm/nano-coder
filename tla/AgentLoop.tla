------------------------------ MODULE AgentLoop ------------------------------
(***************************************************************************)
(* One ACP session: acp::run_acp / acp::run_turn routing messages to a     *)
(* running Agent::run_turn (src/acp.rs, src/agent.rs).                      *)
(*                                                                         *)
(* The client sends a script of messages in order. While idle, the agent   *)
(* takes the next deferred message, else the next received one: a text    *)
(* prompt starts a turn, a slash command runs at once. While a turn runs,  *)
(* incoming messages are routed only when the turn is suspended at an      *)
(* await (the model call or a tool): cancel sets the flag, a text prompt  *)
(* becomes a steer, anything else is deferred until the turn ends. The    *)
(* turn's first poll resets the control (biased select), so starting a     *)
(* turn and routing never interleave.                                      *)
(*                                                                         *)
(* At the end of a turn the prompt and every absorbed steer are answered   *)
(* with the turn's stop reason; steers too late to join are answered       *)
(* "cancelled" if the turn was cancelled, otherwise they run next as       *)
(* ordinary prompts.                                                       *)
(***************************************************************************)
EXTENDS Naturals, Sequences, FiniteSets

CONSTANTS
    Script,        \* sequence of [id, kind], kind \in {"text", "cmd", "cancel"}
    MaxIter,       \* config.max_iterations
    MaxTools,      \* tool calls per model response
    FixedLeftover  \* TRUE: leftover steers keep their arrival position

ASSUME MaxIter >= 1 /\ MaxTools >= 1 /\ FixedLeftover \in BOOLEAN

N == Len(Script)
Kind(m) == Script[m].kind
Requests == {m \in 1..N : Kind(m) # "cancel"}   \* messages that get a reply

VARIABLES
    sent,       \* script messages sent so far
    rx,         \* received, not yet read (message indices)
    deferred,   \* messages to handle after the current turn
    mode,       \* "idle" | "turn"
    tpc,        \* turn at an await: "call" (model) | "tool"
    current,    \* message that started the turn
    cancel,     \* TurnControl cancel flag
    steers,     \* TurnControl pending steers, arrival order
    marks,      \* per pending steer: Len(deferred) when it arrived
    absorbed,   \* steers folded into the turn
    iter, left,
    replies,    \* replies[m]: replies sent for message m
    order       \* messages run as a turn or command, in execution order

vars == <<sent, rx, deferred, mode, tpc, current, cancel, steers, marks, absorbed,
          iter, left, replies, order>>

Init ==
    /\ sent = 0 /\ rx = <<>> /\ deferred = <<>>
    /\ mode = "idle" /\ tpc = "call" /\ current = 0
    /\ cancel = FALSE /\ steers = <<>> /\ marks = <<>> /\ absorbed = <<>>
    /\ iter = 0 /\ left = 0
    /\ replies = [m \in 1..N |-> 0] /\ order = <<>>

Send ==
    /\ sent < N
    /\ sent' = sent + 1 /\ rx' = Append(rx, sent + 1)
    /\ UNCHANGED <<deferred, mode, tpc, current, cancel, steers, marks, absorbed,
                   iter, left, replies, order>>

Range(s) == {s[i] : i \in 1..Len(s)}
Reply(r, ms) == [m \in 1..N |-> IF m \in ms THEN r[m] + 1 ELSE r[m]]

\* Insert s[k] before position marks[k] of d (marks are nondecreasing), last first.
RECURSIVE InsertAt(_, _, _)
InsertAt(d, s, mk) ==
    IF s = <<>> THEN d
    ELSE LET k == Len(s) IN
         InsertAt(SubSeq(d, 1, mk[k]) \o <<s[k]>> \o SubSeq(d, mk[k] + 1, Len(d)),
                  SubSeq(s, 1, k - 1), SubSeq(mk, 1, k - 1))

\* End of acp::run_turn. `stop` \in {"end_turn", "cancelled", "max_turn_requests"}.
EndTurn(stop) ==
    /\ mode' = "idle"
    /\ replies' = Reply(replies, {current} \cup Range(absorbed)
                                 \cup (IF stop = "cancelled" THEN Range(steers) ELSE {}))
    /\ deferred' = IF stop = "cancelled" THEN deferred
                   ELSE IF FixedLeftover THEN InsertAt(deferred, steers, marks)
                   ELSE steers \o deferred
    /\ steers' = <<>> /\ marks' = <<>> /\ absorbed' = <<>>

\* Top of an iteration of Agent::run_turn: stop, or absorb steers and call the model.
\* `st` and `ab` are the steers/absorbed values on entry.
LoopTop(it, st, ab) ==
    IF it = MaxIter \/ cancel
    THEN /\ steers = st /\ absorbed = ab   \* (the caller has not changed them)
         /\ EndTurn(IF cancel THEN "cancelled" ELSE "max_turn_requests")
         /\ UNCHANGED tpc
    ELSE /\ absorbed' = ab \o st /\ steers' = <<>> /\ marks' = <<>>
         /\ tpc' = "call" /\ mode' = "turn"
         /\ UNCHANGED <<deferred, replies>>

\* Idle: take the next message.
Take ==
    /\ mode = "idle"
    /\ deferred # <<>> \/ rx # <<>>
    /\ LET fromDeferred == deferred # <<>>
           m == IF fromDeferred THEN Head(deferred) ELSE Head(rx)
       IN /\ deferred' = IF fromDeferred THEN Tail(deferred) ELSE deferred
          /\ rx' = IF fromDeferred THEN rx ELSE Tail(rx)
          /\ CASE Kind(m) = "text" ->
                    \* start_turn, push the user message, first loop top.
                    /\ mode' = "turn" /\ tpc' = "call" /\ current' = m
                    /\ cancel' = FALSE /\ iter' = 0 /\ left' = 0
                    /\ order' = Append(order, m)
                    /\ UNCHANGED <<replies, steers, marks, absorbed>>
               [] Kind(m) = "cmd" ->
                    /\ replies' = Reply(replies, {m}) /\ order' = Append(order, m)
                    /\ UNCHANGED <<mode, tpc, current, cancel, iter, left, steers, marks, absorbed>>
               [] Kind(m) = "cancel" ->   \* nothing running: ignored
                    UNCHANGED <<mode, tpc, current, cancel, iter, left, replies, order,
                                steers, marks, absorbed>>
    /\ UNCHANGED sent

\* The turn is suspended at an await: the select routes one received message.
Route ==
    /\ mode = "turn" /\ rx # <<>>
    /\ LET m == Head(rx) IN
       /\ rx' = Tail(rx)
       /\ CASE Kind(m) = "cancel" ->
                 /\ cancel' = TRUE /\ UNCHANGED <<deferred, steers, marks>>
            [] Kind(m) = "text" ->
                 /\ steers' = Append(steers, m) /\ marks' = Append(marks, Len(deferred))
                 /\ UNCHANGED <<deferred, cancel>>
            [] Kind(m) = "cmd" ->
                 /\ deferred' = Append(deferred, m) /\ UNCHANGED <<cancel, steers, marks>>
    /\ UNCHANGED <<sent, mode, tpc, current, absorbed, iter, left, replies, order>>

\* The model call resolves. With cancel set the select may take either branch.
ModelCancelled ==
    /\ mode = "turn" /\ tpc = "call" /\ cancel
    /\ EndTurn("cancelled")
    /\ UNCHANGED <<sent, rx, tpc, current, cancel, iter, left, order>>

ModelAnswers ==
    /\ mode = "turn" /\ tpc = "call"
    /\ iter' = iter + 1
    /\ IF iter + 1 < MaxIter /\ steers # <<>> /\ ~cancel
       THEN LoopTop(iter + 1, steers, absorbed)   \* a late steer gets a reply in this turn
       ELSE /\ EndTurn("end_turn") /\ UNCHANGED tpc   \* a final answer wins over cancel
    /\ UNCHANGED <<sent, rx, current, cancel, left, order>>

ModelCallsTools ==
    /\ mode = "turn" /\ tpc = "call"
    /\ iter' = iter + 1
    /\ \E n \in 1..MaxTools :
         IF cancel
         THEN \* every call gets CANCELLED_TOOL_RESULT, then the loop top
              /\ left' = 0 /\ LoopTop(iter + 1, steers, absorbed)
         ELSE /\ left' = n /\ tpc' = "tool" /\ mode' = mode
              /\ UNCHANGED <<deferred, replies, steers, marks, absorbed>>
    /\ UNCHANGED <<sent, rx, current, cancel, order>>

\* A tool finishes; the remaining calls are skipped if cancelled.
ToolDone ==
    /\ mode = "turn" /\ tpc = "tool"
    /\ IF left > 1 /\ ~cancel
       THEN /\ left' = left - 1
            /\ UNCHANGED <<mode, tpc, deferred, replies, steers, marks, absorbed>>
       ELSE /\ left' = 0 /\ LoopTop(iter, steers, absorbed)
    /\ UNCHANGED <<sent, rx, current, cancel, iter, order>>

\* Everything sent has been handled.
Done ==
    /\ sent = N /\ rx = <<>> /\ deferred = <<>> /\ mode = "idle"
    /\ UNCHANGED vars

Next ==
    \/ Send \/ Take \/ Route
    \/ ModelCancelled \/ ModelAnswers \/ ModelCallsTools \/ ToolDone
    \/ Done

Spec == Init /\ [][Next]_vars /\ WF_vars(Send) /\ WF_vars(Take) /\ WF_vars(Route)
        /\ WF_vars(ModelAnswers \/ ModelCancelled \/ ModelCallsTools) /\ WF_vars(ToolDone)

-----------------------------------------------------------------------------
(* Properties *)

TypeOK ==
    /\ mode \in {"idle", "turn"} /\ tpc \in {"call", "tool"}
    /\ Len(steers) = Len(marks)
    /\ \A m \in 1..N : replies[m] \in 0..2

\* No request is answered twice.
AtMostOneReply == \A m \in 1..N : replies[m] <= 1

\* No steer is absorbed into a turn after it was cancelled.
NoSteerAfterCancel ==
    [][cancel /\ mode = "turn" /\ mode' = "turn" => absorbed' = absorbed]_vars

\* Messages that run on their own (not absorbed into a running turn) run in the
\* order the client sent them.
SendOrder == \A i, j \in 1..Len(order) : i < j => order[i] < order[j]

\* Every request is eventually answered.
AllAnswered == <>(\A m \in Requests : replies[m] = 1)
=============================================================================
