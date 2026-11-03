# Supervisor handoff

*Updated 2026-11-03 by the supervisor session that shipped C1 and merged M7 slices 1 to 3b-i, for the session that runs C2 and the rest of M7. It covers both repos. Update it when you hand off in turn: replace what changed, keep it short.*

The owner decides; the supervisor runs the work. Zigbox (`Zigbox/zigbox`) is the sister project: its `AGENTS.md`, `REVIEW.md` and `DIAGNOSTICS.md` are where new rules show up first.


## Role

You supervise Zigcube C2 and Zigbox M7, one slice at a time. Each slice runs through these steps:

1. A fresh **Sonnet** implementer session (`create_session`, model `claude-sonnet-5-5`, `extra_allowed_tools ["mcp__claude-code-remote__add_repo"]`, `source_url` and `source_revision` = main).
2. An **Opus** review session, which inherits the model.
3. A fresh Sonnet fix session for the review findings.
4. A PR.
5. A squash-merge.

You may merge to main once the review findings are fixed and CI is green. Zigbox also needs its `vm.yml` run green on a `vm/*` branch.

After each merge:

- Update README.md and site/index.html in a commit marked `[skip ci]`.
- Dispatch `pages.yml` by hand (`actions_run_trigger run_workflow`, ref `main`), because `[skip ci]` also skips Pages.

Rules:

- **No tags or releases.**
- Do not subscribe to PR activity.
- Report briefly, with costs.
- Leave owner-only decisions to the owner.

## Mechanics

**Commits**

