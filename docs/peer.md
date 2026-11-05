# Peer identity and the handshake (C2 slice 6a)

**Interim.** This is a small, purpose-built authenticated key exchange, chosen by the owner on
2026-11-03 (brief c2.md, O3) because the pinned standard library has a TLS 1.3 *client* only: no
server, no client certificates. **Real mTLS (TLS 1.3 with certificates) is the eventual target.**
Release documentation must say that this handshake is not final and has not had the review a
standard protocol has had. Nothing outside the peer listener depends on it, so it can be replaced
without touching the store, the API or the fetch plan.

Slice 6a builds the identity and the handshake and no transfer. Slice 6b puts the chunk server
and the fetch worker on top of the API at the end of this file.

## What it gives, and what it does not

Gives:

- **Mutual authentication.** Each side proves it holds the private key of a credential the
  cluster CA signed, and a client checks that the server's credential names the node it meant to
  reach. A peer with no CA-signed credential is refused before it is sent application data. It is
  not refused before it is told anything: any 34-byte M1 gets the server's credential in M2, at
  the cost of one X25519 and one Ed25519 signature. The peer server limits handshakes per source ("Rate limit", below).
- **Confidentiality and integrity of the stream** (ChaCha20-Poly1305 records) and **forward
  secrecy** (fresh X25519 keys for every connection; a stolen node key does not open a recorded
  session).
- Both credentials travel encrypted, so a passive observer does not learn which nodes talk.

Does not give:

- **Traffic analysis resistance.** Record lengths, timing and the number of records show how
  much was fetched. Images in scope are public; this is accepted.
- **Protection from a compromised CA or server.** The control plane is the cluster CA and signs
  whatever key a join presents (below). Whoever holds `ca.key`, or can reach the unauthenticated
  API, can mint a credential for any node name. API auth is a later milestone's.
- **Revocation in real time.** A credential lives `peer_credential_ttl_ms` (24 h); a node
  removed from the cluster is refused renewal and its credential lapses (see "Lifetime").
- **Anything about chunk correctness.** Integrity of image data rests on BLAKE3 against hashes
  the fetcher already holds, as before. A peer is trusted for speed only.
- **Authenticated refusal.** A server that refuses a client closes the connection; the client
  cannot tell the refusal from a network cut, and says so (ZC-E0804).

**Server-side TLS follow-up (owner, 2026-11-03).** When we have our own TLS 1.3/mTLS server
implementation we open-source it, and it must land before Zigcube is offered for self-hosting on
EC2 (C5 at the latest; C4 if C4 picks mTLS for workload identity).

## Trust model

The control plane is the cluster CA.

1. `zcube-server` has an Ed25519 **CA key**, generated on its first start into
   `<state dir>/ca.key` (mode 0600, the 32-byte seed in hex, one line) and loaded afterwards.
   The secret is never written to the store, an API answer, a bundle or a log. Its public key is
   served to agents.
2. An agent has an Ed25519 **node key**, generated on its first run into
   `<state dir>/peer.key` (mode 0600, same format). At join it sends the public key and receives
   a signed **credential** binding that key to its node name. It stores the credential in
   `<state dir>/peer.cred` and the CA's public key in `<state dir>/ca.pub`.
3. A peer accepts only credentials signed by the CA key it holds, inside their validity window.

The join call is `POST /v1/agent/nodes/{node}/credential` (docs/api.md). Like every agent
endpoint it is unauthenticated until the API has auth; anything that can reach the server's port
can join, which is exactly as much as it can already do to the store. The CA key therefore buys
peer-to-peer trust (a node on the private network that never joined cannot fetch from or serve
to the swarm), not protection from the control plane's own clients.

## The credential

Fixed size, 185 bytes, version 1. Integers are little endian.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | `version` = 1 |
| 1 | 8 | `ca_key_id`: the first 8 bytes of SHA-256 of the CA public key |
| 9 | 1 | `name_length`, 1 to 63 |
| 10 | 63 | `name`, a node name (hostname label), zero padded; padding must be zero |
| 73 | 32 | `node_key`: the node's Ed25519 public key |
| 105 | 8 | `not_before_ms`: Unix milliseconds |
| 113 | 8 | `not_after_ms`: Unix milliseconds, greater than `not_before_ms` |
| 121 | 64 | `signature`: Ed25519 by the CA over `"zcube-peer-cred-v1" 0x00` followed by bytes 0..121 |

