# C5's recorded demo runs as a dispatched CI job on `demo.zigbox.org`

*Decided 2026-11-15, by the owner (C5 brief, Q1); recorded by the supervisor's docs session.*

The recorded run of demo-c5 (Let's Encrypt production, a public address) is no longer done by
hand. It is a `workflow_dispatch` job.

- **Domain.** The owner wrote "zgbox.org". The supervisor assumes **zigbox.org** (the project's
  domain) and records that as an assumption; the owner corrects it if it is wrong.
- **Where.** The job lives in `Zigbox/zigcube-jepsen`, which already holds the Google Cloud
  Workload Identity access (`2026-11-15-jepsen-on-google-cloud.md`). It builds Zigcube from the
  commit it is given (the `zig build dist` tarball of the C5 brief's PR `J`).
- **What it does,** in order: create a VM with a reserved static IPv4 address in the Jepsen
  project, with :80 and :443 open to the internet for that run only; write an A record
  `hello.demo.zigbox.org` (any name under the `demo.` label will do) to that address through the
  Cloudflare API; run the demo script against Let's Encrypt production; capture the transcript
  and a headless-Chromium screenshot of the page as job artifacts; then delete the record, the
  VM and the address, **even on failure** (an `always()` step).
- **The token.** The owner gives the repository a secret `CLOUDFLARE_DNS_TOKEN`, a Cloudflare API
  token with Zone DNS Edit on the zone `zigbox.org` only. The job never prints it and never puts
  it on a command line: it reaches `curl` through the environment or a 0600 file
  (`curl -H @file`), and the step masks it.
- **Leave the zone alone.** The apex of zigbox.org is a Cloudflare Worker (the website
  repository's AGENTS.md). The job touches only the one record it created: it refuses to run if
  that name already exists, it deletes by the record id the create call returned, and it never
  edits the apex or any other record. The record is DNS-only (not proxied): a proxied record
  would put Cloudflare's own TLS in front of the edge and the demo would prove nothing.
- **Rate limits.** Each dispatch orders one production certificate. Let's Encrypt allows 5
  duplicate certificates a week, so the job is dispatched by hand, once per release, not on a
  schedule. CI on pull requests keeps using Pebble.
- **The record of it.** The supervisor copies the transcript into `docs/demos/c5.md` and links
  the run; that is what the site's `recorded` badge cites.

**A difference from SPEC's wording.** SPEC step 2 says "from a laptop outside the cluster". The
browser is now a headless Chromium on the GitHub runner, which is outside the cluster and reaches
the edge over the internet. The supervisor takes that as meeting the step; the owner can say
otherwise.

**Check before the first run.** A CAA record on zigbox.org that does not name letsencrypt.org
would make every order fail; the first dispatch reports it as ZC-E0823 with the CA's detail.

Where: `docs/briefs/c5.md` ("How demo-c5 runs"); `Zigbox/zigcube-jepsen`.
