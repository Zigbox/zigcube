# B1: how large the request that carries a job's input may be (open owner question)

*Open 2026-11-05, raised by the review of slice 1 (PR #98). Not decided: `docs/api.md` is on
HANDOFF's Ask-first list, so the owner decides. Slice 2 builds the route only after the answer; if
none comes, slice 2 follows the recommendation and says so in its report.*

## The question

The owner's answer 5 fixes the input at "at most 64 KiB of UTF-8 without NUL", sent as the
`input` field of `POST /v1/jobs`, a JSON string. The brief gives that route a body of up to
`job_request_bytes_max` (128 KiB). The slice-1 constants asserted `job_input_bytes_max <
job_request_bytes_max`, which suggests that every valid input fits. It does not: the input is
64 KiB *decoded*, and the wire form is JSON-escaped.

| Input bytes | JSON form | Growth |
|---|---|---|
| `"` and `\` | `\"` `\\` | 2x |
| control characters (`\x01`..`\x1f`, bar `\n`, `\t`, `\r`, `\b`, `\f`) | `\u00XX` | 6x |
| CJK and other 3-byte UTF-8, if the client escapes to ASCII (Python's `json.dumps` default) | `\uXXXX` | 2x |
| 4-byte UTF-8 (emoji), escaped to ASCII | surrogate pair `\uXXXX\uXXXX` | 3x |

So the largest valid input (64 KiB of control characters) is 384 KiB on the wire, and a 64 KiB
CJK input from a default Python client is about 128 KiB plus the rest of the spec, over the
limit. A valid input would be refused for a reason the owner's answer 5 does not state.

Two facts about the HTTP layer, for the options below. The body limit the server checks is
`http_body_bytes_max` (64 KiB, `server_http.zig`); a larger body is refused by the HTTP layer as
413 ZC-E0108 ("the request body is larger than 65536 bytes"), not as ZC-E0130, so any option that
refuses on size changes that cause for this route. The request arena is
`request_arena_bytes_max`, 16 MiB per connection (`constants.zig`, `server_http.zig`), not 64 KiB.

The stored form is not affected: `/job-input/<name>` holds base64 (about 88 KiB), which fits a
store value whatever the content.

## Options

**A. Keep 128 KiB and say what it means.** The limit is "64 KiB decoded, and the whole request
at most 128 KiB". Ordinary text fits. Input that escapes heavily is refused as 413 ZC-E0108 (the
HTTP layer's own refusal; its cause must name the job route's limit), and `docs/api.md` says so. Cheapest; the stated limit is not exactly
true, and a client can only learn it by being refused.

**A2. Size the route for the escaping real clients produce.** The route's limit becomes 2x the
input plus the spec (about 144 KiB), which covers quotes, backslashes and CJK from a client that
escapes to ASCII. Only the 6x case (control characters) is refused, with ZC-E0130 naming the
input (the route's handler can say what the HTTP layer cannot). Between A and B: the stated limit
is true for any text a person writes, and false only for binary-looking input.

**B. Size the route for the worst case.** The route's body limit becomes
`6 * job_input_bytes_max + 16 KiB` (400 KiB), so every valid input is accepted whatever it
contains, and the "64 KiB" limit is exactly true. The body is 2.4% of a
16 MiB request arena, and the budget already allows 96 connections (`http_connections_max`) of
16 MiB each, so the extra memory is small (up to 38 MB if every connection holds one such body
at once). Slice 2 must check the arena asserts either way (the brief says so).

**C. A separate request for the input.** `POST /v1/jobs` carries the spec; the input goes in
`PUT /v1/jobs/{name}/input` as raw bytes (`application/octet-stream`, 64 KiB exactly, no
escaping). The job would have to wait in a state that is not yet schedulable until the input
arrives, which adds a state, a failure (the PUT never comes) and a timeout. It also changes the
shape answer 5 gave (`input` field), so it is the largest change.

**D. An additive `input_base64` field.** Base64 has a fixed 4/3 growth, so 64 KiB is 88 KiB on
the wire and fits 128 KiB with the spec. The client encodes. Additive, so it can follow A later.
It is a second way to say the same thing, and the owner chose the `input` string.

## Recommendation

**B** if the HTTP layer can take 400 KiB on one route (slice 2 measures: the request arena and
`http_body_bytes_max`; the arena is not the constraint), because it makes the limit the owner
stated true with no new concept. If it cannot, **A2**, or **A** with D added later as a plain
field if a client needs it. C is not worth its state machine for 64 KiB. The owner decides.

## What slice 1 did

It removed the assert and wrote no relation between the two constants. `job_request_bytes_max`
stays 128 KiB until the owner answers; the stored record is unaffected.

Where: `src/constants.zig` (jobs block), `docs/briefs/b1.md` ("Input"), `docs/api.md` (slice 2).
