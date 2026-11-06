# ZC-E0523: a run's input does not match its digest

Date: 2026-11-06. Status: proposal.

## Problem

The agent fetches a run's input (`GET /v1/runs/{name}/input`) and checks it against the digest in the
run record. Slice 4 first reported both a missing input and a digest mismatch as ZC-E0301
(`raise_malformed`), which blames the user and says the wire form is malformed. Neither is true:
the user submitted a valid job, and the fault is in what the store holds or what the agent read.

## Proposal

Register ZC-E0523, "a run's input does not match its digest".

- Blame `environment`, severity `error`. Blame `internal` would make the code a bug by the registry
  invariant (`internal` if and only if `bug`); a mismatch can come from a damaged store or transfer
  as well as from a defect, so it is not claimed as a bug.
- Raised by the input endpoint when the input key is absent or fails its digest, and by the agent
  when the bytes it read do not match. The agent ends the run as `start_failed` with this
  diagnostic. A store or transport error is not this code: the run stays claimed, not started,
  and the agent retries on a later pass.
- A spec the runtime refuses is ZC-E0130 with the runtime's text, blamed on the user.

Registry entry, golden files and the site page are in the same commit.

Pending the owner's confirmation.
