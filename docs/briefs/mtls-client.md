# mTLS client: X.509 from the cluster CA and a TLS 1.3 client that presents it

*Brief written 2026-11-04 for the implementer sessions that follow. Slice 0 is this file; nothing
else is built yet. Source: the owner's B3 section (`docs/briefs/botpike-first-customer.md` on
branch `claude/focused-noether-d3npid`), `docs/peer.md` and
`docs/decisions/2026-11-03-peer-handshake-and-ca.md`.*

## Goal

The relay (B2) must prove to a stock TLS upstream, a JVM service, which workload is calling. It
does so as a TLS 1.3 **client** presenting an X.509 certificate, issued by the cluster CA, that
carries the workload's identity. This work builds the two halves that need no controller,
scheduler or store change: an X.509 writer and strict parser, and a TLS 1.3 client that can answer
`certificate_request`.

Why in-house: Zig 0.17's `std.crypto.tls.Client` names `certificate_request` and never answers it;
`std.crypto.Certificate` parses X.509 and cannot write it (`docs/peer.md:4`). Std only, no libc, no
third-party code. **Before any slice relies on a std API, it reads the pinned source** (`zig env`,
`.lib_dir`); what this brief says about std was read on 2026-11-04 and is a starting point.

The work is "wholly independent" (owner): no `Store`, `Runtime` or key-layout change, so HANDOFF's
Ask-first list is not touched. The owner assigned it outside C0 and C1, which that list also
names; this brief is the record of that assignment.

## Scope

### 1. X.509 v3 (DER), Ed25519 only

A writer and a matching parser, both bounded, for three certificate kinds:

| Kind | Subject CN | Key usage | EKU | Basic constraints |
| --- | --- | --- | --- | --- |
| CA (self-signed) | `zcube-ca-<16 hex of ca_key_id>` | keyCertSign (critical) | none | CA:TRUE, pathLen 0 (critical) |
| Workload leaf (client) | the job name | digitalSignature (critical) | clientAuth | CA:FALSE |
| Server leaf (for tests and, later, B6) | the DNS name | digitalSignature (critical) | serverAuth | CA:FALSE |

- **Algorithm.** Ed25519 (OID 1.3.101.112, parameters absent) in `signatureAlgorithm`, in the
  TBSCertificate's copy, and as the subject key. Nothing else is parsed: RSA, ECDSA, Ed448 and
  every other OID are refused, so the parser needs no big-number code.
- **SPIFFE ID.** One `uniformResourceIdentifier` in the subjectAltName of a workload leaf:
  `spiffe://<cluster>/job/<name>`. `<cluster>` is a lowercase DNS label sequence, `<name>` the job
  name (the job-name charset B1 fixes; until B1 lands, a hostname label). Exactly one URI, no
  port, no userinfo, no query, no fragment, no empty or dot path segments. A server leaf carries
  one `dNSName` instead (exact match, no wildcard).
- **Private extension** (non-critical, so a stock stack that does not know it still accepts the
  certificate; JDK and OpenSSL both refuse unknown *critical* extensions). OID under the
  UUID-derived arc `2.25.192541954756406065736426278304158759968` (Q4). Value is a DER SEQUENCE:
  `{ version INTEGER (1), image_digest OCTET STRING (32, the BLAKE3 tree digest), placement_epoch
  INTEGER (0..2^63-1), labels SEQUENCE OF SEQUENCE { key UTF8String, value UTF8String } }`.
  Labels are sorted by key, keys unique. This is C4's identity: service or job, image digest,
  placement epoch (docs/decisions/2026-10-27-c4-workload-identity-binds-service-image.md), plus
  B3's labels.
- **Serial.** 16 bytes, top bit clear: the first 16 bytes of SHA-256 of subject key and
  `not_before`, so the writer needs no randomness and the output is deterministic.
- **Validity.** UTCTime to 2049, GeneralizedTime after (RFC 5280 §4.1.2.5), whole seconds, from
  the caller's wall clock in Unix ms. A leaf lives at most `x509_leaf_ttl_ms_max`; B3 sets it to
  the job's `deadline_ms` plus a small constant.
