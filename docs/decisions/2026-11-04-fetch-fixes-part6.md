# Fetch fixes, part 6 (slice 6b, fix pass D)

- **M1.** Handshake slots (`peer_handshakes_max`, 32, short deadline, one per source) are separate
  from serving slots (`peer_connections_max`, big buffers). A connection takes a serving slot only
  after it authenticates; with none free the client gets 503 (busy).
- **M2.** The published peer address is `--peer-advertise`, else a specified listen address; an
  unspecified listen address without it is refused at startup (ZC-E0505).
- **S1.** Discovery pages `/v1/list` (`discover_page_nodes` per page) instead of one reply sized to
  the 1 MiB bound.
- **S2.** The back-off streak is per digest, at most `fetch_streak_digests_max`; the oldest is
  dropped. The older one-streak file reads as no streak.
- **S3.** Busy is retried in `Net.peer_get` (transport), a bounded number of times with a short
  sleep, with no strike. Deviation: the brief says "the plan retries"; the plan is unchanged and
  sees `refused` only after the bound.
- **S4.** ZC-E0808's cause names the refused address (IPv6 by /64); blame is `external`. Severity
  stays `error`: DIAGNOSTICS.md's "Letter by kind" ties a warning to a W-code, so a change would
  rename the code. Owner to decide.
- **S5.** `parse` requires `b3:` plus 8..64 lowercase hex; anything else is ZC-E0505.
- **S6.** The accept loop sleeps one poll period on any accept error other than AGAIN/INTR.
- **Nits.** Exit codes in docs; `after_fetch` stops before the command after SIGTERM; ZC-E0808 is
  logged per time window; short-digest trees are neither served nor counted.
