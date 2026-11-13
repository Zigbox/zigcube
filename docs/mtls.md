# Certificates and mTLS

This document describes how Zigcube makes and checks its X.509 certificates. The brief is
[briefs/mtls-client.md](briefs/mtls-client.md). All eight slices are built: X.509, the CA, the key schedule, the TLS 1.3 client with client
authentication, the connection, the stock-server interop harness and, in slice 8, the wiring (the
WASM smoke, `mtls-teeth` in `check`) and this document. The rest of mTLS (the relay's listener,
issuance in the control plane) is out of scope (brief).

## Certificates

All keys are Ed25519 and all encoding is DER. The writer is deterministic, the parser is strict,
and verification checks against one pinned anchor key. The code is in `src/x509.zig`,
`src/x509_der.zig` and `src/x509_identity.zig`. It is core code: it never allocates, never
reads a clock (the wall time is an argument) and never uses a randomness source.

### Two profiles

The decision is in decisions/2026-11-04-x509-two-profiles.md.

- **`cluster`** (`x509.parse`, `verify`) covers what this cluster's CA writes.
  - There are three kinds:
    - `ca`: BasicConstraints and KeyUsage.
    - `server`: BasicConstraints, KeyUsage, ExtKeyUsage serverAuth, and a SAN with one DNS name.
    - `workload`: BasicConstraints, KeyUsage, ExtKeyUsage clientAuth, a SAN with one SPIFFE ID
      (`spiffe://<cluster>/service/<name>`), and the identity extension.
  - Each kind has its extensions in a fixed order, and its bytes are exact. The issuer's CN is
    `zcube-ca-` followed by 16 hex digits.
  - A certificate parsed and then written again gives back its exact input bytes.
- **`foreign_server`** (`x509.parse_profile(..., .foreign_server, ...)`,
  `verify_foreign_server`) covers a server leaf signed directly by an operator-pinned Ed25519
  anchor, such as one made with OpenSSL.
  - It allows any Name, a serial of up to 20 bytes, key identifiers, and extensions in any order.
  - It refuses an extension that appears twice and an unknown critical extension.
  - It requires serverAuth, a leaf (not a CA), and exactly one DNS name or SPIFFE ID.

### Validity

A certificate is valid from `not_before - 60 s` (inclusive) to `not_after + 60 s` (exclusive).

- UTCTime is used through 2049 and GeneralizedTime from 2050. The parser accepts only the
  canonical form of each, with no second 60 and no day the calendar lacks.
- A leaf's lifetime is at most 7 days. A CA's, or a foreign leaf's, is at most 10 years.
- The decision is in decisions/2026-11-04-x509-validity-boundaries.md.

### Identity labels

A label key is at most 63 bytes and a value at most 256 bytes. There are at most 16 labels, and
together they total at most 256 bytes (decisions/2026-11-04-identity-label-bytes-256.md). They
are sorted by key, with no key twice.

## Tests

- **`src/x509_test.zig`**: the writer and parser, the time rows, and the identity labels.
- **`src/x509_near_miss.zig`**: one edit away from a good cluster certificate, with the exact
  error each edit must get.
- **`src/x509_foreign_test.zig`**: the `foreign_server` profile, run against fixtures that
  `src/testdata/x509/gen.sh` made with OpenSSL.
  - The fixtures are committed, and no test runs OpenSSL.
  - Rerun the script only to change a fixture, then commit every file it writes. It makes new
    keys and dates each time.
- **`zig build x509-format`**: openssl, keytool and others read the certificates the writer
  makes. It needs those tools, so it is not in `check`.
- **`src/x509_fuzz.zig`**: mutates good certificates of all three kinds, plus the foreign
  fixtures.
  - **Cluster profile.** Every result the parser gives must agree with an independent naive
    decoder, `src/x509_oracle.zig`. That decoder has its own TLV walker and its own checks.
  - **Round trip.** An accepted certificate must write back to its exact bytes.
  - **Foreign profile.** Only the unmutated fixture verifies.

### Replaying a fuzz failure

`src/fuzz_seeds.zig` runs both `x509_fuzz.zig` and `peer_fuzz.zig`.

- Each run has a master seed, and iteration `i` uses the `i`-th SplitMix64 output of that seed.
- A failure prints two lines that replay it:

```
x509 fuzz failed at iteration 812: OracleDisagrees
  replay the run:       ZCUBE_FUZZ_SEED=… ZCUBE_FUZZ_ITERATIONS=813
  replay the iteration: ZCUBE_FUZZ_ITERATION_SEED=…
```

To run long, set `ZCUBE_FUZZ_ITERATIONS=N` and run the test binary directly. Without
`ZCUBE_FUZZ_SEED` this takes a fresh seed from the OS. The run prints its seed first and a PASS
line last:

