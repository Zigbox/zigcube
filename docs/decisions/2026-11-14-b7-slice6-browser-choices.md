# B7 slice 6 part 1: choices made while building the browser path

*Recorded 2026-11-14 by the implementer of part 1, for the supervisor's review. They follow
docs/decisions/2026-11-14-b7-slice6-console-over-tls.md (path A); none adds a code or a
user-visible bound beyond those it lists, except as marked.*

- **Low S.** Certificates (both directions) must carry a low S, and the server signs its
  CertificateVerify with a low S. A browser's CertificateVerify is accepted with any S in
  range: browsers do not normalise S, and a CertificateVerify signs a transcript that holds the
  server's fresh random, so a malleated copy replays nothing. Strict DER (no padding, r and s in
  1..n-1, no trailing bytes) holds everywhere. `x509_p256_test.zig` and `tls_server_test.zig`
  test both.
- **The browser CA's key** is made at server start when absent (`server_browser_ca.zig`). A
  new key locks out nobody who was not already out. `ca issue-client --p12` refuses a store
  without one (`ZC-E0806`) rather than make it, since a key it made the running server would
  not hold.
- **`--tls-san` is a flag only**, not a key of the ZON config file.
- **The browser chain is the leaf only.** The browser CA certificate is imported as a root, so
  the server sends no intermediate.
- **PKCS#12.** PBES2 (PBKDF2-HMAC-SHA256, AES-256-CBC) for the key bag, a plain certBag (the
  certificate is public), an HMAC-SHA256 MAC, 600,000 iterations (OWASP's figure for
  PBKDF2-SHA256), both bags tied by a `localKeyId`. OpenSSL 3 and Chrome's NSS import it.
- **Cross-path refusals reuse `ZC-E0809`** (an algorithm the profile does not allow).
- **`--password-file F`** is how "a password from a file" is spelled. The file must not be
  readable by others (`ZC-E0806`, the existing `.secret` guard). From stdin, a terminal is
  refused (`ZC-E0106`: it would echo the password); one trailing newline is dropped. A password
  is at most 32 KiB, the existing `peer_file_bytes_max`; empty or non-UTF-8 is `ZC-E0106`.
- **The browser check uses Chrome, not the headless shell.** Playwright's default headless shell
  never sends a client certificate (the server logs `ZC-E0814`), so `tools/browser_check.mjs
  --tls` launches `channel: "chromium"` with a managed `AutoSelectCertificateForUrls` policy;
  docs/mtls.md, "Browsers", records the trust setup. It is a dev-time check, not in CI: CI has
  no NSS database or policy, and the supervisor may decide otherwise.
- **`ZC-E0814`'s text** still says a certificate "of the cluster CA" is required; the browser CA
  is per-cluster too, so it was left as is.
