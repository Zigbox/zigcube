# ZC-W0603: the swarm fetch ended without the tree

*Decided 2026-11-06, by the owner* (issue #93, PR #109 review).

The supervisor's end lines in `fetch.log` reused ZC-E0601 ("not fetched from any peer or the
registry", error, external) before the registry was tried. ZC-W0603 (warning, environment) says
"the swarm fetch ended without the tree; the registry pull follows", with the reason (did not
start, exit not 0, killed at its deadline) in the cause. ZC-E0601 stays the fetch's own line.
`ops/zigbox-smoke/guest.sh` anchors on the fetch's rendered `error[ZC-E0601]`.
