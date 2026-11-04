# Untrusted paths need the full tree digest

Date: 2026-11-03. Status: Decided (owner, 2026-11-03).

`node_store.list_matches` accepts a digest that is a prefix of the list's BLAKE3 digest as short as
8 hex digits (the short digests of images and fixtures). That is 32 bits: a CA-signed but rogue peer
could grind a forged chunk list that matches it, then serve chunks that hash to the forged list.

Decision: on every path that trusts a peer, the expected tree digest is the whole `b3:` + 64 hex
(67 characters). `fetch_worker.fetch` gives a tree whose digest is shorter no peer at all: it comes
from the registry alone (the registry is the origin of the image; the short form stays usable
there). Test: "a tree named by a short digest is never fetched from a peer".

`peer_serve` is unaffected (it only serves what it holds). Anything new that fetches from a peer
must pass the full digest or call `fetch_worker.fetch`, which enforces this.
