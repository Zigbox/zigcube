# Pull stats are agent-written, per (node, tree), and pruned by the server

*Decided 2026-11-04, by C2 slice 7 (owner decision O6 asked for the stats).*

- **Writer.** The node's agent writes `/pulls/<node>/<tree>`, not lease-bound, so the numbers
  outlive the node. It is statistics: no controller reads it and it is in no compare set.
- **Shape.** One record per (node, tree); a later pull of the same tree replaces it. Fields:
  `registry_bytes`, `peer_bytes` (list of `{peer, bytes}`), `cached_bytes`, `started_at_ms`,
  `finished_at_ms`, `bad_peers` (names). Written only for a pull that finished.
- **Data path.** The fetch child writes `pull.json` (`--report`); the agent publishes it on a
  later step and removes it. The child still writes no store key.
- **Retention.** The replica controller prunes every 5 minutes: newest 100 per node, none older
  than 30 days. The `retention` role may delete under `/pulls/` and never put.
- **Console and CLI** read `GET /v1/stats/pull`; a malformed record is skipped and counted.

Where: docs/keys.md, docs/api.md, docs/agent.md, docs/cli.md, docs/authority.md.