- **The same CA key.** The CA signs the 185-byte credential (`"zcube-peer-cred-v1" 0x00 || bytes`)
  and now X.509 TBS bytes (DER, always starting `0x30`). The prefixes make the two messages
  disjoint; a test asserts a credential's signed message can never parse as a TBS and the reverse,
  and a decision file records the argument. The existing credential format is **unchanged**.
- **Strict parser.** Refuses: any non-DER encoding (indefinite or non-minimal length, BER
  booleans, non-minimal integers, trailing bytes), version other than v3, an algorithm OID that
  differs between the two places, issuer or subject unique IDs, any unknown *critical* extension,
  a duplicated extension, a SAN that is not exactly the shape above, a negative or oversized
  serial, `not_after <= not_before`, a lifetime over the kind's bound, and a certificate over
  `x509_cert_bytes_max`. It returns offsets into the input, copies nothing, allocates nothing, and
  has no recursion (an explicit depth counter; DER nesting here is at most 6 deep).
- **Verification** is a separate function: signature by the pinned CA key (ZC-E0810), validity
  window with `peer_clock_skew_ms` (ZC-E0811), issuer byte-equal to the CA's subject, CA flag and
  key usage as the kind requires, EKU matches the use, name matches when the caller named one
  (ZC-E0812). Order: parse, signature, then window and names, as `peer.zig` does, so a forged
  certificate never reaches an expiry message.

### 2. TLS 1.3 client with client-certificate authentication

- **Versions and algorithms.** TLS 1.3 only. One group, x25519. One signature scheme,
  `ed25519` (0x0807), for `signature_algorithms` and `signature_algorithms_cert`. Cipher suite
  `TLS_AES_128_GCM_SHA256` (0x1301) **only** (Q2: no ChaCha20-Poly1305; JDK 15+ and OpenSSL both do AES-128-GCM).
- **Never offered, never accepted:** TLS 1.2 or older, session resumption (no `pre_shared_key`,
  no `psk_key_exchange_modes`; a `NewSessionTicket` is read and discarded), 0-RTT (no
  `early_data`), compression, renegotiation, other groups. A `HelloRetryRequest` is refused: the
  only group offered is the one already sent (ZC-E0818). The ClientHello is fixed in layout, so
  its size is a constant.
- **Server authentication.** The chain is `Certificate` with one server leaf, optionally followed
  by the CA certificate (ignored if present; the pinned copy is the only trust anchor). Verified:
  leaf signed by the **one pinned CA key**, window, EKU serverAuth, name against the caller's
  expected DNS name or SPIFFE ID, `CertificateVerify` over the transcript with the context string
  `"TLS 1.3, server CertificateVerify"`, then `Finished`. A chain longer than 2, any intermediate,
  or a leaf signed by anyone else is refused (ZC-E0810).
- **Client authentication.** On `certificate_request` the client echoes the context, checks the
  request lists `ed25519`, and sends `Certificate` (workload leaf, CA certificate optional),
  `CertificateVerify` (`"TLS 1.3, client CertificateVerify"`) and `Finished`. The signing key is
  held by the caller as a `std.crypto.sign.Ed25519.KeyPair` (or a sign callback, so the relay can
  keep the key behind its own boundary: the callback form is the core's contract, the key pair
  form is a convenience). If the server sends no `certificate_request` and the caller required
  client authentication, the handshake fails (ZC-E0814): a relay must know its identity was
  asked for. The caller may pass no identity (server authentication only); the interop tests use
  it to produce "no certificate at all", and an empty `Certificate` is sent if one is requested.
- **After the handshake.** Application data both ways; `KeyUpdate` received and answered;
  `close_notify` sent and received; a close without `close_notify` is a truncation (ZC-E0816),
  never a clean end. A record-per-key limit forces a client `KeyUpdate` well before the AES-GCM
  bound. Alerts received are reported by name.
