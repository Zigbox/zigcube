# demo-c2 images: ghcr.io/zigbox/python-app v1 and v2, digest-pinned (owner, 2026-11-04)

The owner built and pushed the O8 images with `ops/demo-c2-images/push.sh` (linux/amd64, on `python:3.12-slim` pinned by digest). demo-c2's service files pin them by digest, never by tag:

- `ghcr.io/zigbox/python-app@sha256:c0373ee9361f29da3cbd8b0eee85ff11297f7f9a61724bc920c622f7de58e14c` (v1)
- `ghcr.io/zigbox/python-app@sha256:e89d9e8605126e634764d3829c4d71a9e5b85377675b66b16f174f3b3cfa9a36` (v2)

Layers (first 12 hex of each digest), as `push.sh` printed them:

- v1: `6fc242d221a6 3eb771151506 f574edac59d9 acca7542dfc7 75387e8a7838 a36a0146dcf2`
- v2: `6fc242d221a6 3eb771151506 f574edac59d9 acca7542dfc7 75387e8a7838 0308a31afebf`

They share every layer but the last, which holds only `app.py`, so demo-c2 step 2 (v1 to v2) moves only that file's chunks. The package must be public so the demo's guests pull it without credentials; on 2026-11-04 an anonymous pull token for it was refused (401), so it was still private when this was recorded.
