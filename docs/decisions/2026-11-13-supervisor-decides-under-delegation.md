# The supervisor decides what reviewers agree on; the owner is asked only for what is theirs

*Decided 2026-11-13, by the owner.*

## Decision

From 2026-11-13 the supervisor decides, without asking the owner first:

- user-visible bounds, limits and defaults, and new diagnostic codes, when the slice's two
  independent Opus reviewers do not object to the value;
- the conservative option where a model or simulation finding offers a choice of repair;
- scope cuts that keep the milestone's demo, recorded in the milestone's demo document.

Each such call is recorded in its own file in `docs/decisions/`, saying it was decided by the
supervisor under this delegation. The owner can overturn any of them with a later file.

Open questions for the owner are batched into one digest a day, each with the supervisor's
recommendation. A recommendation stands if the owner has not answered it within 12 hours.

These stay with the owner: signing keys and secrets, tags and signed public releases (the
`release` environment), the licence, money and quotas, and anything that loosens security or a
rule the owner has set.

Reviews: every pull request gets two independent Opus reviewers, run in parallel, and one fix
pass for their MUSTs. A re-review is needed only when the fix pass changes behaviour beyond the
MUSTs. Release reviews are unchanged (`AGENTS.md`, Releases).

## Why

The owner is the bottleneck on decisions that reviewers already agree on, and is available
for a limited time. Delegating them shortens each slice by a round trip.

Where: `AGENTS.md` ("Stop and ask the supervisor" now means the supervisor decides under this
file), `docs/supervisor-handoff.md`.
