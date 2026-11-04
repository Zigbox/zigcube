// Checks the console's Pulls data without a browser (zig build console-pulls):
//   node tools/pulls_check.mjs
// (1) the text helpers agree with the CLI's golden text (src/cli_stats.zig), and (2) the mock
// answers GET /v1/stats/pull as docs/api.md says: empty before any image starts, then one record
// per (node, tree), the second node's pull coming from a peer and not the registry.
import { bytesText, treeShort, tookText, peersText, sourcesText } from "../web/js/pulls_text.js";
import { startMock } from "../web/mock/index.js";

function fail(message) { console.error(`pulls check: ${message}`); process.exit(1); }
function equal(got, want, what) { if (JSON.stringify(got) !== JSON.stringify(want)) fail(`${what}: got ${JSON.stringify(got)}, want ${JSON.stringify(want)}`); }

equal(bytesText(1536), "1Ki", "1536 bytes");
equal(bytesText(0), "0B", "zero");
equal(bytesText(48 * 1048576), "48Mi", "48 MiB");
equal(treeShort("b3:51aa9c03"), "b3:51aa9c03", "a short digest stays whole");
equal(treeShort("b3:" + "ab".repeat(32)), "b3:" + "ab".repeat(6) + "...", "a long digest is cut at 15 bytes");
equal(tookText(0, 4000), "4.0s", "took");
equal(tookText(0, 42000), "42s", "took, ten seconds or more");
const pull = { registry_bytes: 1048576, peer_bytes: [{ peer: "node2", bytes: 2097152 }], cached_bytes: 0, bad_peers: [] };
equal(peersText(pull), "node2=2Mi", "peers text");
equal(sourcesText(pull), "1Mi from the registry, 2Mi from node2, 0B already held", "sources text");

const mock = startMock({ scenario: "c1", at: 0, speed: 1 });
mock.paused = true;
const ask = async path => (await mock.request("GET", path)).body;
equal((await ask("/v1/stats/pull")).pulls, [], "no pulls before an image starts");
const e = mock.engine;
e.recordPull("node1", "b3:51aa9c03");
e.advance(1000);
e.recordPull("node2", "b3:51aa9c03");
e.recordPull("node2", "b3:51aa9c03"); // a second start of the same tree on a node records nothing
const all = (await ask("/v1/stats/pull")).pulls;
equal(all.map(p => p.node), ["node2", "node1"], "newest first");
equal(all[1].registry_bytes > 0 && all[1].peer_bytes.length === 0, true, "the first pull came from the registry");
equal(all[0].registry_bytes === 0 && all[0].peer_bytes[0].peer === "node1", true, "the second pull came from node1");
equal((await ask("/v1/stats/pull?node=node1")).pulls.length, 1, "filter by node");
equal((await ask("/v1/stats/pull?limit=1")).pulls.length, 1, "limit");
const bad = await mock.request("GET", "/v1/stats/pull?limit=0");
equal([bad.status, bad.body.diagnostics[0].code], [400, "ZC-E0104"], "limit 0 is refused");
console.log("pulls check: ok");
process.exit(0);
