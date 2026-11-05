# zigbox-smoke: the agents run as `cube`, not root

Status: decided 2026-11-05, on PR #66. Corrects the "Update" section of
`2026-11-04-c2-slice8-m4-smoke-blocked-on-z9.md`.

## What happened

`c990ed9` ran the smoke's agents as root (stage `setup_root`, `root:200000:65536`, root's bus) to
get around gap 2 (a non-root peer server cannot open range-owned objects of mode 0640). It was
not run: no KVM. CI then failed in stage `replicas` on both runs that had it:

- run 41904107133 (`802e013`, Zigbox 0.3.0 pin) and run 41934911334 (`d40d7ad`, 0.3.1 pin):
  `FAIL: timed out after 240s waiting for 2 box replicas running`; the agent log ends at
  "joined the cluster CA"; `zbx doctor` ok, including `subid root`.
- run 41888110848 (`48bad44`, agents as `cube`): `replicas`, `kill`, `restart`, `oom`, `refusals`,
  `scale0`, `peers_prep` and `peers_up` all passed; only `peers_fetch` failed (the Z9 gap).

So neither the 0.3.1 pin nor the Z9 adapter caused it: 0.3.0 failed the same way, and
`peers_fetch` was never reached. The change that broke it is the move to root.

## Which side is wrong

The harness. Zigbox's SPEC ("Rootful mode. There is no `sudo zbx`. If something only works as
root, it is not supported") and `zbx doctor` (probes drop to uid 65534; "nothing here lets uid 0
pass") make root an unsupported way to run containers. Zigbox's VM guests run as an ordinary user.
Not proven from the logs: the exact step root fails at. The agent says nothing about it, which is
itself worth a look (a replica that cannot start should leave a diagnostic in the observed record).

## Decision

Agents run as `cube` again (`runuser`, uid 1000 bus). Gap 2 stays open for the peer server until
`peers_fetch` shows otherwise; if it fails on it as `cube`, that is a real C2 blocker to report to
Zigbox, not to work around with root.
