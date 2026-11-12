# ZC-E0703 stays registered without a raising runtime

*Decided 2026-11-12, by the supervisor after B3 release review A (https://github.com/Zigbox/zigcube/pull/216#pullrequestreview-5868569297).*

**Decision.** ZC-E0703 (a runtime cannot give a container a relay) stays in the code registry
(`src/diag/codes.zig`) and in the golden sample (`src/cli_golden.zig`), although no runtime
raises it since B3 slice 4.

**Reasons.** `docs/api.md`, `docs/agent.md` and `docs/demos/b3.md` promise the code to a future
agent build that has no relay support: such a build refuses a relayed job with ZC-E0703 instead
of starting it without egress control. Removing the code now would make that promise dangling and
would have to be restored when the build lands.

**Exception to DIAGNOSTICS.md.** DIAGNOSTICS.md requires that a test triggers every registered
code. ZC-E0703 is an accepted exception: only its golden sample exercises it, and no test raises
it through a runtime. This decision is the record of that exception.

**Revisit** when an agent build without relay support lands, or at the next code-registry
cleanup, whichever comes first. At that point either the build raises ZC-E0703 and the exception
ends, or the promise in the docs above is withdrawn and the code is removed in the same change.

**Where:** `docs/api.md` (the code table and the relay note), `docs/agent.md` (the relay section),
`docs/demos/b3.md` (the golden note), `src/diag/codes.zig`, `src/cli_golden.zig`.
