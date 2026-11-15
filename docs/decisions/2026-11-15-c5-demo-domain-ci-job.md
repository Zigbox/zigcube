# C5's recorded demo runs as a dispatched CI job on `demo.zigbox.org`

*Decided 2026-11-15, by the owner (C5 brief, Q1); recorded by the supervisor's docs session.*

The recorded run of demo-c5 (Let's Encrypt production, a public address) is no longer done by
hand. It is a `workflow_dispatch` job.

- **Domain.** The owner wrote "zgbox.org", read as **zigbox.org**: the project's domain
  (`2026-11-04-errors-on-org-site.md`), which the owner controls through Cloudflare.
- **Where.** The job lives in `Zigbox/zigcube-jepsen`, which already holds the Google Cloud
  Workload Identity access (`2026-11-15-jepsen-on-google-cloud.md`). It builds Zigcube from the
  commit it is given (the `zig build dist` tarball of the C5 brief's PR `J`). That commit must be
  an ancestor of Zigcube's `main` or a release tag's commit; the job refuses anything else, and
  builds in a job with no secrets and no `id-token` permission.
- **What it does,** in order: create a VM in the Jepsen project and attach the static IPv4
  address **the owner reserved beforehand** (the job never creates or deletes it), with :80 and
  :443 open to the internet for that run only; write an A record `hello.demo.zigbox.org` (TTL 60,
  comment `zcube-demo run=<run id>`) to that address through the Cloudflare API and wait until
  Cloudflare's authoritative nameservers answer with it; run the demo script against Let's
  Encrypt staging, then production; capture the transcript and a headless-Chromium screenshot as
  job artifacts; then delete the record and the VM, **even on failure** (an `always()` step).
- **The token (option b only).** `CLOUDFLARE_DNS_TOKEN` is a secret of the GitHub Environment
  `demo-dns` (deployments from `main` only, a required reviewer), not a repository secret: a Cloudflare API
  token with Zone DNS Edit on one zone only. Only the DNS create and delete steps see it (`env:`
  on those steps). The job never prints it and never puts it on a command line: it reaches `curl`
  through the environment or a 0600 file (`curl -H @file`).
- **Open, the owner's choice; not decided.** Either way, `demo.zigbox.org` is delegated to a zone
  of its own. (a) *Recommended:* the NS records point at a GCP Cloud DNS zone, and CI writes the
  record through the existing Workload Identity Federation, so CI holds no Cloudflare token.
  (b) A zone-wide Cloudflare DNS-edit token, kept in the `demo-dns` Environment (main only, a
  required reviewer) and exposed only to the DNS steps. A Cloudflare token cannot be scoped below
  the zone without an Enterprise subdomain zone, so under (b) it can edit every record in that
  zone, including the apex and the MX records.
- **A nightly sweep** deletes records under `demo.zigbox.org` whose comment starts `zcube-demo` and
  that are over 6 hours old, and VMs labelled for the demo.
- **Leave the zone alone.** The apex of zigbox.org is a Cloudflare Worker (the website
  repository's AGENTS.md). The job touches only the one record it created: it refuses to run if
  that name already exists, it deletes by the record id the create call returned, and it never
  edits the apex or any other record. The record is DNS-only (not proxied): a proxied record
  would put Cloudflare's own TLS in front of the edge and the demo would prove nothing.
- **Rate limits.** Each dispatch orders one staging and one production certificate. Let's Encrypt
  allows 5 duplicate certificates a week, so the job is dispatched by hand, once per release, not on
  a schedule. CI on pull requests keeps using Pebble.
- **The record of it.** The supervisor copies the transcript into `docs/demos/c5.md` and links
  the run; that is what the site's `recorded` badge cites. C5 is marked "demonstrated" when the
  `demo-c5` CI job (Pebble) is green, as AGENTS.md requires.

*Amended 2026-11-15 by the supervisor's review rulings (R7): commit restriction, build without
secrets, the Environment secret, TTL and authoritative check, the sweep, the pre-reserved address
and the subzone question. The owner's choices above are unchanged.*

**A difference from SPEC's wording.** SPEC step 2 says "from a laptop outside the cluster". The
browser is now a headless Chromium on the GitHub runner, which is outside the cluster and reaches
the edge over the internet. The supervisor takes that as meeting the step; the owner can say
otherwise.

**Check before the first run.** A CAA record on zigbox.org that does not name letsencrypt.org
would make every order fail; the first dispatch reports it as ZC-E0826 with the CA's detail.

Where: `docs/briefs/c5.md` ("How demo-c5 runs"); `Zigbox/zigcube-jepsen`.
