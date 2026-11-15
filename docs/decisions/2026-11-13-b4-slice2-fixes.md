# B4 slice 2: fixes from the two reviews of 2b6ea66

*Decided 2026-11-13, by the supervisor (rulings) and the slice (fix session).*

The two reviews of B4 slice 2 (2b6ea66) found four MUSTs. This file records how each was fixed,
the supervisor's rulings, and what is left to slice 3 and slice 4.

## A refusal that is only "not yet" is 503, not 409 (ruling a)

The server refused a run's certificate with 409 ZC-E0706 when no node had claimed the run yet, or
when the claim had no start yet. The agent took that 409 as final and wrote `relay.refused`. It
also asked before its own `running` report had landed, so every new relayed run was refused for
good.

- ZC-E0706 stays the only code: no ZC-E0707. Its two transient causes (`no_claim`, `not_started`)
  are answered **503**. The other refusals stay 409. A structural flag, `Diag.settling`, which is
  never rendered, overrides `status_for` in `api.error_response`. It is allowed only with blame
  `environment`.
- The agent writes `relay.refused` only on 409 with ZC-E0706. A 503 with ZC-E0706 is deferred
  without a word, and that container is asked again after `peer_join_retry_ms`.
- The agent asks only for a run whose `running` report it knows the server holds (the
  `running_reported` ring in `agent.zig` and `agent_jobs.zig`).
- ZC-E0706's explanation names the two transient causes.

Upgrade order: the server first. An agent from before these fixes reads the server's 409 for
`not_started` as final. B4 is unreleased, so no deployed pair is affected.

## The certificate step is bounded, and per container

- `relay_cert_asks_per_step_max` (8) caps the asks of one step.
- Each ask gets what is left of the step's time before the fence, recomputed before each ask
  (`Host.left_fn`; the step's share is at most `relay_cert_step_ms_max`, which is
  `peer_join_timeout_ms`). At 0 the step ends. This replaces a `before_fence` computed once.
- A failed ask defers only its own container, for `peer_join_retry_ms`, in a ring of
  `agent_node_runs_max` entries. The step goes on to the next container.
- Tests in `agent_relay_certs_test.zig`: a 503 is deferred, a run not yet reported is skipped,
  the step continues past a failed container, a slow server gets at most 4 calls, and the cap
  holds.

## The zigbox runtime fails closed (#228)

`zigbox_supervisor.open_relay` ignored the relay's server name and anchor, and would have
connected in plaintext without the run's identity. Until B4 slice 4 brings TLS there, it refuses
to serve:

- a relay that names a server;
- a relay with neither a server name nor `.plain` (a job submitted before B4);
- a plain relay in a release build.

Each refusal kills the container and writes ZC-E0702 with that cause to `relay.log`.

ZC-E0702's summary is now "a job's relay could not be served". Its explanation covers the three
causes and both endings, with no new code. The errors site and the CLI goldens are regenerated.

## demo-b3 runs Debug binaries until slice 4 (ruling B2)

Under the fail-closed rule, demo-b3's relayed jobs would be killed at their start. Its eight
isolation checks would then hold only vacuously. They were not cut. Instead:

- demo-b3's `zcube-server` and `zcube-agent` are built Debug, whatever `-Doptimize` says
  (`build.zig`, `built_debug`, not installed). Its relay `botpike` is `.plain = true` and leads
  to the plain-TCP test upstream on the guest's loopback. That upstream is test-only and is
  reached only from the demo.
- Section 0 of the transcript says so in one line.
- Release builds still refuse `.plain`: `demo-b3-build`, which is in `check`, runs the tests
  named `relay plain:` (in `server_config.zig` and `zigbox_supervisor.zig`) in ReleaseSafe.
- Every assertion of demo-b3 is kept.

**Slice 4's acceptance items.**

- demo-b3 runs ReleaseSafe binaries again (the `built_debug` set is removed).
- `botpike` is a TLS upstream that pins the cluster CA and the job.
- Every isolation assertion and the positive path (the report through the relay, read by the
  upstream) still hold.

The fix session did not run demo-b3: its container has no KVM.

## relay-teeth bite in every mode

`zig build relay-teeth` builds its broken agents and the tests in Debug, whatever `-Doptimize`
says. Under ReleaseSafe, the plain test upstream the tests use is refused. Each test would then
fail on that refusal, and the step would pass without biting.

## Left to slice 3: the clock a certificate is issued on

`job_cert.decide` sets `not_before` to the server's now, but it computes `not_after` from
`@min(started, ask.now_ms)` plus the job's deadline and grace. `started` is the agent's clock,
from its `running` report.

- A node whose clock runs behind gets a shorter certificate. Near the deadline, it may be
  refused for its lifetime.
- A node whose clock runs ahead is clamped to the server's now. Its certificate can outlive the
  run's true deadline by the skew.

This is not on any path these fixes touch, so it is noted for slice 3 rather than changed here.
Slice 3 should decide whether issuance uses the server's clock only.

Where: `docs/api.md` (the certificate endpoint), `docs/agent.md` (the agent's certificate step),
`docs/demos/b3.md`, `src/agent_relay_certs.zig`, `src/zigbox_supervisor.zig`, `build.zig`.
