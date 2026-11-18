# C5's slices 1, 2, 3a and 3b are built from main now; 4a onward waits for C3 and C4

*Decided 2026-11-18, by the supervisor, on the owner's direction to build C5 now.*

`docs/briefs/c5.md` lists C3 and C4 on `main` as prerequisites of every slice. The first four
slices do not depend on them:

- **1, Public TLS mode**: the `Public` mode of `tls_server.zig` and `edge_host.zig`. Core only;
  no mesh, grant or `/service/` certificate.
- **2, Sealing**: `seal.zig` and the key file.
- **3a, the ACME core**, and **3b, the ACME shell** (with `zig build acme-interop` against
  Pebble and a test-only :80 responder in place of the edge).

So these four are built from `main` now, in that order, one pull request each. Slice 4a (the
edge's authorization: `/edge/<node>`, derived grants in `mesh_plan`) and every later slice wait
until C3 and C4 are merged on `main`.

Where: `docs/briefs/c5.md`, "Slices".
