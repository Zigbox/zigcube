# C2 slice 1 review fixes: a pid-0 Zigbox record is starting and stop kills the supervisor, never pid 0; a grace of 0 waits stop_wait_ms once; a record is a launch's only if its supervisor equals the launch's supervisor.pid; the image lock must be the full b3:+64 hex form; ZBX-E0307 is ZC-E0512; the supervisor is single-threaded by construction (Io.Threaded.init_single_threaded) and checks Threads: 1 (ZC-B0002); ZBX_REGISTRY_MIRRORS of the agent's environment is passed to pull.

*Decided 2026-11-03.*

C2 slice 1 review fixes: a pid-0 Zigbox record is `starting` and `stop` kills the supervisor, never pid 0; a grace of 0 waits `stop_wait_ms` once; a record is a launch's only if its supervisor equals the launch's `supervisor.pid`; the image lock must be the full `b3:`+64 hex form; ZBX-E0307 is ZC-E0512; the supervisor is single-threaded by construction (`Io.Threaded.init_single_threaded`) and checks `Threads: 1` (ZC-B0002); `ZBX_REGISTRY_MIRRORS` of the agent's environment is passed to pull.

Where: `docs/agent.md`
