# Agent: a container is adopted only if its zcube.image and zcube.created (the replica key's create revision) labels match the replica; a mismatch (an earlier replica with the same id, after delete and re-apply) is stopped and, once stopped, replaced

*Decided 2026-10-31.*

Agent: a container is adopted only if its `zcube.image` and `zcube.created` (the replica key's create revision) labels match the replica; a mismatch (an earlier replica with the same id, after delete and re-apply) is stopped and, once stopped, replaced. A container without the labels is not the replica's either and is replaced (pre-release: none predates them). `zcube.created` holds a store revision, so moving or restoring the store to another backend changes create revisions and would restart every container: a known consequence for the backup work (slice 10). A stop that finished is forgotten before the replacement starts under the same name, and a late `running` record over a stopped stale container is reported `lost`. No `Runtime` or key change.

Where: `src/agent.zig`