- **Streaming.** The record layer decrypts one record at a time and hands over its plaintext as
  soon as the record is complete; it never waits to fill a caller buffer or reads ahead for more
  than the record it needs. Writes seal and flush per call, with an explicit `flush` only to
  batch. This is what server-sent events need: an event of 40 bytes sent alone by the server is
  readable at once, and the connection stays open for hours (a `KeyUpdate` falls inside that).
- **Randomness and time.** The core has none. The shell passes the 32-byte client random, the
  32-byte session-id, the x25519 secret and the wall clock; Ed25519 signing is deterministic.
  This keeps the state machine a pure function of its inputs, so a fuzzer and a simulation can
  drive it from a seed.

### 3. Bounds and diagnostics

Every bound is a named constant in `src/constants.zig` with a `comptime` assertion relating it to
the others (STYLE). Proposed, to be confirmed or tuned in slice 1:

| Constant | Value | Why |
| --- | --- | --- |
| `x509_cert_bytes_max` | 1024 | CA 250 B, leaf with 16 labels fits; one record carries a flight |
| `x509_labels_max`, `x509_label_key_bytes_max`, `x509_label_value_bytes_max` | 16, 63, 256 | match B1's label limits; slice 1 reads B1 and aligns |
| `x509_leaf_ttl_ms_max` | 7 days | the job deadline bound; fails closed |
| `x509_ca_ttl_ms_max` | 10 years | the CA certificate outlives `--new-ca` anyway |
| `tls_record_plaintext_bytes_max` | 16384 | RFC 8446 §5.1 |
| `tls_record_ciphertext_bytes_max` | 16384 + 256 | RFC 8446 §5.2; larger is `record_overflow` |
| `tls_handshake_message_bytes_max` | 4096 | the server flight is a chain of at most 2 |
| `tls_handshake_flight_bytes_max` | 8192 | sum of the server's handshake messages |
| `tls_handshake_timeout_ms` | 10 000 | one deadline for the whole handshake, enforced by the shell |
| `tls_records_per_key_max` | 2^24 | a `KeyUpdate` is sent here; the AES-GCM bound is far higher |
| `tls_key_updates_per_connection_max` | 2^16 | a peer that updates without end is refused |
| `tls_alert_wait_records_max` | 4 | records read looking for `close_notify` |

Every refusal is a `Diag` with a cause and a fix (DIAGNOSTICS.md). New codes in the 08xx trust
group, registered in `src/diag/codes.zig`, each with a golden, an error page and a long
explanation. E0801 to E0808 are the peer handshake's; these start at E0809 (slice 1 confirms
nothing has taken them):

