# C2 slice 1 smoke: zigbox-smoke drives the server and agent in the guest with curl and python3 (no zcube binary copied); trees come from Zigbox's zbx.lock, not zbx pull; ops/zigbox-smoke/guest.sh is the one allowlisted shell script (tidy); binaries are stripped to fit the harness's 8 MiB served-body cap; pid_limit is cut because the service API has no pids

*Decided 2026-11-03.*

C2 slice 1 smoke: `zigbox-smoke` drives the server and agent in the guest with `curl` and `python3` (no `zcube` binary copied); trees come from Zigbox's `zbx.lock`, not `zbx pull`; `ops/zigbox-smoke/guest.sh` is the one allowlisted shell script (tidy); binaries are stripped to fit the harness's 8 MiB served-body cap; `pid_limit` is cut because the service API has no `pids`. Not run on KVM yet: the pinned Zigbox 0.2.1 package omits `vm/` from its `.paths`, so CI cannot build it (FileSystemFailure on `vm/kernel/pin.zon`).

Where: `docs/demos/c2.md`
