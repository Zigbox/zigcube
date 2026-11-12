# The relay's fence, compared with NVIDIA OpenShell's

*Decided 2026-11-12, by the supervisor, on Zigcube #228 (approved by the owner).*

OpenShell (Apache-2.0, v0.1.8) was read at commit 8606ee3. Its fence checks were set side by
side with B3's hostile tests (`docs/demos/b3.md`, step 2). Nothing was built or run, and nothing
of OpenShell's is copied. Line numbers below refer to that commit.

## What both test

Each of these must fail from inside a relayed workload:

| Check | OpenShell | B3 |
|---|---|---|
| Direct connect to a public address | e2e `bypass_detection.rs:50` | 1.1.1.1:443 |
| Cloud metadata, 169.254.169.254:80 | e2e `proxy_egress_pipeline.rs:1096` | the same |
| The control plane | 203.0.113.10:6443 | zcube-server |
| Another port of the boundary | 203.0.113.10:8080 | the bystander's relay port |
| DNS outside the route | resolves only over policy DNS | a lookup must fail |

## What B3 tests and OpenShell does not

- A raw ICMP socket.
- The upstream reached directly, bypassing the relay.
- Nothing listening on the relay port in the node's own namespace.

## Rows B4 adds

These come from OpenShell and are missing from B3. B4's demo (slice 4) adds them.

1. **The workload cannot touch its supervisor.** This matters more in B4 than in OpenShell: the
   run's private key lives in the supervisor's memory. OpenShell checks that the workload's
   signals fail with EPERM (`network_broker.rs:3104`). From inside the container, B4 checks
   that each of these fails:
   - the supervisor's pid is visible in `/proc`;
   - a kill or a ptrace of the host pids the agent reports;
   - reading `/proc/<pid>/mem` of any process that is not the workload's own.
2. **The fence is asserted from the spec, not only probed.** OpenShell refuses a workload
   configuration that attaches any network (`tests.rs:1686`, `:1706`; `isolation/mod.rs:154` for
   the microVM). B4 slice 2 adds a unit test: a relayed run's `Runtime.Spec` asks for a network
   namespace with loopback only, and the adapter refuses to start one that asks for more.
3. **IPv6 and UDP.** Neither project probes them today:
   - a connect to `[2606:4700:4700::1111]:443`;
   - a UDP datagram to 1.1.1.1:443 (QUIC);
   - a UDP datagram to the node's address.

## Deliberate differences

- **No recovery window.** OpenShell freezes a workload whose path drops and waits 30 s (10 to
  300 s) for it to return (`boundary_server.rs:3231`, `boundary_protocol.rs:586`). Zigcube kills
  the run at once (B4, "Fail closed"). The relay lives in the supervisor, so nothing can come
  back, and a job is retried by the caller, not resumed.
- **Body inspection.** OpenShell's middleware cannot see compressed bodies, which is a known
  gap. Zigcube's relay never inspects bodies, so the gap does not apply.
- **Live probes.** OpenShell checks its Docker, Kubernetes and microVM fences with unit tests
  only. B3 and B4 probe them live in a VM.

Where: `docs/briefs/b4.md` ("Fail closed" and slices 2 and 4), `docs/demos/b3.md`.
