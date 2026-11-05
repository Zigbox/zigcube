# B1: the owner's answers to the brief's questions

*Decided 2026-11-05, by the owner.*

Every question in `docs/briefs/b1.md`, "Questions for the owner" (1 to 12), is answered as
recommended there, except question 6:

1. A submission over `jobs_max` is refused at `POST` (ZC-E0132, 429). Over `jobs_per_node_max`
   a job waits in `pending`, up to the start backstop.
2. `retries` above 0 is refused until C8 (ZC-E0130).
3. An ending the agent cannot determine is `failed unknown`, a new cause in the closed set.
4. Logs are cut from B1. Reading the supervisor's log file is a follow-up slice once Zigbox
   states the layout.
5. Job input is the `input` field, stored once in `/job-input/<name>`, at most 64 KiB of UTF-8
   without NUL, given to the container in the variable `input_env` names. `env` is capped at
   8 KiB.
6. **Not as recommended.** Observed and inferred loss are two endings, not one ending with a
   `basis` field: `failed fenced` (the agent reported it stopped the run) and
   `failed unreachable` (the node stopped being heard). A run whose node was lost before any
   claim ends `failed not_started`. The input's name `node_lost` is not kept; clients recode.
7. A deadline counts from the start, on the agent's monotonic clock checked by `boot_id`, with a
   start backstop of the same length from creation.
8. The constants are as listed in question 8.
9. The run id is `<name>-job`.
10. A partition longer than `ttl - fence_margin` kills the node's jobs, as it does replicas.
11. Idempotency: `submit_by_ms` is required, at most 1 h ahead, and retention never deletes an
    ended job younger than 1 h. The simulation and tests run on a controllable clock, so the
    hour-long windows are exercised by advancing time, not by waiting.
12. Job input and env are readable without authentication until mTLS and B3. The server listens
    on a private address, the public job routes and the console never return them, and
    `docs/api.md` says not to put secrets in either until identity lands.

Also decided: Botpike is a customer like any other. Its input informs the design; it does not
override it. Where a clean design differs from what Botpike has coded against, Botpike changes.

Where: `docs/briefs/b1.md`.