| Code | Blame | Refused because |
| --- | --- | --- |
| E0809 | external | a certificate is malformed or outside the bounds (the parser's every refusal, with the field named) |
| E0810 | external | a certificate is not signed by the pinned CA, or its chain is longer than the pinned shape |
| E0811 | external | a certificate is expired or not yet valid |
| E0812 | external | the server's certificate names another server than the one asked for |
| E0813 | external | the TLS handshake failed: malformed or out-of-order message, bad `CertificateVerify` or `Finished`, unsupported suite or version, an alert from the server (named) |
| E0814 | external | the server did not ask for a client certificate, or refused ours (`bad_certificate`, `certificate_expired`, `unknown_ca`, `certificate_required`) |
| E0815 | external | a record failed authentication, was oversized, or a direction reached its counter limit |
| E0816 | external | the connection ended without `close_notify` |
| E0817 | user | an identity could not be issued: too many or too long labels, a bad SPIFFE name, a lifetime over the bound, a CA key that does not match |
| E0818 | external | the server answered with something this client never offers (HelloRetryRequest, TLS 1.2, another suite or group) |

A `ZC-B` code is used only for our own broken invariant. Alerts the client sends map to the same
causes (`bad_certificate`, `decrypt_error`, `illegal_parameter`, `unexpected_message`,
`record_overflow`), and the diagnostic shows both.

## Where each piece goes: core or shell

The rule is in `docs/wasm.md` and `src/core.zig`: no threads, sockets, files, libc, `std.Io` value,
real clock, randomness or blocking call in the core. `peer.zig` already does Ed25519, X25519 and
AES-GCM in the core, so the crypto is wasm-clean.

| File | Side | wasm-clean | What |
| --- | --- | --- | --- |
| `src/x509.zig` | core | yes | DER writer, strict parser, verification of a certificate against a CA key. No allocation: writes into a caller's buffer, parses by offsets |
| `src/x509_identity.zig` | core | yes | the private extension and the SPIFFE ID: encode, decode, bounds (kept apart so B3 can import it without the TLS code) |
| `src/peer_ca.zig` (extended) | core | yes | `issue_ca_certificate`, `issue_workload_certificate`, `issue_server_certificate` beside the existing `issue`. No new key |
| `src/tls_schedule.zig` | core | yes | HKDF-Expand-Label, key schedule, transcript hash, record seal and open, nonce and counters |
| `src/tls_client.zig` | core | yes | the handshake and `KeyUpdate` state machine: bytes in, bytes out, an `Event` per step, a `Diag` per refusal. No sockets |
| `src/tls_conn.zig` | shell | no | a connected socket, deadlines by `poll` (never a blocking read; REVIEW.md), the wall clock, the random bytes; the streaming reader and writer the relay uses |
| `src/tls_testpeer.zig` | test only | yes (tests) | a scripted TLS 1.3 *server* for the core's own tests: deterministic, derived from `tls_schedule.zig`, never built into a shipped binary, refuses to be reached from a non-test root. **It is not the TLS server B6 needs**; tidy checks it is imported only from test roots |
| `src/x509_fuzz.zig`, `src/tls_fuzz.zig` | test roots | yes | the fuzzers (below) |
| `src/mtls_interop.zig` | shell | no | the stock-server harness (below) |

The CA certificate is a file beside `ca.key` in the server's state directory (`ca-<hash>.crt`,
same permission rule and ZC-E0806), never a store key. No `Store`, `Runtime` or key-layout
change. New core modules join `src/core.zig`, `src/wasm_core.zig` and `tools/wasm_check.mjs` as
slice 8's last step; until then each slice proves its own module with `zig build wasm-test`.

## Interop acceptance

The harness is `zig build mtls-interop` (shell, in Zig as STYLE requires). It issues a CA, a
server certificate and workload certificates with the code under test, starts a stock server,
connects with the new client, and asserts the outcome by code and message, not just exit status.
Not part of `zig build check` (it needs OpenSSL and a JDK, and takes seconds); CI runs it in a job
of its own, with the JDK installed there. It is an interop check, never called a demo.

**Stock servers.**

- `openssl s_server -tls1_3 -Verify 1 -verify_return_error -CAfile <ca.pem> -cert … -key …`
  (OpenSSL 3.0.13 here; supports Ed25519 in TLS 1.3).
- A JVM server: a ~60-line `SSLServerSocket` program with `needClientAuth` and a trust store
  holding the CA certificate, run with the container's JDK 21 (`java Server.java`, no build).
  **The JVM server is JDK 21**, because Botpike's broker runs on JVM 21 (supervisor, 2026-11-04);
  JDK 21 does Ed25519 in TLS 1.3 in both directions. Where the test gets it: this container has
  `openjdk 21.0.12` with `javac` and `keytool` (checked 2026-11-04), found as `java` on PATH or by
  `ZCUBE_JAVA_HOME`. The harness runs `java -version` first and **fails, not skips**, if the major
  version is not 21 (ZC diagnostic from the harness, naming the version found). CI gets it from
  `actions/setup-java` pinned to Temurin 21 (GitHub's Ubuntu images also carry it as
  `JAVA_HOME_21_X64`); slice 7 verifies which the runner uses. The Java file is test tooling, not
  product (Q3).

**Accepted, with the identity read back** (both servers):

