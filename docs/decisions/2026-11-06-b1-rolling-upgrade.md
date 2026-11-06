# B1 needs every agent upgraded before the first job

Date: 2026-11-06. Status: decided for B1 slice 3.

An agent from before B1 reads an Assigned v2 record (a job run) as too new: ZC-E0303. It then
stops reading that node's assignments, so its services stop being reconciled too.

So the first job must not be submitted until every agent runs a B1 build. The rolling upgrade is:
upgrade all agents, check `zcube nodes` shows one version, then submit jobs. The server does not
yet enforce this (no agent version is recorded); it is an operator step and is stated in
docs/api.md's job section when the endpoint ships to users.
