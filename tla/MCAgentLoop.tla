----------------------------- MODULE MCAgentLoop -----------------------------
EXTENDS AgentLoop

\* A prompt; during its turn a steer, a slash command, another steer and a
\* cancel; then a final prompt. Any suffix may arrive after the turn ends.
MCScript ==
    << [id |-> "prompt",  kind |-> "text"],
       [id |-> "steer-1", kind |-> "text"],
       [id |-> "/plan",   kind |-> "cmd"],
       [id |-> "steer-2", kind |-> "text"],
       [id |-> "cancel",  kind |-> "cancel"],
       [id |-> "next",    kind |-> "text"] >>
=============================================================================