- The handshake completes and application bytes flow both ways.
- The server reads from the client certificate, exactly: the SPIFFE URI SAN
  `spiffe://<cluster>/job/<name>`, and the private extension's digest, epoch and every label. The
  JVM reads them with `X509Certificate.getSubjectAlternativeNames()` and `getExtensionValue(oid)`;
  OpenSSL's side by `openssl x509 -text` on the certificate `s_server` prints (confirmed in slice 7).
  The harness decodes the extension with an independent decoder (the Java one), not ours.
- Format-only checks need no TLS and land in slice 1: `openssl x509 -text`, `openssl verify
  -CAfile`, `keytool -printcert` and `CertificateFactory` each accept every certificate the writer
  makes and show the fields; a table of near-miss certificates is refused by the strict parser.

**Refused by the stock server** (and the client's diagnostic is asserted: the server's alert is
reported as ZC-E0814 with the alert named):

- a workload certificate from another CA;
- an expired certificate (`not_after` in the past, by the real clock);
- a certificate for another job, when the server's expected name differs (the Java server checks
  the SPIFFE ID against an allow-list; this tests the format, not Botpike);
- no certificate at all (client with no identity).

**Refused by the client:**

- a server chain not signed by the pinned CA (a second CA's server certificate, from both stock
  servers);
- an expired server certificate; a server certificate for another name; a server that does not
  request a client certificate when one is required; a server `CertificateVerify` or `Finished`
  that is wrong (test peer); a downgrade to TLS 1.2 (OpenSSL with `-tls1_2`); a `HelloRetryRequest`
  (test peer); truncation without `close_notify`.

**Streaming.** A stock server sends server-sent events: 20 events 100 ms apart. The client's
reader returns each event within one `poll` wakeup of its arrival (asserted by arrival order and
by a read that was already pending), never held for the next. A second run lasts long enough to
cross a `KeyUpdate` (the test peer, and `openssl s_server`'s `-key_update` hook if the build has
it; otherwise the test peer alone, stated in the report).

## Fuzzers

All are seeded, print their seed first, replay with `ZCUBE_FUZZ_SEED=<seed> zig build test`, and
are imported from `src/tests.zig` like `peer_fuzz.zig`, so `zig build test`, `zig build check`,
CI and (for the core files) `zig build wasm-test` run them. A failure first gets a fixed-seed
regression test.

- **`x509_fuzz.zig`.** Random bytes; every valid certificate with one byte replaced, one bit
  flipped, a length field grown or shrunk, a TLV inserted or truncated, a sequence reordered.
  Properties: no crash, no allocation, bounded steps; a mutated *signed region* never verifies
  under the CA key; a certificate the parser accepts re-encodes to the same bytes (writer and
  parser are inverses on the accepted set); the independent oracle (a second, naive decoder inside
  the test, allowed compound conditions per STYLE) agrees on accept or refuse.
- **`tls_fuzz.zig`.** Drives `tls_client.zig` against `tls_testpeer.zig` under a seed that chooses
  the flight's mutations: reordered, duplicated, dropped or truncated handshake messages;
  fragmentation of messages across records and of records across reads at every split point;
  random bytes in each field; a wrong transcript; replayed records; a record sequence number off
  by one; overlong records; alerts at every state. Properties: no crash; never `connected`
  without a verified server `Finished`; never an accepted chain that the pinned CA did not sign;
  no output bytes after a fatal alert; every refusal carries a registered code; state is
  unreachable-asserted, not defaulted.
- **Teeth.** As `sim-swarm-teeth` does: a test-only fault flag (skip the chain signature, skip
  `CertificateVerify`, skip `Finished`, skip the name check, skip the window) makes the matching
  fuzzer or table test fail on a seed in 1..10, and `zig build mtls-teeth` passes only if each
  does. Added to `zig build check`'s list in slice 8.
- **Vectors.** RFC 8448 (the 1-RTT trace) checks `tls_schedule.zig`: every derived secret, key,
  IV, and the record protection of its messages, and RFC 8032's Ed25519 vectors are std's. The
  client-auth flight has no RFC vector, so the interop harness is its authority.

## Slices

