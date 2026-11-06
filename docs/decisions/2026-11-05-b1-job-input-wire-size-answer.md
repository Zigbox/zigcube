# B1: the job route accepts every valid input (option B)

*Decided 2026-11-05, by the owner.* Answers the open question in
`2026-11-05-b1-job-input-wire-size.md`, which stays as the record of the options.

## Decision

**B.** `POST /v1/jobs` accepts a body of up to `6 * job_input_bytes_max + 16 KiB` (400 KiB), so
every input that meets answer 5 (at most 64 KiB of UTF-8 without NUL, decoded) is accepted however
the client escapes it, and the stated 64 KiB limit is exactly true. The limit applies to this route
only; every other route keeps `http_body_bytes_max` (64 KiB).

## What slice 2 does

- Sets `job_request_bytes_max` to the figure above and lets the job route, alone, read a body that
  large. A body over it is still refused by the HTTP layer as 413 ZC-E0108, whose cause names the
  job route's limit.
- Measures that the HTTP layer can take it: the 16 MiB request arena (`request_arena_bytes_max`)
  is not expected to be the constraint, and the arena asserts must still hold.
- Tests the worst case: a 64 KiB input of control characters (about 384 KiB on the wire) is
  accepted and stored, and one byte more of decoded input is refused with ZC-E0130.
- Updates `docs/api.md`.

If the HTTP layer cannot take it, slice 2 stops and reports; the fallback the owner was offered is
A2 (about 144 KiB, refusing only control-character-heavy input), which needs the owner's word.
