# Gate for shipping C1 (owner): besides demo-c1 green in CI, an always-on instance runs the cluster simulation 24/7 at main and files a GitHub issue for each new failure (shrunk, deduplicated, with seed and replay command)

*Decided 2026-10-30.*

Gate for shipping C1 (owner): besides `demo-c1` green in CI, an always-on instance runs the cluster simulation 24/7 at `main` and files a GitHub issue for each new failure (shrunk, deduplicated, with seed and replay command). C1 ships after the fleet has run 24 hours on the shipping commit with every issue closed or recorded as a cut; later milestones ship under the same rule. Brings the seed fleet and hub forward from "Later, not in 2b" in the row below into C1, as slice 9; the Runtime conformance suite, Postgres fault proxy and chaos lab stay later.

Where: `docs/briefs/c1.md`, live design doc