Rules a decoder enforces, each its own refusal: wrong version, a name that is not a valid node
name or has non-zero padding, `not_after_ms <= not_before_ms`, or a lifetime above
`peer_credential_ttl_ms_max`. A verifier then checks, in this order: the key id matches the
CA it holds (ZC-E0801), the signature verifies (ZC-E0801), `not_before_ms <= now < not_after_ms`
(ZC-E0802), and, when the verifier named a node, that the name is that node (ZC-E0803). `now` is a
Unix-millisecond **wall clock** passed in by the shell; the core reads no clock. Nodes need
clocks within `peer_clock_skew_ms` (60 s) of the CA's: the verifier accepts `not_before_ms` that
far in the future and `not_after_ms` that far in the past, no more. Credentials start at the
issuer's `now` and the agent renews after half the lifetime, so skew only matters at a join.

## The handshake

Three messages over any ordered byte stream, then records. Notation: `H` is SHA-256, `||` is
concatenation, `X(a, B)` is X25519, `E(k, n, ad, m)` is ChaCha20-Poly1305 with a 12-byte nonce
`n`, and `sign_X(label, ...)` is Ed25519 by node `X`'s key. This is a SIGMA-style exchange
(authenticated by signing the transcript) rather than Noise XX, because a node's long-term key is
an Ed25519 signing key, and it keeps the code to one DH per connection.

```
client                                                          server
  e_c = fresh X25519
  M1 = 0x01 0x01 || E_c                       ───────────────▶
                                                  e_s = fresh X25519
                                                  dh = X(e_s, E_c)
                                                  h1 = H(label || M1)
                                                  h2 = H(h1 || E_s)
                                                  keys (below) from dh, h2
                                       ◀───────────────  M2 = 0x01 0x02 || E_s || ct_s
                                                  ct_s = E(k_hs_s, 0, h2,
                                                        cred_s || sign_s("server" || h2 || cred_s))
  dh = X(e_c, E_s); same keys
  open ct_s; check cred_s (CA, window, name)
  h3 = H(h2 || ct_s)
  M3 = 0x01 0x03 || ct_c                      ───────────────▶
     ct_c = E(k_hs_c, 0, h3, cred_c || sign_c("client" || h3 || cred_c))
                                                  open ct_c; check cred_c (CA, window)
                                                  h4 = H(h3 || ct_c)
  transport keys from dh and h4 (both sides)
```

- `label` is the ASCII string `zcube-peer-v1`. Header bytes are `version` then `type`. The
  version is 1; any other is refused (ZC-E0804). There is no negotiation, so there is nothing to
  downgrade: a later protocol uses a new port or a new `version`, and this side refuses it.
- **Sizes.** M1 is 34 bytes. M2 is 34 + `credential_bytes` + 64 + 16 = 299 bytes. M3 is 2 +
  `credential_bytes` + 64 + 16 = 267 bytes. All fixed, so the reader reads exactly that many
  bytes and no length field is parsed from the network during the handshake.
- **Keys.** `prk = HKDF-Extract(salt = h2, ikm = dh)`; `k_hs_s = HKDF-Expand(prk,
  "zcube-peer-v1 hs server")` and `k_hs_c` likewise with `client`. After M3,
  `prk2 = HKDF-Extract(salt = h4, ikm = dh)`; `k_c2s = Expand(prk2, "zcube-peer-v1 c2s")` and
  `k_s2c = Expand(prk2, "... s2c")`. Each handshake key seals exactly one message, nonce 0.
- **The signed bytes.** `sign_X(label, role, h, cred)` signs `SHA-256(label || " " || role ||
  h || cred)`, where `label` is the ASCII string `zcube-peer-v1`, `role` is `server` or `client`,
  and `h` is `h2` or `h3`.
