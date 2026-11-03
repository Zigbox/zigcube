# C2 slice 2 (P1, approved): a service names the OCI reference its image is pulled from in source, beside image (the tree digest)

*Decided 2026-11-03.*

C2 slice 2 (P1, approved): a service names the OCI reference its image is pulled from in `source`, beside `image` (the tree digest). `Service` and `Replica` are v3 (v1 and v2 read, `source` empty; v4 is ZC-E0303). Apply accepts empty, or at most 1024 bytes ending `@sha256:` plus 64 lowercase hex, no whitespace or control characters; that is a prefilter, the supervisor's `pull.parse_reference` stays the parser of record. `source` reaches `Runtime.Spec.source`; `ZigboxRuntime` prefers it to the node's `--images` file, which stays as a deprecated fallback (the agent says so on stderr); the fake and simulated runtimes ignore it. **Pending owner confirmation:** (1) the name stays `source`, and the unwritten reservation in `docs/keys.md` is renamed `provenance`; (2) a change of `source` bumps `generation` (a held replica is replaced when the reference is fixed). `ops/zigbox-smoke/guest.sh` uses `source` and no `--images`; its `cached` service (no `source`, tree in the store) covers the fallback.

Where: `docs/briefs/c2-2.md`, `docs/keys.md`, `src/apply.zig`
