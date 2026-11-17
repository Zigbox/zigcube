# Jepsen PR `J`: split in two, `at=` for the views, and how the client classifies

*Decided 2026-11-17, by the supervisor (the split, `at=`) and the slice (the rest).*

- **The split.** PR `J` (docs/briefs/c5.md, "Jepsen on Google Cloud") is two sessions. **J1**:
  items 6 (the views), 3 (the client), 7 (its tests and the encoder's golden files) and 5 (the
  properties, with C4's grant check written as "pending C4" and no code). **J2**: items 1
  (`zig build dist`, which must include `zcube-jepsen-client`), 2 (`ops/jepsen/`) and 4 (the
  fault surfaces). One PR's worth of work did not fit one session's context.
- **`at=N`, not `?revision=N`.** `GET /v1/replicas` and `GET /v1/nodes` take `at=N`, the name
  `/v1/list` and `GET /v1/jobs` already use for "read at revision N", with the same refusals
  (`410` ZC-E0203, `400` ZC-E0204). A deviation from the brief's wording, not its meaning.
- **No new code for a cut view.** A prefix with more than `cli_list_pages_max` pages (an existing bound) is cut and
  the answer says `"truncated": true`; a checker does not judge it. No code was registered.
- **The client's verdicts.** A write that may have committed is `info`, never `fail`; a read that
  did not answer is `fail`; a refusal before any write (4xx, or 503 ZC-E0201) is `fail`; no
  connection is `fail`, since no byte was sent (`cli_http.Client.sent`). Its time is
  `CLOCK_BOOTTIME`, so a `date -s` fault on the client's host cannot reorder its own lines.
- **A separate binary.** `zcube-jepsen-client` is built only by `zig build jepsen-client`, as the
  brief asks: the shipped `zcube` does not grow.

Where: docs/jepsen.md, docs/api.md ("state at one revision").
