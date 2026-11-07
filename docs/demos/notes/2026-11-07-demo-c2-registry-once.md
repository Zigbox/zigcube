# demo-c2 on 4b97e69: the registry was read three times (O5 wait shorter than the pull)

Status: **diagnosed; the fix changes a bound, so it is not made here** (asked of the supervisor).

## What the run shows

- Step 1 asserts "the registry is read once". All three nodes took 43,273,982 B from it.
- Two nodes (python-app-1 and -3) logged "no peer came to hold the tree in 30000 ms; 3 node(s)
  fetch it (O5)" and fell back to the registry.
- The elected node (python-app-2) needed 35,587 ms for its own registry pull. The runner was
  slow: its apt and QEMU setup alone took about 10.5 minutes.

## Cause

The other nodes wait for the elected node up to the O5 cap (`constants.zig`, 30,000 ms) and then
go to the registry themselves. On a runner where one pull takes longer than the cap, the wait
ends before the pull does, every node pulls, and "once" is false. It is a timing assumption, not
a defect in the election.

## Choices (not taken)

1. Raise the cap above the slowest pull CI sees. It is a user-visible bound; it also delays a
   real fallback when the elected node died.
2. Have the demo's registry throttle or the runner's pull stay well under the cap.
3. Keep the cap and let the demo accept "at most once per election round" on a slow runner.

Recorded on issue #93 and sent to the supervisor.
