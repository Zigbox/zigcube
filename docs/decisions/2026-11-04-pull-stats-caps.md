# Pull statistics: a 1,000-record read cap and partial-run pruning

**Decision.** `GET /v1/stats/pull` reads at most `pulls_read_max` = 1,000 records and says
`truncated: true` when it stopped there. Retention keeps a cursor (`continue_after`) across
passes and prunes the part of each node's run it has read.

**Why.** A worst-case record is about 9.7 KB in the arena (key, value and its parse), and the
request arena is 16 MiB; the earlier 6,400 could not fit. `constants.zig` now asserts the whole
worst case at compile time: `pulls_read_max` + 1 records (the list asks each page for no more
than the cap still allows plus one, so no third page of 500 is read at the cap), the response
buffer taken whole (`pulls_response_bytes`, about 2 MiB: an arena frees nothing, so a buffer that
grew would leave about twice its final size behind), the sort order and 64 KiB of slack. That
is about 11 MiB of the 16. A test (`api_test.zig`, "at its read cap with the largest records")
stores 1,005 maximum-size records and checks the arena's whole capacity stays within the limit.
Retention that restarted at the first page starved every node past the first
2,000 records. Pruning a partial run is safe because a record's age does not depend on others,
and a dropped record has at least `pulls_per_node_max` newer ones in the whole set.

**Not done.** A streaming top-K read would give exact newest-first statistics without a cap; the
console and CLI show `truncated` instead. A retention failure is kept in the cursor and printed
once by `server_drive` (the core cannot log). A `pull.json.tmp` left by a crashed fetch child is
not removed: removing it could race a live child.