- Sign off with `git commit -s`, and add these trailers:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_01RfMZXMyXBLPcsaPf5PCxtq`.
- Never put a model name in a repo artifact.
- PR bodies end with "🤖 Generated with [Claude Code](https://claude.com/claude-code)" and the session link.

**Child sessions**

- To read a child's report, call `list_events` with `kinds ["result"]`.
- When it is done, call `archive_session`; the response gives `cost_usd`.

**GitHub**

- Force-push is denied. Push fixes to a new branch name and close the superseded PR.
- `merge_pull_request` needs the full 40-character SHA as `expectedHeadSha`. Use squash.
- The GitHub MCP disconnects often. Reload it with ToolSearch `select:mcp__github__<tool>`.
- On Zigbox PRs, the "check and demos on macOS" job stays queued with no runner. Merge past it: there is no Mac build this release.

**CI**

- Zigcube CI runs only on PRs and main.
- Zigbox `vm.yml` runs on pushes to `vm/<demo>-<slug>`.

**Local**

- Clones are at /home/user/zigcube and /home/user/zigbox. Update them with `git pull -q --ff-only origin main`.
- There is no zig locally; children build.
- **Summary doc (Claude Docs):** https://claude.ai/artifact/SE5XBKq9fVWHmdhJLamENX. Update it with `mcp__Claude_Docs__update`, using ref `{"object":"node","id":"5751ad44-4a69"}`, engine `prose`, and container `{"kind":"project","id":"cc47ebd7-0b8b-47eb-8dfb-791ef09b0ac4"}`. The current rev is 8.
- This file is the handoff. Update it, in Zigcube, when you hand off.

## State at handoff

**C1 is demonstrated.**

- Main CI run [41605325965](https://github.com/Zigbox/zigcube/actions/runs/41605325965) on 48024d6 was green.
- README and site were updated in 21cab3a, and Pages was dispatched.

**M7 has slices 1, 2, 3a and 3b-i merged.**

- Slice 3b-i is zigbox#34 (a126aee). It ran as VM run 41605919986.
- The status commit is defd2c1, and Pages was dispatched.
- The site still shows `green:2,total:5`, "not demonstrated".

**Overnight:** 12 PRs merged (Zigcube #38 #39 #37 #42 #46 #48 #50 #51; Zigbox #31 #32 #33 #34), about $122 in child sessions.

**In flight:** nothing. No sessions or check-ins are scheduled.

## Owner decisions (2026-11-03), not yet written into the repos

### M7: slice 3b-ii is split into two parts (approved)

**3b-ii, "The result"**

- Image assembly and its cache, `image.config`, E0807.
- The build record and the result digest.
- `zbx run <digest>` and `zbx inspect <digest>`.
- `--output json` and `zbx schema build`.
- Pull of a locked base by digest. This removes the E0804 stopgap.
- The N8 fix: root step outputs come before the cache entry.
- VM check: the full demo builds, `zbx run` prints "hello from zigbox", and the JSON shows `compile` and `notice` overlapping.

**3b-iii, "Network, streaming, library"**

- `network = true`, with `net` in the report, and W0801.
- `--verbose` streaming (kept).
- The `zigbox.build` library export, with a second-caller test.
- Worker crashes in the simulation, with the result digest a function of the inputs only.
- **The pasta VM check is cut (owner, 2026-11-03).** demo-m5 already checks pasta, and demo-m7 step 6 (slice 4) runs `wget` through it end to end. Record the cut in `docs/demos/m7.md`.

Slice 4 (demo-m7, upgrade, CI) follows.

Record the split in `docs/briefs/M7-build.md` (slice 3 is at about line 166) and in `docs/demos/m7.md`, on the 3b-ii branch.

### C2 (`zigcube/docs/briefs/c2.md`; owner questions at about lines 312–354, Z table at about line 299)

**Approved:**

- O1: `/node-store/<node>`, advisory, with an authority.md amendment.
- O2: placement order is fit, then spread, then locality, then least allocated, then name. Demo step 4 gets a new service on a shared image.
- O4: hostfwd plus a guest nft rule.
- O5: the node with the lowest `hash(node, tree)` pulls; the others wait up to 30 s for peers.
- O6: the key is `/pulls/<node>/<tree>`.
- O7: peers are not on `Runtime.Spec`.
- O8: GHCR images the owner pushes, public and pinned by digest.
- Z1–Z8: all approved.
- `source` names the OCI reference, and the provenance reservation is renamed `provenance`. A change of `source` bumps generation.

**Open:**

**Decided after the list above:**

- **O3 revised (owner, 2026-11-03, later the same day): a Noise-style handshake, not TLS.** The pinned std has a TLS 1.3 client only: no server, and no client certificates. C2 peers therefore use a small fixed handshake (X25519, Ed25519, ChaCha20-Poly1305). It keeps the trust model below: the control plane signs each node's Ed25519 key at join. Real mTLS remains the target, and the release docs must say the handshake is interim.
  - **Server-side TLS: open-source it, and when (owner, 2026-11-03).**
    - When we have our own server-side TLS 1.3/mTLS implementation, we open-source it.
    - It must land before Zigcube is offered for self-hosting on EC2. The owner placed that at C5.
    - SPEC's C5 is "Edge: public HTTPS", which needs a TLS server for ACME certificates anyway. C4 ("Mesh") already lists mutual TLS between workloads as one option.
    - So the latest point is C5, and C4 if C4 picks mTLS over WireGuard identity.
    - Put this into c2.md's follow-ups and the C4/C5 briefs when they are written.
- *Original O3 text, superseded:* **O3: mTLS (owner, 2026-11-03).** The peer chunk protocol is authenticated with mutual TLS. The control plane is the cluster CA and issues each node a certificate at join (node name in the cert). Chunk servers accept only peers whose certificates chain to the cluster CA, and clients verify the serving node's name. Integrity still rests on BLAKE3, and TLS adds confidentiality.
  - **Before slice 6, check:**
    - **Std TLS server support.** Have a Haiku agent read the pinned std's `std.crypto.tls` and confirm whether it supports server-side TLS 1.3 and client certificates. If it doesn't, slice 6 needs its own minimal TLS 1.3 server with Ed25519 certs. That would be a large piece of work, and the owner should be told about it before the slice is briefed.
    - **Docs to amend:**
      - O3 in c2.md.
      - A keys.md / authority.md item covering where the CA key lives (the server's state, never in the store in clear), certificate lifetime, renewal before lease expiry, rotation, and revocation when a node is removed.
      - New diagnostics, e.g. peer refused: bad or expired certificate.
- **Console:** the "full on hover" behaviour against docs/console.md is still unanswered.

## Next steps

1. Mark the decided owner questions in c2.md, either through a docs PR or inside slice 5's branch.
2. Start the **M7 3b-ii** implementer: Sonnet, from Zigbox main, with a VM check on `vm/m7-slice3b2`. Include the brief/demo-doc split edits.
3. Start the **C2 slice 5** implementer: locality in keys and the scheduler, per O1 and O2.
4. Brief the Zigbox slices for Z1–Z8. C2 slices 8 and 9 depend on them.
5. Check std TLS (see O3), amend c2.md for mTLS, then C2 slice 6 (peers, mTLS, O5). Slice 7 (`/pulls`) follows. Slice 6 may need splitting (CA and issuing; then the chunk protocol over mTLS).
6. Afterwards, M7 3b-iii, then slice 4 (demo-m7).

## Kept from earlier handoffs

- Playwright here: the default headless shell is missing. Launch Chromium with `executablePath` set to the binary under `/opt/pw-browsers/`.
- Implementer reports must carry `check: PASS <commit>` on the reported commit and a handoff note. A report without them goes back.
- A fix session that cannot `add_repo` Zigbox/zigbox cannot build. Make every implementer prove it can build before it writes code.
- Do not push docs-only follow-ups to an open PR's branch: each push restarts its CI. Batch them.
- Scheduled tasks on this account that you did not create belong to other sessions. Leave them alone.
- Open, low priority:
  - Zigbox issue #8, a separate diagnostics module.
  - A real code for `lost`.
  - Container start time in `Runtime`.
- Before C7: a TLA+ model of fencing. Before a second server: a leader lease on `/leader/controllers`.