- **What kind of exchange this is.** SIGMA-I-style, not Noise: there is no static DH and no
  chaining key. The server reveals its identity to an active attacker; the client reveals its
  own only to a server it has verified. The signatures are transferable (unlike XX's), and
  authentication holds because each proof is sealed under the DH-derived key. See
  docs/decisions/2026-11-03-peer-handshake-and-ca.md.
- **Order of checks.** The transcript signature is verified before the credential's CA, window
  and name, so a replayed old credential fails as ZC-E0804, not ZC-E0802.
- **Why the signatures cover the credential bytes** (`|| cred`): so that a signature cannot be
  paired with a different credential for the same key (an identity misbinding). They cover
  `h2` / `h3`, which hash both ephemeral keys, so a signature is good for one connection only and
  cannot be replayed to another.
- **Reflection.** The labels `"server"` and `"client"` are in the signed bytes, and the two
  directions use different keys, so a side's own message sent back to it opens under neither.
- **Replay of M1 or M3.** A replayed M1 gets a fresh `e_s`, so the attacker cannot open the
  answer. A replayed M3 is bound to the server's ephemeral key through `h3`, so it fails against
  any other connection.
- **All-zero or low-order X25519 points** make `X25519` return an error; that is a refusal
  (ZC-E0804), never a key derived from zero.
- **Who may be told what.** The server sends its credential only after a well-formed M1 (any
  32 bytes pass; the cost of that is one signature). It sends no application data until M3
  verifies, and the client checks the server's name before it sends M3, so a client never
  reveals its credential to a node it did not mean to reach.
- **Failure.** Any check that fails ends the handshake with a typed error and no reply. The
  caller closes the stream and raises the diagnostic (below).

## Records

After the handshake each direction is a sequence of records:

```
length u16 big endian  ||  ciphertext (length - 16 bytes)  ||  tag (16 bytes)
```

`length` counts ciphertext plus tag, so it is at least 16 and at most `peer_record_bytes_max`
(16384) plus 16. The plaintext of a record is 0 to 16384 bytes. The nonce is 4 zero bytes then
the record's **counter** as a u64 little endian; the counter starts at 0 for each direction, is
implicit (never sent) and rises by one per record, with the 2-byte length as the associated
data, so a record cannot be dropped, repeated, reordered or truncated-and-lengthened without the
tag failing (ZC-E0805). A direction **closes at `peer_record_counter_max`** (2^32 records, 64 TiB at
full records): sealing or opening the next record is refused (ZC-E0805) and the caller starts a
new connection with a new handshake. There is no rekey. The end of a stream is not
authenticated: a cut stream is indistinguishable from a close, so the application above (6b)
must frame its messages (a request line, a body length) and treat a short body as an error.

## Diagnostics

All are `ZC-E08xx`, blame `external` except where noted, one line, naming the peer when known.

| Code | Refused because |
| --- | --- |
| E0801 | a credential is not signed by this cluster's CA (unknown key id, or a bad signature) |
| E0802 | a credential is expired or not yet valid |
| E0803 | the server's credential names another node than the one asked for |
| E0804 | the handshake failed: malformed or tampered message, wrong version, bad transcript signature, weak key, or a cut stream |
| E0805 | a record failed authentication, or a direction reached its record counter limit |
| E0806 | (environment) the CA key or the node key could not be read, written or parsed |
| E0807 | (user) a node was refused a credential because it was removed from the cluster |
| E0808 | (user) a peer's handshake was refused: its address already has as many unfinished as one may, started too many in a window, or the table of addresses is full |

## Lifetime, renewal and removal

- A credential lives `peer_credential_ttl_ms` (24 h) from the issuer's wall clock.
- The agent renews through the same `POST .../credential` when half the life has gone, and again
  on any start whose stored credential has less than half its life left. The renewal is a
  lease-time concern in spirit (a node that stays up keeps a current credential) but it is a call
  of its own: the credential is not a store key and is not tied to the lease's revision.
- **Removal.** A node removed from the cluster is named in the server's `<state dir>/revoked`
  (one node name per line, `#` comments), read at start. The server refuses to issue or renew
  for a listed name (ZC-E0807) and the node's credential lapses within a day. That is the
  denylist: cheap, but read only at start and not a store key, because C2 has no node removal
  command to drive a store-backed list. When one exists it writes this list. A listed node whose
  credential has not yet expired is still accepted by peers until it does: **a day is the bound
  on revocation**, and a shorter ttl is the dial.
- **The CA key file is per store.** `ca-<16 hex of a hash of the store's identity>.key`, so two
  clusters sharing a state directory get two CAs. The directory and the file must not be
  writable by group or others (ZC-E0806). The key is never written to the store.
- **A lost key is refused, not remade.** A new CA is made silently only at a store's first
  start. If the key is missing for a store that has history, the server stops with ZC-E0806;
  `zcube-server --new-ca` accepts a new CA, and every node then joins again.
- **A CA that changed reaches the agents.** Every agent answer carries `chain.ca_key_id`. An
  agent whose credential names another CA drops it and its `ca.pub`, reports ZC-E0801 once and
  joins again at its next pass (seconds). A server without a state directory (memory store)
  makes a new CA each start and says so in its startup line; its agents do the same.
- **Issuance names a lease.** `POST .../credential` carries `{"node_key", "lease"}` and the
  server issues only when the node's record is registered under that live lease (a store read;
  ZC-E0205 otherwise). The CA reads node and lease records and writes none.
