# C4 slice 3: the supervisor's rulings on the service-certificate review

Date: 2026-11-14. Status: decided by the supervisor, except ruling 2's admission rule, which goes to
the owner for sign-off (below). It adds to `2026-11-14-c4-service-certs.md`, which stays as merged.

Reviews A and B of C4 slice 3 (service certificates, `service_cert.zig`, the agent API's
`POST /v1/agent/nodes/{node}/replicas/{id}/certificate`, `sim_mesh_certs.zig`) raised one MUST and six
SHOULDs. The supervisor ruled on each; this file records the rulings and what the fix session did.

## 1. A replica id has its own bound

The endpoint and the agent API's other checks bounded a replica id by `service_name_bytes_max`
(48). A replica id is `<service>-<n>`, so a service of 46 to 48 bytes has ids of up to 50 bytes and
every ask for them was a 400. The id's bound is now `constants.replica_id_bytes_max` (63, the
container-name rule `records.replica_key` has always checked), named once and used by the
endpoint, the agent's report checks and the key builders; a comptime assert keeps
`service_name_bytes_max + 1 + 9 <= replica_id_bytes_max` (the longest service and replica number fit).
`api_test.zig` asks for a replica of a 48-byte service (200), an unassigned id of 63 bytes (409) and
one of 64 (400).

## 2. A short pin is refused with a cause of its own

Admission accepts an image of 1 to 67 bytes (`apply.zig`), so a service may pin `b3:` and fewer than
64 hex digits. A workload certificate names the full digest (x509 identity extension), so the issuer
cannot certify such a replica. It keeps failing closed, and the refusal is its own cause under
ZC-E0706 (no new code): `service_cert.Refusal.short_pin`, "the service pins its image by a short
digest, and a certificate names a full one", with the fix "pin the full 64-hex digest".

No admission warning in this slice: a follow-up (a warning at `zcube apply` when a service pins a
short digest, since it can never join the mesh).

**For the owner's sign-off:** the rule "admission accepts a short pin, the mesh refuses it". The
alternative is to refuse short pins at admission once the mesh ships; that changes what `apply`
accepts, a user-visible bound, so it is the owner's call.

## 3. The node gate is the node-keyed lookup

The issuer reads `/assigned/<node>/<id>`, where `<node>` is the asking node, so the assignment it
finds is always the asking node's. `decide`'s compare of the assignment's node with the ask's could
never fail, and its unit teeth tested a path the server never takes. **Dropped**, not made
reachable: making it reachable would mean reading assignments some other way only to compare the
node back, which adds a path to get wrong and checks nothing the key does not. The lookup moved
into `service_cert.look_up`, which the agent API and the simulator share, so a tooth on it weakens
the code the server runs:

- `mesh_issue_any_node` (`c1_teeth.zig`, `sim-c1-teeth-mesh_issue_any_node`): the lookup takes the
  first assignment of the id on any node. M3's "not assigned to the node" clause must fail; the
  simulator's forged asks from other nodes find it.
- Server-side, `api_test.zig`'s node2 ask (409) fails if the lookup ignores the node.

`Assignment` has no node any more; the unit teeth for a mismatched service stay.

## 4. Renewal is checked: M3r

A sim check like J10, judged only after the heal: a running service replica whose node is up and
connected, and which the issuer would certify (assigned to that node, the replica exists, a full
digest equal to what the container runs), must hold a certificate before half-life again within
`ask_interval_ms + renew_cut_ms` (1 s + 2 s) of needing one, measured in simulation time from the
heal at the earliest. The cut covers the node's clock rate (asks are timed on it) and the tick.
The report adds `mesh: longest wait for a certificate after the heal N ms (M3r bound 3000)`.
The tooth `mesh_renew_late` (a supervisor that renews only at expiry, not at half-life) must fail
it with "M3r: ...".

## 5. The agent side is cut (approved)

Renewal, the half-life ask and ZC-W0703 exist only in the simulator's model of the supervisor
(`sim_mesh_certs.supervise`); `zcube-agent` and the real supervisor ask for no service certificate
yet. M3, M3r and M6 check that model and the issuer it calls. The slice that adds the real
supervisor's ask must put it under the simulation (the model replaced by, or proved equal to, the
real code). Recorded in `docs/demos/c4.md`, "Cuts".

## 6. Security

`docs/mtls.md`'s "Issuance is unauthenticated until B7" bullet now covers service certificates, and
the citations that pointed at threat T5 (which is about supervisors, not issuance) point at
"Issuance" (`agent_api.zig`, `docs/api.md`). Until B7 authenticates issuance, the mesh must not
trust a `/service/` certificate as proof of the replica it names: anyone who reaches the agent API
and knows a replica's node, epoch and digest can have one for a key of their own.

## 7. Replay

The strong world changed: the issuer goes through `look_up`, the refusal set gained `short_pin`
(the report's `refused by` line), M3r runs and the supervisor tick judges it. A `--strong` replay
line (and any `auto` line, which switches `--strong` on) written before this slice may run a
different world. These fixes leave worlds without `--strong` unchanged: whole reports of
`sim_cluster <seed> 120 --c1` (seeds 11, 19, 42) and `sim_cluster 9 60` are byte-identical to the
merge they start from (f2be6d4). Against a0a6847, as the ruling asked: seeds 3 and 7 (`--c1`) and
plain seed 5 are identical, but seeds 11, 19, 42 (`--c1`) and plain seed 9 differ in the `world
hash` line alone (every count the same). Slice 3 as first written (6431405) was identical to
a0a6847 on seeds 11 and 19; the difference arrives with slice 2's merge (5a266c8), which this
branch took in, so it is slice 2's, not this slice's: a non-strong replay line from before slice 2
replays the same run, and its final world hash can differ. AGENTS.md's sim-c1 entry says the
`--strong` part.

## 8. No assert on stored data

`records.replica_key` asserted that the id starts with the service; the issuer called it with the
service an assignment record names, so a corrupt record would have crashed the server. The issuer
now checks first (`records.replica_id_valid`) and refuses as not assigned (`wrong_node`);
`replica_key`'s assert stays for callers whose arguments are their own. `api_test.zig` writes such a
record and expects 409.

## Notes, not acted on

- Forged asks skew to `wrong_node`, and an honest ask that is stale because the agent's watch lags
  is never exercised (the model reads the epoch from the store as committed). A lagging watch in
  the model would exercise it; a follow-up for the slice that brings the real supervisor.
- The simulated issuer now reads time from the asking node's (skewed) clock, as `sim_certs.zig`
  does; slice 5's mesh checks must allow for that skew.
- `docs/api.md`'s paragraph on causes that are not final (503) is about runs only; the replica
  endpoint says so.
