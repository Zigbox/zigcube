# openssl and java are test tools, never part of a product
*Decided 2026-11-05, by the owner (mTLS client brief, Q3).*

The interop harness (`zig build mtls-interop`, `src/mtls_interop.zig`) runs the TLS client against stock servers: `openssl s_server` and a JDK 21 `SSLServerSocket` (`ops/mtls-interop/InteropServer.java`). Both are used only to test.

1. **No shipped binary starts, links or needs `openssl` or `java`.** They are invoked by the harness and by the CI job `mtls-interop` and by nothing else. A product code path never shells out to them.
2. **The harness fails, it does not skip, without them.** A missing `openssl`, a missing `java` or a JDK that is not 21 is a failure line of the harness itself (not a registered `ZC-` code, because it is not a failure of a product).
3. **The Java server is source, not a build artifact.** The harness compiles it with `javac` into a scratch directory on each run; nothing is checked in as a class file.
4. **Not in `zig build check`.** The job needs a JDK and takes minutes; it runs in its own CI job, selected by `src/mtls_interop.zig` and `ops/mtls-interop/*` in `.github/ci-changes.sh` (any other path that runs everything runs it too).
5. **The CI job takes the JDK from the runner image** (`JAVA_HOME_21_X64`), not from `setup-java`, because no pinned commit of that action is vetted here. If the image drops JDK 21, the job fails on the version check.
