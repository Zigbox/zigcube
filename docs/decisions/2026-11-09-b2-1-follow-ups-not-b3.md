# B2's follow-ups are B2.1, not B3

Decided by the supervisor on 2026-11-09, under the owner's instruction to make sane assumptions and
document them. The owner approved starting the follow-ups collected in #205 ("Go for your
suggestions"); #205 was titled "B3".

## The conflict

[2026-11-07-b2-scope-decisions.md](2026-11-07-b2-scope-decisions.md), decision 1, already gave B3
to the Botpike relay (B4 identity, B5 signed images, B6 placement by tenant, B7 API identity), and
[../briefs/botpike-first-customer.md](../briefs/botpike-first-customer.md) is numbered that way.
Calling the follow-ups B3 would renumber the Botpike sequence a second time in three days.

## The decision

- The follow-ups are **B2.1**, a hardening point release. Brief: [../briefs/b2.1.md](../briefs/b2.1.md);
  tag `b2.1`; retro `docs/retros/b2.1.md`. The relay stays B3.
- `b2.1.md` is not a slice brief (those are `b1-1.md`, `c1-2.md` and so on); the dot is what tells
  them apart.
- #205 is retitled to match. Nothing else is renumbered.
- B2.1 ships under the full release rule (AGENTS.md "Releases"), like B2.
- No B2.1 branch merges to `main` before the `b2` tag: a merge restarts the fleet's 24-hour clock
  on B2's candidate.
