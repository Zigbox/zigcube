# Test data

`cli/` holds the golden outputs of every diagnostic (`ZCUBE_GOLDEN_UPDATE`, see `cli_golden.zig`).

`c0_store.txt` holds the live records of a store written by a C0 build (commit `2ed7b80`, before
C1 slice 2 changed any format): `zcube-server` on SQLite and `zcube-agent` with `FakeRuntime`, as
real processes, with `hello` at 3 replicas, every replica process killed with `kill -9` and
replaced, and `ghost` applied with a digest the node does not have (so an observed record carries a
diagnostic). The `store_live` table was dumped with Python's `sqlite3`, one `key<TAB>value` per line,
unedited. Do not regenerate it from a newer build: it is the proof that C0's records still read.

`c1_store.txt` is the same kind of capture from a C1 build (commit `8ff338e`, before C2 slice 2
added `source`; `Service` and `Replica` are version 2 in it): `zcube-server` on SQLite and
`zcube-agent` with `FakeRuntime`, as real processes, with `hello` at 3 replicas with `env` and
`limits`, one replica killed with `kill -9` and replaced (`hello-1` by `hello-4`), and `ghost`
applied with an unknown digest. `store_live` was dumped with Python's `sqlite3`, one
`key<TAB>value` per line, unedited. Never regenerate it: it is the proof that version 2 still reads.

`c2_pulls.txt` holds the three `/pulls/` rows a C2 slice-7 `zig build swarm-smoke` run left in the
server's SQLite store (commit `7bceea3` plus the slice's fixes): node2 from the registry, node1
from node2, node3 from node2 with node1 struck. The rows are what the server stored (each agent's
`--report` file, parsed and encoded again by `agent_api.pull`), dumped with Python's `sqlite3`,
one `key<TAB>value` per line, unedited. Never regenerate it: it is the proof that `Pull` v1 reads.