Sizes: S under a day of focused work, M a day or two, L three or more. One session per slice
(AGENTS.md); each ends with `zig build check` on the reported commit, REVIEW.md run on its own
diff, and a handoff note. Briefs for slices 1 and later are derived from this file, as c2.md's
were. The branch is `claude/mtls-client`; nothing is pushed anywhere else.

| # | Slice | Size | Mechanical parts (Haiku, given the exact pattern) |
| --- | --- | --- | --- |
| 1 | `x509.zig`, `x509_identity.zig`: writer, strict parser, verification; constants; ZC-E0809 to E0812 and E0817; `x509_fuzz.zig`; format checks against `openssl x509`, `openssl verify`, `keytool`, `CertificateFactory`; table of near-miss refusals | M | goldens, `site/errors/` pages, `core.zig` listing, the constants' doc comments from the table above |
| 2 | CA integration: `peer_ca.zig` issues CA, workload and server certificates from the existing key; `ca-<hash>.crt` written with the key's permission rule; `docs/peer.md` section; the decision file for the shared CA key and message disjointness; credential format untouched (its tests prove it) | S | the `peer.md` text from the decision file |
| 3 | `tls_schedule.zig`: HKDF-Expand-Label, key schedule, transcript, AES-128-GCM record seal and open, counters and `KeyUpdate`; RFC 8448 vectors | M | none; the vectors are copied by pattern into a table (Haiku may transcribe them, the supervisor checks the hex) |
| 4 | `tls_client.zig` part 1: `ClientHello` through server `Finished` and client `Finished`, no client auth; server-chain pinning and name check; `tls_testpeer.zig`; the refusals above for the server's flight; `tls_fuzz.zig` for this part; ZC-E0813, E0815, E0816, E0818 | M | goldens and error pages |
| 5 | `tls_client.zig` part 2: `certificate_request`, client `Certificate`, `CertificateVerify`, `Finished`; required-or-optional client authentication; sign callback; `KeyUpdate` both ways; `close_notify`; fuzzer extended to the whole state machine; ZC-E0814 | M | goldens and error pages |
| 6 | `tls_conn.zig`: sockets, `poll` deadlines, handshake timeout, wall clock and random from the shell, streaming reader and writer, `flush`; loopback tests against the test peer, including the SSE pattern and a cut at every handshake byte | M | none |
| 7 | `mtls_interop.zig`, `zig build mtls-interop`, the Java server source, the stock-server cases above, a CI job and its `ci-changes.sh` rule and table-test row | L | the CI job and the `ci-changes.sh` row |
| 8 | Wiring and docs: `wasm_core.zig`, `tools/wasm_check.mjs`, `zig build mtls-teeth` and its place in `check`, `docs/mtls.md` (the format, the handshake as a state diagram, the constants), README and `site/index.html` status | S | the status updates; the `check` line text |

Slices 1 and 3 share nothing and can run in parallel in separate worktrees (each with its own
`ZIG_GLOBAL_CACHE_DIR`; AGENTS.md "Disk"). Slice 4 needs 1 (verification) and 3; slice 5 needs 4;
slice 2 needs only 1; slice 6 needs 5; slice 7 needs 2 and 6.

## Out of scope

- The TLS **server**, and the API's mTLS (B6). `tls_testpeer.zig` exists for tests and is not a
  server a binary may link.
- The relay itself (B2): its listener, its policy, its connection handling.
- Job objects, labels' storage and the deadline (B1); this work takes labels and a lifetime as
  arguments.
- Wiring issuance into the control plane or the agent: no API endpoint, no store key, no CLI
  command. B3 calls `peer_ca.issue_workload_certificate`.
- Revocation beyond the short lifetime (B3's bounded-time cancel is the relay's).
- Session resumption, 0-RTT, TLS 1.2, other groups, other signature schemes, RSA or ECDSA chains,
  intermediates, OCSP, CRLs, name constraints, wildcard names.
- Changing the 185-byte peer credential, the peer handshake or `docs/peer.md`'s rules, except the
  one added section.
