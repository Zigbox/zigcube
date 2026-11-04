# C2 slice 8 (M4): the two-agent smoke is blocked on the Z9 gap

Run 41888110848 (commit 48bad44), zigbox-smoke, stage `peers_fetch`: B's `pyone`
(python:3.12-slim, pinned by digest, A holds it and its peer server was restarted after A's pulls)
ran with `registry=43523430 cached=0 peer=0 peers=-`. `containers/pyone-1/fetch.log` exists and
is empty: the fetch was spawned, produced no output and did not finish with peer bytes; the
supervisor then pulled everything from the registry. `doctor.log` shows `subid` 65536 ids for
`cube`, i.e. a non-root agent with a range, the case the first gap in
`2026-11-04-c2-slice8-review-fixes.md` (M3) describes: every one-chunk object is `Damaged` on
the serving peer, and python:3.12-slim has many.

Not worked around, per the supervisor: no image-specific skipping, no weakening of
"peer bytes > 0". The smoke stays red until Zigbox 0.3.1 (Zigbox PR #53) lands and
`build.zig.zon` pins it. Open: the empty `fetch.log` is itself worth a look (the fetch should say
why it gave up); it is not proven that every chunk failed for Z9 and not for another reason.

Lasting trap (S3): agent A's peer server indexes its store at start; the supervisor's pulls write
chunks behind its back, so the smoke restarts A after its pulls (`stage_peers_prep`).
