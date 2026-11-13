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
- **Reuse.** Before the counter wraps (65,534 creates), every number is new. After, a number is
  taken only if no hold names it, or its hold was released at least `mesh_address_quarantine_ms`
  (24 hours, the decision-retention window) ago and no `/replicas/<old>/` record and no
  `/observed/` record of a `<old>-<n>` replica remains. An `/observed/` record that does not decode
  counts as a replica that remains. At most `mesh_address_probes_max`
  (`store_list_limit_max`, 500) numbers are tried per create; then the create is refused with
  ZC-E0207, the store's "no capacity" code, cause "127.77.0.0/16 has no free address" (no new
  code: supervisor).
- **Records are written at the oldest version that holds their members**, and every C4 service
  has an address, so every service the API writes is version 5. A server older than C4 refuses
  them (ZC-E0303): **downgrading the server past C4 after its first create is not supported**, as
  with earlier record bumps. This belongs in the release notes.
- **Services with no address (written before C4).** Slice 1 assigns one on the next apply of the
  service. A service that is never re-applied keeps none until the backfill, which belongs to
  slice 4. Until then slice 2's `mesh_plan` treats a service without `mesh_address` as having no
  mesh: grants to or from it are not planned, with a one-line reason the API can show (such as
  "db has no mesh address yet: apply it again").
- **`service_allow_max` is 64**, refused with ZC-E0135 and a cause naming the bound.
- **A change to `allow` alone keeps the generation** and is recorded as a `grant` decision whose
  change names each grant added and removed (`web → 5432 added`).

Where: `docs/keys.md` ("Mesh addresses", "Version 5"), `docs/authority.md` §2, `docs/api.md`
(`POST /v1/apply`), `src/mesh_address.zig`.