- Any change to `Store`, `Runtime`, key layout or the controllers.
- Replacing the peer handshake with this TLS (the "eventual target" in `docs/peer.md` is a later
  decision).

## Answers (supervisor, 2026-11-04)

- **Q1. Server chains.** The client takes ONE pinned trust anchor: an Ed25519 CA public key
  chosen by the caller. It is the cluster CA by default, and a relay's upstream may pin its own
  anchor in cluster configuration. Only Ed25519 server leaves signed directly by that anchor are
  accepted; there is no public-CA, RSA or ECDSA support. Botpike's broker will present an Ed25519
  certificate on the relay port; JDK 21 can serve one. Botpike confirmed this contract (owner,
  2026-11-04). The client API names the parameter `anchor`, not "cluster CA".
- **Q2. ChaCha20-Poly1305.** No.
- **Q3. External programs.** Approved, test-only. The owner's B3 acceptance requires a stock JVM
  server, which is the spec naming the programs. Slice 7 records this in a decision file:
  `openssl` and `java` run in the interop harness and its CI job only, never in a shipped binary.
- **Q4. The private extension's OID.** The `2.25.<UUID>` arc. The UUID was generated once, in
  slice 1: `90da3b4b-8df9-4f57-9af3-d569aaf6bc20`, so the OID is
  `2.25.192541954756406065736426278304158759968`.
  `docs/decisions/2026-11-04-mtls-identity-extension-oid.md` records it.
- **Q5. Server name form.** Support both forms, as written. Botpike's broker has a DNS name
  (`broker.botpike.com`).
- **Q6. Core or shell for the state machine.** Core, as recommended.
- **Q7. Who holds the leaf key.** B3's to decide; out of scope here. The interface stays as
  written: a public key to certify, and a sign callback.
- **Q8. Live design doc.** Slice 1 read Zigbox `docs/SPEC.md` Part II C4 and the identity and
  trust lines of C6 (snapshot `a2ff703`). Nothing is resolved here or in code; the owner decides.
  The first list was lost with the slice 1 session's context, so this one was re-derived on
  2026-11-04 by re-reading the snapshot against this brief and the slice 1 code. It may miss
  something the first list had.
  1. **mTLS or WireGuard identity.** SPEC C4 scope: "mutual TLS between workloads (or
     WireGuard-level identity, decided at C4 start)", and the Open question "Workload identity at
     C4: mTLS per connection, or identity carried at the WireGuard layer?" is unchecked. The
     brief and `x509_identity.zig` fix X.509 with a private extension as the identity format now.
     Building it before C4 starts settles a decision the SPEC leaves open.
  2. **Reuse proven libraries.** SPEC risk table, "Identity and mTLS design is easy to get subtly
     wrong" (C4, C6): "Reuse proven libraries and an existing identity format such as SPIFFE IDs;
     external review before C6". SPEC also says "Lean on the standard library first" (std covers
     "a TLS client") and to add a dependency only with a written reason. The brief writes the
     X.509 writer, strict parser and TLS client in-house, on std only, because std's TLS client
     cannot answer `certificate_request` (first section of this brief). It does use SPIFFE IDs,
     but the digest, epoch and labels are a private extension, not a SPIFFE feature. The brief
     schedules no external review.
  3. **Service or job.** SPEC C4: identity is "bound to service name, image digest and placement
     epoch". The brief's SPIFFE ID is `spiffe://<cluster>/job/<name>`, with `<name>` the job
     name under B1's charset, and the extension comment says "service or job". Whether C4's
     service name maps onto `/job/<name>`, or needs another path form, is not settled. The
     label charset in code is provisional for the same reason.
  4. **Identity bound to a signed digest.** SPEC C4 acceptance: "A workload's identity changes
     when its digest changes, so a grant can be scoped to signed versions". The extension holds
     a 32-byte BLAKE3 tree digest only. Nothing in the format says whether it is a signed
     version, and the SPEC's C6 signing (ed25519 `zbx sign`) is not referenced by this work.
