# zigbox-smoke on 5b1ca09: a fetch silent after it chose a peer (issue #93)

Status: **undiagnosed: the logs show only two fetch.log lines, then silence.**

## What the run shows

- The failing container's `fetch.log` (python two, replica 1; 119 bytes) holds exactly two
  lines: "a peer came to hold the tree after 1 ms (O5)" and "left out 1 nodes (1 with this node)".
- After them there is no "bundle found", no progress line and no `ZC-` code, until the smoke's
  120 s deadline ended the run.
- So the fetch got past the election and the peer choice and then neither finished nor failed.
  It has no deadline of its own at that point, and it says nothing while it waits.

## What is not known

The state of the fetch process at 120 s (blocked on a peer read, on the registry, or on a
write) was not recorded. The logs do not say which, so no cause is claimed here.

## What would settle it

- A progress line, or a coded timeout, for a fetch that is silent after peer selection. A new
  code or a new bound needs the supervisor's decision (HANDOFF, **Ask first**); not added here.
- Until then the smoke's failure output should keep each container's `fetch.log` (it did this
  time, which is how the two lines above are known) and, if the machine allows, the fetch's
  `/proc/<pid>/stack` and open sockets at the deadline.
