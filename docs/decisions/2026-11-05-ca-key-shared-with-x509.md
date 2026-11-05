# The cluster CA key signs both peer credentials and X.509 certificates

*Decided 2026-11-05, by the mTLS slice 2 session, on the brief's answer to Q1 (one pinned
anchor, the cluster CA) and its scope line "The same CA key". The supervisor reviews it with the slice.*

The CA's Ed25519 key (`ca.key`) already signs the 185-byte peer credential. From mTLS slice 2 it
also signs X.509 certificates: its own CA certificate, workload (client) certificates and server
certificates (`peer_ca.Ca.issue_*_certificate`). There is no second key. The public key is the
anchor in both formats, and `ca_key_id` (first 8 bytes of SHA-256 of it) names it in both: the
credential's `ca_key_id` field, and the CA certificate's subject `zcube-ca-<16 hex>`.

## Why one key

- A second key would be a second file to protect, back up and lose, and a second answer to "which CA is
  this?". `--new-ca` would have to replace both or explain why not.
- Every service that pins the anchor pins one public key whichever protocol it speaks.
- Sharing a key is safe when the messages it signs cannot be confused. The rest of this file argues
  that they cannot.

## Why the signed messages are disjoint

Ed25519 here is the pure scheme of RFC 8032 (`std.crypto.sign.Ed25519`, `sign(message, null)`): the
signature covers the message bytes themselves, with no prehash and no context string. A signature
over message `A` verifies for message `B` only if `A` and `B` are the same bytes (otherwise it is a
forgery of Ed25519). So two uses of one key cannot be confused if the sets of messages they sign
have no member in common. The CA key signs exactly two kinds of message.

1. **A credential.** `peer.signed_message`: the 19 bytes `"zcube-peer-cred-v1" 0x00` followed by
   the 121 body bytes (`docs/peer.md`, "The credential"). 140 bytes. The first byte is `0x7A`
   (`z`), always, because the domain is a constant.
2. **A TBSCertificate.** The DER bytes of the `tbsCertificate` of RFC 5280, which `x509.zig` writes
   and reads (`Parsed.tbs`, "the TBSCertificate with its header"). It is a DER SEQUENCE, so its first
   byte is the tag `0x30`, always: the parser refuses a certificate whose TBS does not start there
   (`Malformed`), and the writer cannot produce another first byte.

`0x7A != 0x30`, so no credential message is a TBS and no TBS is a credential message. The
`peer_ca.zig` tests assert it both ways: every kind of certificate the writer makes has a TBS that
starts `0x30` and not with the credential domain; a credential's signed message never starts
`0x30`; a credential signature swapped into a certificate fails `x509.verify` as a bad signature
and a certificate signature swapped into a credential fails `peer.verify` (ZC-E0801); and a
`comptime` assertion keeps the first byte of the domain different from `0x30`.

Nothing else is signed by the CA key:

- **The peer handshake** (`docs/peer.md`) is signed by the *node* keys, over a 32-byte SHA-256
  digest. A 32-byte message is not a TBS either: the smallest TBS the parser accepts is over 100
  bytes. The CA key is not a node key and never signs a transcript.
- **TLS `CertificateVerify`** is signed by the leaf's key, not the CA's, over 64 spaces (`0x20`)
  followed by a context string (RFC 8446, 4.4.3). Neither of the CA's message kinds starts so.

Whoever can choose the contents of a message the CA signs gets no purchase on the other format.
A certificate request chooses the subject name, the subject key, the SPIFFE ID, the labels and
the window, all inside a DER TBSCertificate; a node join chooses a node name and key, inside a
credential body. Each lands behind its own first byte.

## The rule that keeps it so

A new use of the CA key needs a new first byte or a new domain string that cannot start with `0x30`
or `zcube-peer-cred-v1`, a test next to the two above, and an edit to this file. Never sign
anything with this key whose first byte the signer's caller chooses.

## What this does not change

- **The credential format** stays 185 bytes, version 1, and `src/peer.zig` is not edited. The
  test `the peer credential is byte for byte what it was before X.509 shared the key` holds a golden
  of one credential made from fixed inputs.
- **One key is one blast radius.** A stolen `ca.key` already lets its holder mint any node
  credential (`docs/peer.md`, "Does not give"). It now also lets them mint workload certificates.
  The key file's rules (0600, a directory others cannot write, ZC-E0806) are the same.

## The CA certificate file

`<state dir>/ca-<16 hex>.crt` (`ca.crt` for a store with no file of its own) is the CA certificate
as one PEM block, written next to the key (`server_ca.zig`) with the key's rule: mode 0600, a
directory others cannot write, ZC-E0806 for a file that is too open. It is derived from the key,
so it is made again, not repaired, when it is absent, not our PEM, for another key (after
`--new-ca`) or expired. It lives `x509_ca_ttl_ms_max` (10 years) from the start that made it. It is
not a store key and nothing in the server reads it back: it is for operators to hand to the
services that pin the anchor. A memory store makes a CA in memory each start and writes no file.

Where: `src/peer_ca.zig`, `src/server_ca.zig`, `docs/peer.md` ("X.509 certificates from the CA").
