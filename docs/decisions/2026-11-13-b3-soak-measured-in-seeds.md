# b3 soaks, and a soak may be measured in seeds

*Decided 2026-11-13, by the owner (the supervisor's proposal).*

b3 ships features (the relay, the job fixes of #244), so it runs the fleet soak, as the b2 retro
said the next feature release would. The soak is measured in seeds, not hours:

- **Commit.** The soak runs on one fixed commit: `main` right after #244 merges. Nothing else
  merges to `main` until b3 is tagged, except changes to docs only. In particular #242 (the
  authority repairs) merges after the b3 tag and gets its own soak in b4.
- **Target.** The seeds of one full day of the fleet at its old size (1 worker per kind), taken
  from the tracker's post for 2026-11-12 (#29): **20,900 `sim-cluster` seeds and 20,900 `sim-c1`
  seeds**, all on the soak commit. `sim-swarm` has no seed target for b3: no swarm code changed
  since b2 (`git diff b2 main -- src` touches no swarm or fetch file), and its seeds in the same
  window count as usual.
- **Gate.** The tag is cut once the tracker (or the fleet's journal) shows both targets reached on
  the soak commit, with no `sim-fleet` issue open against it and every teeth canary that ran
  caught. Any new failure stops the soak; its fix is a new commit and the count starts again.
- **Fleet size.** The owner moved the fleet to a host with 14 slots: 6 `sim-cluster` workers, 6
  `sim-c1`, 1 `sim-swarm`, and one slot left for the reporter, builds and the canary, so the
  target takes about 4 hours instead of 24.

Rule for later releases: a feature release soaks; the soak may be measured in seeds, at least
the seeds per simulator of 24 hours at the 1-worker size (the numbers above), on the release
commit. A hardening-only release may still be waived in writing, as b2 was.

Related: `2026-11-04-c2-ships-without-fleet-soak.md`, `2026-11-07-b1-ships-without-fleet-soak.md`,
`docs/retros/b2.md`.
