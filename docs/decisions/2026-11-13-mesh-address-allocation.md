# C4: how mesh addresses are handed out and kept

*Decided 2026-11-13, by C4 slice 1; the bound, the code and the downgrade approved by the supervisor the same day.*

- **A counter and one hold per address.** `/mesh-address-next` names the next number to try;
  `/mesh-addresses/<n>` (five digits) names the service holding `127.77.<n/256>.<n%256>`, and when
  it was released. Both are written by the API in the apply's (or delete's) own transaction, each
  compared at the revision read, so two creates that race for one number cannot both commit: one
  fails its compare and is planned again (ZC-E0105 after three tries, as every apply).
- **The address is given when the service is first written** and kept in the service record
  (`mesh_address`). A service written before C4 has none and gets one the next time it is applied,
  even when nothing else changed: that apply writes (generation unchanged) instead of answering
  `none`.
- **Creates serialize on the counter.** Every create (and the first apply of a pre-C4 service)
  compares `/mesh-address-next`, so creates of different services at the same moment conflict;
  each is planned again, and under enough of them one ends in `409` ZC-E0105 although nobody
  touched its service. Nothing was written, and the client retries. Accepted: creates are rare
  next to every other write, and one counter keeps allocation a plain compare-and-set. docs/api.md
  (`POST /v1/apply`) says so to clients. (Review SHOULD 7, 2026-11-14.)
- **Reuse.** Before the counter wraps (65,534 creates), every number is new. After, a number is
  taken only if no hold names it, or its hold was released at least `mesh_address_quarantine_ms`
  (24 hours, the decision-retention window) ago and no `/replicas/<old>/` record and no
  `/observed/<node>/<old>-<n>` key remains. The `/observed/` keys are read once per create, and
  the replica is taken from the key, so a record whose value does not decode holds back only its
  own service's address (it used to block every reuse, and re-reading `/observed/` per probe could
  fill the request arena). A hold that does not read (ZC-E0301, or a newer version) counts as
  held: the delete of its service still succeeds and leaves it alone, and creates probe past it.
- **Probes.** At most `mesh_address_probes_max` (`store_list_limit_max`, 500) numbers are tried
  per create: the first 250 in order from the counter, the other 250 spread over the whole block,
  one every 261 (`mesh_address.probe_number`), all distinct. Then the create is refused with
  ZC-E0207, the store's "no capacity" code, cause "127.77.0.0/16 has no free address" (no new
  code: supervisor). With probes only in order, a run of 500 held numbers after the counter
  refused every create while about 65,000 were free, since a refused create does not move the
  counter (review SHOULD 3); the spread probes find a free number anywhere in the block, and the
  counter moves past the one taken.
- **A hold names the incarnation it was released from** (TLA+ finding 9, zigcube-tla PR #3,
  `M6_ExhaustedMeansFull`). Keyed by name alone, a service deleted and applied again kept its old
  address held for as long as the new one ran replicas, and enough such holds refused creates
  with ZC-E0207 while the block was not full. The delete now records `replicas_below`, the
  service's replica counter (`/replica-numbers/<service>`, never deleted or reset, so numbers are
  never reused across incarnations; a C0 service's `next_replica` where the counter is absent),
  compared at the revision read; only replicas numbered below it hold the address back. The
  counter was chosen over the service's create revision because it also identifies the
  incarnation of an `/observed/` key, which names a replica, not a revision. The field is
  optional and the hold stays version 1: the hold is new in this unreleased slice, and a hold
  without it counts every replica of the name, as before. Known edge: a replica of the old
  incarnation that an agent still reports after the name is applied again keeps the old address
  held until it is gone, which is correct. Separately, ZC-E0207 now moves the counter past the
  250 numbers it tried in order (its own compared write), so creates are not refused at one place
  forever.
- **The reuse check takes no compare on `/replicas/` or `/observed/`** (review SHOULD 9). The
  store compares single keys, not the absence of every key under a prefix, so the apply cannot
  guard "no replica record appeared since I looked". Nor does it need to: the hold is released by
  the delete of its service, after which nothing creates `/replicas/<old>/` (the replica
  controller makes replicas only of services that exist), and an agent still running an old
  replica has been fenced for far longer than its lease (seconds) by the end of the 24-hour
  quarantine, so it stopped that replica long before. The read is a last check behind the
  quarantine, not the guard itself.
- **Records are written at the oldest version that holds their members**, and every C4 service
  has an address, so every service the API writes is version 5. A server older than C4 refuses
  them (ZC-E0303): **downgrading the server past C4 after its first create is not supported**, as
  with earlier record bumps. This belongs in the release notes.
- **Old records are proven by a capture where one exists.** Services at version 3 and
  observations at version 2 are the newest any build's API or agent wrote before C4, and the
  real capture `src/testdata/b3_store.txt` reads with no mesh address, grants or endpoint. Service
  version 4 and observed version 3 (C3 slice 5) have no capture: at `3c5df94` neither the apply
  API nor the agent writes them, so their test is hand-written until a C3 build writes them
  (review SHOULD 8, cut and recorded here).
- **Rollback and history (for C3 slice 8).** A rollback rewrites `/services/<name>` from a
  `/history/` record. `/history/` does not hold `mesh_address` or `allow`, so the rollback must
  keep both from the current service: a rollback that drops `mesh_address` would assign a new one
  (or leave the hold orphaned), and one that drops `allow` silently revokes grants. `allow` is not
  part of a generation, so `/service-history` does not record it; who changed grants is in the
  `grant` decisions.
- **Services with no address (written before C4).** Slice 1 assigns one on the next apply of the
  service. A service that is never re-applied keeps none until the backfill, which belongs to
  slice 4. Until then slice 2's `mesh_plan` treats a service without `mesh_address` as having no
  mesh: grants to or from it are not planned, with a one-line reason the API can show (such as
  "db has no mesh address yet: apply it again").
- **`service_allow_max` is 64**, refused with ZC-E0135 and a cause naming the bound.
- **A change to `allow` alone keeps the generation** and is recorded as a `grant` decision whose
  change names each grant added and removed (`web → 5432 added`). `allow` is a set: a reorder
  alone is no change (no write, no decision; review MUST 1, where it reached the decision with
  nothing to name and the assertion took the server down).
- **ZC-W0704** (a grant names a service that does not exist) is registered here and raised by
  the API from slice 9 (supervisor, 2026-11-14), consistent with slice 2's decision.

Where: `docs/keys.md` ("Mesh addresses", "Version 5"), `docs/authority.md` §2, `docs/api.md`
(`POST /v1/apply`), `src/mesh_address.zig`.

*Amended 2026-11-14 by the slice 1 review fixes: serialization, reuse reads, probes, the reuse
check's compares, `allow` as a set, ZC-W0704's slice, the pre-C4 capture, rollback, holds by
incarnation and a refusal that moves the counter (TLA+ finding 9).*
