# B7: the supervisor's calls on slice 2's open questions

*Decided 2026-11-13, by the supervisor (recorded by B7 slice 3).*

- **The cluster name stays derived from the CA key, for now.** It is `zc-` followed by 16 hex
  digits of the SHA-256 of the CA's public key (`2026-11-13-cluster-name-from-ca-key.md`).
  - B4's `.cluster` server setting (on `claude/b4-slice2`, not yet merged) also names the
    cluster. When it lands, the two become one cluster name, and the configured `.cluster` is
    required to match.
  - Whichever of B4 and B7 merges second does that unification.
- **A client certificate lives 7 days** (`x509_leaf_ttl_ms_max`). There is no `--ttl` flag yet.
- **A new agent requires `node_certificate` at join.** An agent of B7 refuses a credential
  answer without one. So the server is upgraded before the agents, as `docs/agent.md` says.

Where: `docs/mtls.md`, `docs/agent.md`, `2026-11-13-b7-slice2-handoff.md`.