- **The API is unauthenticated.** Revocation (`revoked`, the lease check) binds an honest node
  only until API auth lands: anyone who can reach the API can register a name and ask for a
  credential.

## What 6b calls

`src/peer.zig` is pure: it takes bytes and an `Identity` and returns bytes and a `Session`.
`src/peer_stream.zig` (shell) runs it over a `std.Io` stream.

```zig
var handshake = peer.Initiator.init(identity, expected_node, ephemeral_seed, now_ms);
var out: [peer.m2_bytes]u8 = undefined;
// client: m1 = handshake.first(); send; read m2_bytes; m3 = try handshake.second(m2) ; send;
//         session = handshake.finish()
// server: var h = peer.Responder.init(identity, ephemeral_seed, now_ms);
//         read m1_bytes; m2 = try h.first(m1); send; read m3_bytes; session = try h.second(m3);
//         session.peer_name() is the authenticated client node
// session.seal(plaintext, out) / session.open(record, out): records.
```

The ephemeral seed comes from the shell's randomness; `now_ms` from its wall clock.

## Tests

`src/peer_test.zig` (also run under WASI): a round trip; every refusal; one bit flipped at every
byte position of M1, M2 and M3, each making the handshake fail (a flip in M1's ephemeral key
changes the transcript, so the client fails when it opens M2); replay, reordering, reflection
and tampering of records, and counter exhaustion; a teeth test (`set_test_fault`: a test-only
fault that skips the credential signature check must let a forged credential in, which proves
the refusal tests would fail). `src/peer_fuzz.zig` is the seeded decoder fuzzer
(`ZCUBE_FUZZ_SEED`). The rest of 6a is `src/peer_ca.zig` (core: the `Ca`, the
`revoked` list and its parser), `src/peer_files.zig` and `src/server_ca.zig` (shell: `ca.key`
mode 0600, atomic writes, ZC-E0806), `src/agent_peer.zig` (the agent's files, join, renewal at
half the life), and the join endpoint in `src/agent_api.zig`. Their tests: unit tests in each
file, and in `src/agent_remote_test.zig` a live server and agent files for issuance, persistence
across a server restart, renewal and the refusal of a removed node (ZC-E0807). With a memory
store the CA is made again at each start, which says so on stderr, and every agent rejoins.
The handshake is interim: see `docs/decisions/2026-11-03-peer-handshake-interim.md`.

## The peer server and the fetch worker (slice 6b, part 2)

`src/peer_stream.zig` runs the handshake and sealed messages over a socket (a message is a u32
length and its body in records; every wait is a `poll` against one deadline, and no read or write
blocks: sends and receives use `MSG_DONTWAIT` and the sockets are non-blocking, so a peer that stops
reading mid-reply, or a zero window, ends the connection at `peer_reply_ms`). `src/peer_server.zig`
listens, asks `peer_limit.Limiter` before each handshake (ZC-E0808 once per streak), loads the
identity from the state directory at each handshake (`agent_peer.load_identity`) and answers
`GET /v1/peer/trees/<digest>` and `GET /v1/peer/chunk/<hash>` with `peer_serve.answer`. A reply is a
14-byte head message (status u16, first, last, total u32 big endian) and a body message. Each connection first
holds a cheap handshake slot (`peer_handshakes_max`); only after it authenticates does it take one of
`peer_connections_max` serving slots (the big buffers), else it is told 503 (busy). One node name holds
at most `peer_connections_per_node_max` (2) serving slots at once; its next connection is told 503 too
(a bound per name, not per attacker: any API client can mint a credential). `src/fetch_worker.zig` drives
`fetch_plan` over a `Transport` and a `DirImages`.

