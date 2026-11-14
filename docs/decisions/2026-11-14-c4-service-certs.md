# C4 slice 3: service certificates

*Decided 2026-11-14, by the slice (C4 slice 3); items marked "raised" await the supervisor.*

**Stacking.** The branch `claude/c4-slice3` starts from `claude/c4-slice2` (28de5de) and merges
`claude/b4-slice2` (4adcba5) and `claude/b4-slice3` (cc81cd9), merge commits only. The merges were
built and tested (`zig build test`) before any slice 3 code. Review fixes on those branches are
merged in, never rebased.

**Issuance.** `src/service_cert.zig` (core) is B4's rule (`job_cert.zig`) for `/service/<name>`:
the asking node must hold `/assigned/<node>/<id>` with the replica's service, the ask's epoch must
be that key's `mod_revision`, and the ask's digest must be the one `/replicas/<svc>/<id>` runs.
The endpoint is `POST /v1/agent/nodes/{node}/replicas/{id}/certificate` (docs/api.md). Refusals
are ZC-E0706 with a cause that names the replica and its service. E0706's summary became "the
server refused a workload certificate" (it was the job's), and its explanation covers both kinds.

**Rename (mechanical).** `peer_ca.issue_job_certificate` and `JobArgs` became
`issue_decided_certificate` and `DecidedArgs`, which carry the SPIFFE path, so the job and the
service call sites share them.

**Raised: no labels.** The brief puts the service's labels in the identity extension. Services
have no labels (`records.Service` has none, and no admission rule bounds them), so a service
certificate carries none. Labels on services, with ZC-E0130 at admission, belong to whichever
slice adds them.

**Raised: a service image must be a full digest.** The certificate attests the digest, so a
replica whose image is not `b3:` and 64 hex digits is refused (`wrong_image`). Admission still
accepts short pins; until it refuses them, such a service runs off the mesh.

**The ttl is a parameter.** `service_cert.decide` takes the ttl: the server passes
`workload_cert_ttl_ms` (1 hour, O8), the simulator 20 s (`sim_mesh_certs.ttl_ms`), so runs reach
renewal and expiry.

**The simulator.** `src/sim_mesh_certs.zig` models the supervisors of the strong world's service
replicas (key, ask, renewal at half-life with a new key, expiry as ZC-W0703 with the replica
left running) and forged asks, and judges M3 and M6 at each issue against records it reads
itself. In the strong world a service's image is a full digest (`sim_cluster.full_digest`); the
draws are unchanged. The supervisor reads its assignment's epoch from the store as committed
(it stands for the agent's watch), so stale epochs come from forgeries only.

**Teeth.** `mesh_issue_stale` (M3) and `mesh_reuse_key` (M6) live in `c1_teeth.zig` and
`c1_teeth_roots` (so `sim-c1-teeth-mesh_*` and their canaries exist) until slice 5 brings
sim-c4; both switch the strong world on.

**Cut: the agent's side.** The agent and the supervisor do not make keys, call the endpoint,
renew or raise W0703 yet: nothing uses a service certificate until the mesh listeners and the
mesh port (later slices). The simulator models that side, and the slice that opens the first
mesh connection brings it to the agent, with agent-smoke.

Where: docs/briefs/c4.md (slice 3), docs/api.md, src/service_cert.zig, src/sim_mesh_certs.zig.
