# C4: the owner's answers to the brief's questions

*Decided 2026-11-13, by the owner.*

Every question in `docs/briefs/c4.md`, "Questions for the owner" (O1 to O11), is answered as
recommended there:

1. **mTLS per connection, no WireGuard in C4.** Workload connections are mutual TLS between the
   two replicas' supervisors, with workload certificates from the cluster CA. The SPEC's C4 scope
   ("WireGuard tunnels between nodes") and its open question ("mTLS per connection, or identity
   carried at the WireGuard layer?") still read as before in the live design doc and in the
   snapshot in Zigbox's `docs/SPEC.md`: they need the owner's edit, which is the owner's to make.
2. **`Runtime.Spec.mesh` and `Runtime.mesh_update` may be added** (HANDOFF, Ask first): the
   replica's mesh port and initial rules at start, and a non-blocking update of a running
   container's grants and endpoints. Nothing else in `Runtime` changes.
3. **Names resolve through a per-container `/etc/hosts`**, owned and rewritten by the supervisor
   (Zigbox request ZB-2), mapping every service name to its stable `127.77.x.y` mesh address. No
   DNS responder.
4. **"Zero errors under real traffic" is demo step 5 as written:** a `loadgen` service at 20
   requests/s, one connection per request, through the mesh, across a rolling update of `web`. A
   request fails if its connection is refused or reset, or the response is not 200 within 2 s.
   The demo asserts zero failures and at least 90% of the expected count, and M5 holds in
   simulation at every step. Long-lived connections across a rollout are not claimed.
5. **TCP health checks are in C4; HTTP checks are not.**
6. **Order:** C3 finishes first. C4 slices 1, 2 and 4 run alongside C3's later slices (slice 1
   stacks on C3 slice 5's record versions). B4 and B7 slice 1 come before C4's slices 3 and 6.
   C4 is released on its own, not combined with C3. The owner agreed "if that's optimal for
   time", and the supervisor confirmed that it is.
7. **Grants are declared on the destination** (`db.zon`: `.allow = .{ .{ .from = "web", .port =
   5432 } }`; `zcube grant add web db:5432` writes there).
8. **`workload_cert_ttl_ms` is 1 hour**, renewed at half-life with a fresh key. A certificate
   that cannot be renewed takes the replica off the mesh (W0703) but does not stop it.
9. **The bounds as listed:** `mesh_revoke_ms` 1000, `mesh_drain_ms` 3000,
   `mesh_connect_attempts_max` 3, `mesh_connect_timeout_ms` 5000, `mesh_connections_max` 64 per
   replica, `--mesh-ports` default `30000-30999`, and the address block `127.77.0.0/16`.
10. **The code set is approved:** ZC-E0707 to E0711, W0703, W0704 and E0135, with numbers fixed
    in C4 slice 1, avoiding collisions with C3's (E0125 to E0129, 03xx, 05xx) and B4's (E0706)
    reservations.
11. **Local mode's mesh runs only with the Zigbox runtime on Linux.** With `FakeRuntime` and on
    macOS, `zcube local up` refuses grants with one line saying why.

Where: `docs/briefs/c4.md`.