The `zcube-agent fetch` command, peer discovery over `/v1/list`, the supervisor running the worker before
the command (ZC-E0601) and the fake registry are described in `docs/agent.md`; `zig build swarm-smoke`
runs them end to end. See `docs/decisions/2026-11-03-slice6b-handoff.md`.

### The bundle route (slice 8)

A node whose images live in a Zigbox store (`--zigbox-store`) also answers
`GET /v1/peer/bundle/<full digest>` (`peer_serve.path_bundle`, `zigbox_fetch.encode`): the tree
records, a description of every object and the image record in one message of 16 KiB records
(wire format in `src/zigbox_fetch.zig`, magic `ZCB1`). The route takes the full `b3:` digest only
(a short one is 400); a tree the store lacks, or a server with no Zigbox store, or a request with no
buffer is 404. The core has no allocator: the shell (`peer_server.zig`) gives every request a
bundle buffer and each serving slot its own `ZigboxImages`, so one thread's state is never shared.
Chunks are the existing `chunk/<hash>` route, served from the same store.

A receiver trusts the peer for nothing but speed. The expected manifest comes from its own
assignment, never from the bundle; the tree is asked for by its full digest; each tree record is
checked against its digest, each object against its id and each chunk against its hash. A bad
bundle is ZC-W0602 and the next peer is tried. `src/peer_server.zig` has a test over a real stream
and two stores: a peer that corrupts chunks fails the fetch (`ChunkFailed`), a record for another
manifest is `Refused`, a tree the peer lacks is `TreeUnavailable`, and in each case nothing is
rooted in the empty store.

## Rate limit

M1 costs the responder public-key work, so `peer_server` decides before it starts a handshake,
and closes a refused connection without a byte. A source is the peer's address with the port left
out; an IPv6 address counts by its /64 (one host holds the whole range) and an IPv4-mapped IPv6
address as the IPv4 address it carries (`peer_server.source_key`).

A source may be a whole cluster: nodes behind one NAT address, or demo-c2's VMs, whose peers all
arrive from the host forward's 10.0.2.2. The per-source bounds are therefore sized for many honest
nodes and bound only unauthenticated work; authenticated work is bounded per node name (the serving
slots above).

- **A few unfinished handshakes per source.** While `peer_handshakes_pending_per_source_max` (8)
  connections from a source are still in their handshake, another from the same source is refused
  and not counted below. Strangers of one address that connect and send nothing therefore hold 8
  of the `peer_handshakes_max` (32) links, not all of them (and an old stranger is evicted for a
  newcomer). The refused peer tries again and is admitted once a handshake has finished or timed
  out (`peer_handshake_ms`).
- **A cap per window.** `peer_handshakes_per_source_max` (256) starts per source in
  `peer_handshake_window_ms` (10 s) counted from the source's first start (`peer_limit.Limiter`):
  at most about 25 handshakes' public-key work a second per address. A fetch keeps one stream per
  peer for up to `peer_connection_requests_max` requests, so even a server sending 1 GiB/s to all
  its fetchers together sees about 16 handshakes a second.
- **A table of `peer_sources_max` (256) sources.** A source whose window ran out frees its slot.
  A table of live windows refuses a new source: the cheapest answer to a flood from many
  addresses, at the cost that honest peers are refused too, for at most one window, until a
  slot frees. Their retry is the recovery. The clock is `CLOCK_BOOTTIME` milliseconds (monotonic).

Refusals are shown as ZC-E0808, naming the address, at most once per `peer_refusal_log_ms`
(a flood does not flood the log). Only full `b3:` + 64 hex trees are served or counted.

## Test fault: `peer-corrupt`

`<state-dir>/faults/peer-corrupt` makes that node's peer server flip the first byte of every chunk
it serves. The fetching node must hash the chunk, strike the peer (`ZC-W0601`) and take the chunk
elsewhere; `zig build swarm-smoke` runs node1 with it. Never set it outside a test.
