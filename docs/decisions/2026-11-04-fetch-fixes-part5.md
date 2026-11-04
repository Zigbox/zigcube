# Fetch and peer fixes, slice 6b pass C

Decided 2026-11-04.

- S3, S4, S6 and S7 were already met in the code (E0601, W0601 and W0602 go
  through Diag; a bad key file surfaces E0806; the peer server shows a
  refusal once per streak; `--images-dir` and `--peer-listen` are in `--help`
  and docs/agent.md). Each now has a test or a docs pointer.
- An oversize registry reply is an extra cause on E0601, not a new code: the
  reply buffer is sized for the largest tree list plus a head, and a larger
  reply is refused. A new code would need a registry entry, goldens and a page.
- The peer limiter's table-full lockout is accepted and documented in
  docs/peer.md. Any eviction policy is the owner's decision.
- A summary holds at most `summary_chunks_capacity` chunks; trees past it are
  counted in `omitted`, so the Bloom filter never saturates.
- Not done: a per-tree fetch lock and controller backoff (earlier decisions).
