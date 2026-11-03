# C2 slice 3 (P2, approved): Runtime.signal(Handle, number), TERM or KILL only, delivers and never waits; stop stays for the reconcile loop's pending stops

*Decided 2026-11-03.*

C2 slice 3 (P2, approved): `Runtime.signal(Handle, number)`, TERM or KILL only, delivers and never waits; `stop` stays for the reconcile loop's pending stops. The fence signals every container, then looks at the runtime until one deadline and kills the rest. This closes known gap (1) of the 2026-11-02 row (stop blocks, a fence costs N waits). Sim-c0 fuzz counters move slightly (docs/core.md).

Where: docs/briefs/c2-3.md, docs/core.md