```
ZCUBE_FUZZ_ITERATIONS=20000 .zig-cache/o/<hash>/test --test-filter "x509 fuzz" | cat
```

## The TLS 1.3 client (`tls_client.zig`)

A pure state machine: it reads no socket and no clock. The caller feeds it bytes as they arrive
(`wants()` says how many it will take; `receive` takes at most that many), and after every step
drains `output()` to the transport. The core modules `tls_client.zig` and `tls_wire.zig` are
`wasm32-freestanding`-clean; `tls_testpeer.zig`, the scripted server the tests use, is not a core
module.

What it speaks: TLS 1.3 only, `TLS_AES_128_GCM_SHA256`, x25519 and ed25519; no PSK, no 0-RTT and no
HelloRetryRequest. The server's chain is checked against the pinned CA (`x509.zig`), for the name
the caller connected to; the CertificateVerify and the server's Finished are checked against the
transcript hash before the message joins it. The handshake reassembly buffer is 8192 bytes.

`tls_conn.zig` is the shell around it (native only): a socket, a `poll` deadline on every read and
write, a handshake timeout, the wall clock and random from the shell, and a streaming `read`,
`write`, `flush` and `close`. It adds no diagnostic codes; see
`docs/decisions/2026-11-05-tls-conn.md`. Its tests run a loopback peer, the server-sent-events
pattern, a cut at every byte of the server's flight, and a record-limit crossing.

Rules the code holds to, each with a test:

- Keys never change in the middle of a record: bytes left over after the ServerHello, the server's
  Finished or a KeyUpdate are refused.
- One compatibility `change_cipher_spec` is dropped, only between the ServerHello and the end of
  the handshake, and only with the body `01`. The client sends its own before its Finished.
- A failure queues one alert (sealed if the write keys are live), wipes every secret and buffer,
  and ends the connection: `receive` then answers `error.Closed` and `output()` stays empty.
- A received KeyUpdate re-keys the receive side; one that asks is answered. `seal_application`
  puts a KeyUpdate of its own in front of the record when the write keys have reached their
  record limit (RFC 8446 section 5.5), in the same slice, so a caller sizes its buffer with
  `application_bytes_max` and needs no other step. A direction that cannot move on (the key limit
  or too many KeyUpdates) is ZC-E0815, never a silent stop. `send_key_update` rotates sooner.
- Client authentication (slice 5). `Config.client_auth` is `.none`, `.optional` or `.required`,
  the last two carrying the `Identity`: the workload's chain (at most two certificates) and a
  `Signer` (a callback that signs the CertificateVerify content and may fail). A required
  connection without an identity cannot be written down. A CertificateRequest is read once,
  after EncryptedExtensions: its `signature_algorithms` must be present, no extension type may
  occur twice, and its context (up to 255 bytes) is echoed. `certificate_authorities` is skipped,
  so a large list of names is fine until the message passes the limit below. The client answers
  with Certificate, CertificateVerify (context string "TLS 1.3, client CertificateVerify") and
  Finished, all in one flight after the server's Finished; the client's Finished covers them.
  If the request lists no Ed25519 (in `signature_algorithms` or `signature_algorithms_cert`), or
  there is no identity, an optional client sends an empty Certificate; a required one is refused
  with ZC-E0814. A request after the handshake, or a second one, is ZC-E0813. After the flight,
  an alert such as `bad_certificate` or `certificate_required` is ZC-E0814, any other alert
  ZC-E0813. If the signer returns nothing the connection ends with ZC-E0820 and an
  `internal_error` alert; the Certificate is not sent first.
- **Message limit.** The client reads a handshake message of at most 4096 bytes
  (`tls_handshake_message_bytes_max`); a longer one is ZC-E0813 and the cause names the message
  and its size. A CertificateRequest that lists many `certificate_authorities` can pass it, and a
  server of that kind is refused; raising the limit is a change to `constants.zig`.
- **Leniency in the context.** The client Certificate echoes whatever context the request
  carried, non-empty included. This is a deliberate leniency: RFC 8446 section 4.3.2 says the
  context SHALL be zero length in a request sent during the handshake, and a strict client
  would refuse it. The client accepts and echoes it so a peer that sends one still completes
  (the test peer does); the echo is what section 4.4.2 asks of a response. The server's own
  Certificate (in the first flight) must have an empty context and a non-empty one is refused.

