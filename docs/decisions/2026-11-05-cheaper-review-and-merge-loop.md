# A cheaper review-and-merge loop

*Decided 2026-11-05, by the owner.* Amends the merge rule in
`2026-11-05-supervisor-speed-without-spend.md` (Zigcube); that file's other rules stand.

## Decision

1. **Session wake-ups and background checks.** Briefs end by telling the session to notify the
   supervisor's session when it has pushed with `check: PASS` or posted its review (with
   `send_message`, or a one-shot scheduled task into the supervisor's session where it lacks that
   tool). `zig build check` runs in the background with its output in a file, and the session reads
   only the last line.
2. **GitHub's "update branch", not an agent.** When `main` moves under an open pull request, the
   supervisor updates the branch with GitHub's "update branch". An agent is briefed only when that
   reports a conflict.
3. **When a pull request is ready.** Its latest review's verdict is merge, or merge after MUSTs with
   every MUST fixed and checked; `check: PASS` names the last commit a session wrote (a merge
   commit from "update branch" needs none of its own); and CI is green on the head commit. The
   supervisor then merges it (squash, no model names in the message), or enables GitHub
   auto-merge with squash so GitHub does the waiting. Auto-merge is used only once `main` requires
   CI's checks, including the `changes` job; until then the supervisor merges by hand after CI.
   Anything that needs the owner's judgement still goes to the owner first.
4. **Re-reviews read the change.** After a fix, the fresh Opus re-reviewer gets the diff since the
   commit it last reviewed and the earlier findings, not the whole pull request, and is told to
   follow changed code into its callers. The two release reviews stay full reviews of everything
   since the last release.
5. **Haiku for text fixes.** A finding that only touches a pull request description, a README row
   or a decision note, and whose review gives the exact wording, goes to Haiku. One that changes a
   fact (a size, an error code) stays with Sonnet, which checks it against the code.
6. **Short reports.** A session's final report is at most 15 lines: the commit, the gate result
   lines, what was not run, any deviation from the brief, and the handoff note.

## Why

The supervisor's context is the costliest in the setup, because it is re-read every turn, and Opus
re-reviews are the costliest step per cycle. Waiting on CI, on branch updates and on timed
check-ins cost turns without doing work.
