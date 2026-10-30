# Test data

`cli/` holds the golden outputs of every diagnostic (`ZCUBE_GOLDEN_UPDATE`, see `cli_golden.zig`).

`c0_store.txt` holds the live records of a store written by a C0 build (commit `2ed7b80`, before
C1 slice 2 changed any format): `zcube-server` on SQLite and `zcube-agent` with `FakeRuntime`, as
real processes, with `hello` at 3 replicas, every replica process killed with `kill -9` and
replaced, and `ghost` applied with a digest the node does not have (so an observed record carries a
diagnostic). The `store_live` table was dumped with Python's `sqlite3`, one `key<TAB>value` per line,
unedited. Do not regenerate it from a newer build: it is the proof that C0's records still read.