Tests: `tls_client_test.zig` (client authentication in all piece sizes, refusals, the server's
alerts, a failing signer (ZC-E0820) and five teeth tests for it; `tls_wire_test.zig`, tables for `parse_certificate_request`; success at several piece sizes, refusals, pinning, record faults and
six teeth tests, one each for the pin, the name, the validity window, CertificateVerify, Finished
and the transcript, which fail when that check is skipped), and `tls_fuzz.zig`, a seeded fuzzer
that damages a server's flight in thirteen ways (alerts, plain and sealed, at record boundaries;
any record replayed), damages the CertificateRequest itself in a third of the runs, draws the
request's scheme lists, feeds it in random pieces, and after an intact flight runs a script of
data, KeyUpdates, tickets and alerts both ways. It checks the client's answer at the moment
of `connected`, whatever follows, and has a teeth test of its own. Tidy allows only test roots to
import `tls_testpeer.zig`. It is replayed like the others (see "Replaying a fuzz
failure").

## The handshake

```
idle --start--> wait_server_hello --ServerHello--> wait_encrypted_extensions
     --EncryptedExtensions--> wait_certificate --Certificate--> wait_certificate_verify
     --CertificateVerify--> wait_finished --server Finished-->
     (client flight: [Certificate, CertificateVerify,] Finished) --> connected
connected --close_notify (either way)--> closed
any state --refuse / fail_silently--> failed
```

`CertificateRequest` is optional and read only in `wait_certificate`, where it is a self-edge (the
state does not change). Any failure, from any state, queues at most one alert, wipes the secrets
and goes to `failed`, a sink of its own (ZC-E0813 to E0820 as the table below). `closed` is reached
only through `close_notify`. In `connected`, `KeyUpdate` re-keys one direction, and a key limit is
ZC-E0815.

## The TLS 1.3 server (`tls_server.zig`)

B7 slice 1 (`docs/briefs/b7.md`; the scope is `docs/decisions/2026-11-13-in-house-tls-server.md`).
It is a pure state machine like the client, and its interface has the same shape: `wants`,
`receive`, `output` and `drain`, `end_of_input`, `seal_application`, `send_key_update` and
`close_notify`. It shares the client's key schedule, record layer and wire code (`tls_wire.zig`
holds the parsers and writers for both sides). The shell passes in the server's random value,
its x25519 secret, the time, and the `Identity`: the server's chain and a `Signer`. It has no
socket shell yet; that comes in slice 3.

What it speaks is what the client speaks: TLS 1.3, `TLS_AES_128_GCM_SHA256`, x25519 and ed25519.
It has no HelloRetryRequest, no PSK, no tickets and no early data.

**A client certificate is always required.** Every flight carries a CertificateRequest (empty
context, `signature_algorithms` = ed25519). The chain the client sends (at most two certificates)
is verified against the CA for `Config.client_kind` (`workload` until slice 2 adds `node` and
`client`). A CA-signed certificate of another kind is ZC-E0819. An empty Certificate is ZC-E0814
with the `certificate_required` alert. `peer()` returns the verified kind and name.

**Its rules.** These are the client's, mirrored:

- The ClientHello (reassembled across records, up to the message limit) has no bytes behind it
  in its record, a non-low-order x25519 share, null compression, and no extension twice. A `pre_shared_key` must come last, and is refused, as is
  `early_data`.
- One compatibility `change_cipher_spec` (body `01`) is dropped between the server's flight and
  the client's Finished, and only between whole messages. The server sends its own after the
  ServerHello only when the client sent a session id.
- Keys never change in the middle of a record: bytes behind the client's Finished or a KeyUpdate
  are refused.
- Application data before the client's Finished is refused, not passed on.
- A KeyUpdate in either direction re-keys, and one that asks is answered. `seal_application`
  puts the KeyUpdate in front of a record when the write keys reach their limit.
- A failure queues one alert (sealed once the server's own write keys are live, after the
  ServerHello), wipes every secret, and ends the connection.

The handshake deadline and the record limits are the client's constants (table below). The shell
enforces the deadline.

```
wait_client_hello --ClientHello / server flight--> wait_certificate
     --Certificate--> wait_certificate_verify --CertificateVerify--> wait_finished
     --client Finished--> connected
connected --close_notify (either way)--> closed
any state --refuse / fail_silently--> failed
```

**Diagnostics.** A refusal raises one of the client's codes, ZC-E0810 to ZC-E0820 (ZC-E0809 for
a malformed certificate), with a cause and a fix written for the server's operator. The cause
names the client's offence. ZC-E0820 is the server's own signer failing. No code was added.

**Tests.**

- `tls_server_test.zig`:
  - the real `tls_client.Client`, with required client auth, against the server in the same
    process, in pieces of every size, with data and KeyUpdates both ways;
  - near-miss tables, a scripted client (`tls_testclient.zig`) one knob away from correct, for
    the ClientHello and for the client's flight, each with its code and alert;
  - ten teeth tests, one per security check: the chain (another CA, and a damaged
    certificate), the kind, the required certificate, CertificateVerify, its context string,
    Finished, the key-change boundary, early data, and a transcript that leaves out the client's
    certificate.
