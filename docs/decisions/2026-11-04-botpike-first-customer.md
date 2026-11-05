# Botpike is Zigcube's first customer; the roadmap after C2 is ordered with its needs first.

*Decided 2026-11-04, by the owner.*

Botpike (`Botpike/app`) drops its own agent runtime and runs agents as Zigcube jobs. Its
requirements are listed in `docs/briefs/botpike-first-customer.md`: jobs (from C8), a relay as a
workload's only network route and workload identity on it (slices of C4), signed images only (a
slice of C6), placement by tenant, and an authenticated API. Each is cut from a milestone already
in SPEC Part II, as the general feature, not a Botpike-specific one.

The owner decided that Botpike comes first. The exact order in that file, and its owner questions
O1 to O5, are a proposal until the owner answers them; a later decision file records the answers.

Reason: a paying first customer tells Zigcube which parts of C4, C6 and C8 matter first, and the
Botpike runs Zigcube would carry are exactly the untrusted, short-lived, money-spending workloads
those milestones were designed for.

Where: `docs/briefs/botpike-first-customer.md`; `Botpike/app` `docs/specs/runs-on-zigcube/`.
