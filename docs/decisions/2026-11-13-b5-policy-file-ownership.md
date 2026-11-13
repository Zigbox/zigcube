# B5: the server refuses a trust policy that others could rewrite

Date: 2026-11-13. Raised by review A of PR #241 (a SHOULD that needed a supervisor decision);
**decided by the supervisor under `2026-11-13-supervisor-decides-under-delegation.md`**, which
directed the fix session to make the change. No new code and no new bound.

## Decision

`zcube-server` refuses to start, with the existing ZC-E0106, when the file named by
`trust = .{ .policy = ... }` is not a regular file, is owned by neither root nor the server's
effective user, or is writable by group or others (`mode & 0o022`). The cause names the file,
what is wrong, its owner uid and its mode. The file is judged and read through one descriptor
(`statx` on it, then the read), so it cannot be swapped between the check and the read.

## Why

Zigbox refuses a system policy that is not owned by root or is group- or world-writable
(`trust/gate.zig`, "the system policy binds users who cannot write it"). Without the same rule
here, anyone who can write the file can add their own key and, at the next restart, have
`POST /v1/jobs` admit what that key signed. A server need not run as root, so its own user is
allowed as owner; anyone who is that user can already change the server.

## Consequences

An operator whose policy file is mode 0664 or 0666, or owned by a deploy user, sees the server
refuse to start after upgrading and must `chown` / `chmod go-w` it. `docs/api.md` (Signatures)
and the ZC-E0106 explanation say so. Tested in `src/server_config.zig`.
