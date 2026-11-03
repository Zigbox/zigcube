# C2 slice 1 design: a Zigbox container is starting while its supervisor holds the launch directory's lock and Zigbox has no record newer than the launch; the supervisor pulls only after zigbox.start fails with ZBX-E0410 and a reference is known, and checks the pulled tree equals the locked digest (ZC-E0511)

*Decided 2026-11-02.*

C2 slice 1 design: a Zigbox container is `starting` while its supervisor holds the launch directory's lock and Zigbox has no record newer than the launch; the supervisor pulls only after `zigbox.start` fails with ZBX-E0410 and a reference is known, and checks the pulled tree equals the locked digest (ZC-E0511). The agent preflight is Linux plus a readable run directory (ZC-E0513) because Zigbox's doctor is not exported.

Where: `docs/agent.md`, `src/zigbox_image.zig`
