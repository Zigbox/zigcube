# Release gates: sim-clean, Jepsen-clean once Jepsen exists, two independent Opus reviews (owner, 2026-11-04)

A release is cut only from a commit that the simulation fleet has run clean for 24 hours (every simulator the milestone gates on), that passes the Jepsen battery once it exists (a C5 prerequisite), and that two independent Opus reviewers, each in a fresh session that does not see the other's findings, have reviewed adversarially; every MUST is fixed or accepted by the owner in writing. The rule is in AGENTS.md, "Releases". Zigbox 0.3.0 was cut before this rule.
