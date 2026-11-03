# C2 owner decisions O1–O8 and Z1–Z8

*Decided 2026-11-03.*

**C2 owner decisions O1–O8 and Z1–Z8** (owner). O1 `/node-store/<node>`, advisory, authority.md amended. O2 order fit → spread → locality → least allocated → name; demo-c2 step 4 adds a new service on a shared image. O3 (revised 2026-11-03) a **Noise-style handshake** for the peer chunk protocol, not TLS, because std has no TLS server (the control plane is the cluster CA and signs each node's Ed25519 key at join; X25519, Ed25519 and ChaCha20-Poly1305; BLAKE3 stays the integrity check; real mTLS is the eventual target; slice 6 owns the details; its "unauthenticated" is superseded). O4 `hostfwd` plus a guest nft rule. O5 lowest `hash(node, tree)` pulls, the others wait up to 30 s. O6 `/pulls/<node>/<tree>`. O7 peers not on `Runtime.Spec`. O8 GHCR images pushed by the owner, public, digest-pinned. Z1–Z8 approved. Console: long values stay shortened and a click or key expands or copies the full value; a hover title is never the only way.

Where: docs/briefs/c2.md
