# Minimize the time to release

*Decided 2026-11-11, by the owner.*

Minimizing the time to the next release is an overall constraint on all work, in both Zigbox
and Zigcube. When choosing what to start, how to split it and what runs in parallel, the
supervisor and implementers pick the option that ships the next release soonest, within the
existing rules: the release gates (sim-clean, the 24-hour fleet soak where it applies, two
independent Opus reviews, every MUST fixed or accepted) and the review of every slice stay.

In practice:

- Work on the critical path to the next release starts first and takes the first free session.
- Work that can run beside it runs beside it, up to the session cap.
- Gates that can overlap do (a release review during the soak, a dependency release cut beside
  the work that needs it, as in the B3 pin decision).
- Several milestones may ship as one release when that saves a soak and a pair of reviews.

Where: `AGENTS.md`, `docs/supervisor-handoff.md` (Zigcube).
