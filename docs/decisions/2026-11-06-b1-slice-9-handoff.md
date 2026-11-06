# B1 slice 9 handoff: the Jobs screen and `?mock=b1`

Date: 2026-11-06. Branch `claude/b1-slice-9`. Console and mock only; no core, API, key or code change.

## Decisions

- **Jobs screens poll every 2 s.** The model's watch covers only `/services/`, `/replicas/`,
  `/assigned/`, `/nodes/`, `/observed/`, `/decisions/`; a job-only revision never wakes it. Widening
  the watch is a model change for a later slice; the poll is the cheap, contained choice. A job page
  stops one read after the job ended.
- **State filter is the server's `state=`**, including `ended`; the name box filters on the page.
- **A non-zero exit and a signal use the red "exited" pill** (`exited_bad`), exit 0 the grey one;
  failures are red "failed". The "Ended with" column carries the detail (`exit 3`, `signal 9`, cause).
- **The spec shows env names only and the input as bytes, `input_env` and a digest prefix**; the
  browser check fails if a value (`s3cr3t-token`) or the input text appears on any job page.
- **Logs: placeholder, no request** (owner answer 4).
- **The mock runs plans**, not a scheduler: each job's node, delays and ending are given by the
  scenario (`web/mock/jobs.js`, `web/mock/scenarios.js`). Waits over 30 s virtual time are kept in a
  timer list the engine's step checks, so a one-hour wait does not keep `settled()` false.
- **Sim mode shows no jobs.** `?sim=c0#/jobs` shows the real core's empty list; the scenario and
  panel cannot submit one, and adding that changes `src/console_wasm.zig`'s scenario. Not done.
- `web/mock/codes.js` was regenerated (`node web/mock/gen-codes.mjs`) so the job codes explain.
- The Why screen now accepts `job` and its step renderer (`stepEl`, `completenessEl`) is exported
  and reused by the job page. Its steps no longer print the text "null" for an absent diagnostic or
  locality line (a latent bug: `append(null)`).

## Gaps to report (not invented)

- (Fixed after review #133.) The mock now writes the scheduler's real `hold_pending` and
  `place_run`, then the controller's `job_placed`, and ends runs as `src/job_controller.zig`
  does: a job never placed by its start-by time, and a placed run never claimed, end
  `failed deadline` with stop cause `not_started`; `failed not_started` is stop `unreachable`
  before any claim. Only the `hold_pending` evidence numbers and the why steps for `/job-runs/`
  and `/assigned/` keys are the mock's. **Possible real gap:** `desired_step` in `src/why.zig`
  reads any key that is not `/replicas/` or `/jobs/` as a Service, and `place_run`,
  `hold_pending` and `job_placed` cite `/job-runs/` and `/assigned/` keys; check that `why job`
  on a real server does not fail on them.
- `CAUSE_TEXT` (the one-line wording of each failure cause in `web/js/views/jobs.js`) follows owner answer 6 and the controller; the
  CLI's wording for `zcube job get` should be the source once it is settled, and the two compared.
- The list has no label filter box (the API takes `label`); only state and name.

## Traps

- `ago()` clamps future times to "just now"; "Start by" is therefore a clock time.
- Mock `at=N` fast-forwards N steps and settles within 60 s virtual.

## What's next

Slice 10 onward per docs/briefs/b1.md. When the real server serves jobs, run
`node tools/browser_check.mjs <url> --mode server` with a submitted job and compare the page to the
mock's.
