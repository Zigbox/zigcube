# Runtime.Spec gains `relay` (B3)

Date: 2026-11-10. Decided by: the owner.

B3 slice 2 (Zigcube #208) adds an optional `relay` field to `Runtime.Spec`, the interface HANDOFF
lists under **Ask first**. The field is additive: a spec without it runs as before. It carries the
job's resolved relay (listener and upstream) so the supervisor can hold the listener and relay for
its job, as `docs/briefs/b3.md` describes.

The owner approved the field on 2026-11-10. Its shape is still subject to the slice's review.
