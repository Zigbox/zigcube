# C2 slice 1 proposals (owner, relayed by the supervisor): P1, source (an OCI reference) on Service/Replica/Runtime.Spec, is approved for slice 2; slice 1 stays on the node-local --images file

*Decided 2026-11-02.*

C2 slice 1 proposals (owner, relayed by the supervisor): P1, `source` (an OCI reference) on Service/Replica/`Runtime.Spec`, is approved for slice 2; slice 1 stays on the node-local `--images` file. P2, a non-blocking `Runtime.signal`/`stop_begin`, is approved but done after C1 slice 6 merges; slice 1 keeps signal plus a bounded wait (a fence over N containers costs N times that bound). P3, apply's limits narrowed to Zigbox's, is done in slice 1: `runtime_env_count_max` 64 to 16, `runtime_labels_max` 16 to 8, label keys 63 to 32 bytes, values 253 to 128 (`docs/api.md`, `src/apply.zig` test). `ZBX-E0501` became Zigbox's `ZBX-E0410`.

Where: not recorded (the source row had no Where cell)