- `tls_server_fuzz.zig`:
  - The scripted client is correct, or wrong in one of twenty-one knobs.
  - In an eighth of the runs its hello is damaged, and in half of them its flight, in one of
    eleven ways. The result is fed in random pieces.
  - The server must connect exactly when the hello reached it whole, every knob was correct, and
    the records it read were the client's in order (at most one good `change_cipher_spec` among
    them). The check runs at every step.
  - Every refusal must carry a code and a cause, write at most one alert, and leave the server
    reading nothing.
  - A connection then runs a script of data and KeyUpdates both ways.
  - Its teeth (`tls_server_fuzz_teeth.zig`, in `mtls-teeth` only) switch off the CertificateVerify,
    Finished and chain checks in turn. Each must produce a false connect.
- Tidy allows only test files and the server's fuzzer to import `tls_testclient.zig`.

## The constants

All are in `src/constants.zig` with their reasons; changing one is a change to that file.

| Constant | Value | Bounds |
| --- | --- | --- |
| `x509_cert_bytes_max` | 1024 | a certificate we write or accept |
| `x509_leaf_ttl_ms_max` / `x509_ca_ttl_ms_max` | 7 days / 10 years | lifetimes |
| `x509_labels_max`, `_label_key_bytes_max`, `_label_value_bytes_max`, `_labels_bytes_max` | 16, 63, 256, 256 | identity labels |
| `tls_handshake_message_bytes_max` / `_flight_bytes_max` | 4096 / 8192 | one message / the reassembly buffer |
| `tls_chain_certificates_max` | 2 | leaf and CA |
| `tls_request_context_bytes_max` | 255 | the CertificateRequest context |
| `tls_records_per_key_max` | 2^24 | records before a KeyUpdate is due |
| `tls_key_updates_per_connection_max` | 2^16 | KeyUpdates in one connection |
| `tls_handshake_timeout_ms` / `tls_alert_flush_ms` | 10000 / 1000 | handshake deadline / alert send |

## Checks that run where

- `zig build wasm-check` runs `src/mtls_smoke.zig` in the WASM module (`zcube_mtls_smoke`): a CA
  issues a server and a workload certificate, both verify, a damaged byte, another CA, another
  name and a time past the window are each refused, and the client writes a ClientHello.
  `wasm-test` runs every core module's unit tests, the TLS ones included.
- `zig build mtls-teeth` (in `check`) runs the tests named `teeth:`: each switches one check off
  (chain signature, name, window, CertificateVerify, Finished, transcript, client-auth rules; on
  the server, the client chain and kind, the required certificate, CertificateVerify and its
  context, Finished, the key-change boundary, early data, and the fuzzer's three) and
  passes only if the matching test then fails. Each of these tests also runs its negative half
  (the check on, the scenario refused), because this step does not run the plain tests.
- `zig build mtls-interop` (not in `check`; CI job of its own) runs the client against
  `openssl s_server` and a JDK 21 server. It needs `openssl`, JDK 21 and `setpriv` (util-linux),
  and fails, not skips, without them
  (decisions/2026-11-06-interop-needs-setpriv.md). The JVM runs with
  `-Dcom.sun.net.ssl.requireCloseNotify=true`, so a client that drops TCP without `close_notify`
  fails the clean-close check.

## Diagnostics

| Code | Refused because |
| --- | --- |
| ZC-E0809 | malformed or outside the bounds; the field is named |
| ZC-E0810 | not signed by the pinned anchor |
| ZC-E0811 | expired or not yet valid; shows the window, the time now and the skew |
| ZC-E0812 | names another peer; shows both names |
| ZC-E0817 | an identity could not be issued |
| ZC-E0813 | the TLS handshake was refused: a malformed or out-of-order message, a CertificateVerify or Finished that does not verify, a server alert, or a CertificateRequest that is malformed or out of order |
| ZC-E0814 | the client certificate was not asked for though required, could not be answered, or was refused by the server (an empty or absent Certificate answered by a refusal is this too) |
| ZC-E0820 | the signer holding the client certificate's key did not sign |
| ZC-E0815 | a TLS record could not be read: it does not authenticate, is too long, has the wrong type or came after a key limit |
| ZC-E0816 | the connection ended or stalled without close_notify, or the handshake or a KeyUpdate answer did not finish in time, or a call came after an earlier failure had ended the connection |
| ZC-E0818 | the server needs something zcube does not offer: another version, suite, group or scheme, or a HelloRetryRequest |
| ZC-E0819 | issued for another role, such as a client certificate where a server's is needed |
| ZC-E0821 | the operating system's secure random source failed, so no key, nonce or seed was made (the weaker `random` is never used instead) |

For ZC-E0819, the fix is to give the peer a certificate issued for its role.
