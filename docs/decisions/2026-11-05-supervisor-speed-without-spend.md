# The supervisor merges ready pull requests; sessions report back when done

Date: 2026-11-05. Decided by the owner.

## Context

Most of a slice's wall-clock time was waiting, not work: a fix session that finished cleanly sat
idle until the supervisor's next timed check-in (up to 30 minutes), a `zig build check` killed by a
command timeout had to start again (10+ minutes lost on #96), and pull requests that were ready
waited for the owner to merge.

## Decision

1. **Sessions report back.** Every brief the supervisor writes ends by telling the session to
   notify the supervisor's session when it has pushed with `check: PASS` (or posted its review):
   with `send_message`, or, where a session lacks that tool, a one-shot scheduled task that fires
   into the supervisor's session. Timed check-ins remain only as a backstop.
2. **`zig build check` runs in the background**, its output in a file, and the session reads only
   the last line once it exits. A command timeout must never kill it.
3. **The supervisor merges a pull request that is ready**: its latest review's verdict is merge (or
   merge after MUSTs, with every MUST fixed), CI is green on the head commit, and the report's
   `check: PASS` names that commit. Squash merge, no model names in the message. Anything that
   needs the owner's judgement (an open design question, a release, a deploy) still goes to the
   owner first.

## Consequences

Less idle time between steps and fewer empty check-ins, so no more tokens and usually fewer. The
owner sees merges after the fact, in the supervisor's reports.
