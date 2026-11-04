// Pure text helpers of the Pulls screen (no DOM, so tools/pulls_check.mjs runs them in Node).

const UNITS = ["B", "Ki", "Mi", "Gi", "Ti"];

/** Bytes as the CLI shows them: whole units, "1Mi", "1536" is "1Ki". */
export function bytesText(n) {
  let v = Number(n) || 0, u = 0;
  while (v >= 1024 && u < UNITS.length - 1) { v = Math.floor(v / 1024); u++; }
  return `${v}${UNITS[u]}`;
}

/** The digest cut to 15 bytes and "..." as the CLI does; the full value stays one click away. */
export function treeShort(tree) { return tree.length > 15 ? `${tree.slice(0, 15)}...` : tree; }

/** Seconds, one decimal under ten, as `took`. */
export function tookText(startedMs, finishedMs) {
  const ms = Math.max(0, finishedMs - startedMs);
  return ms < 10000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.round(ms / 1000)}s`;
}

/** Total bytes the peers gave. */
export function peersTotal(pull) { return pull.peer_bytes.reduce((a, p) => a + p.bytes, 0); }

/** `node2=2Mi,node4=1Mi`: the wide column and the copyable text. */
export function peersText(pull) { return pull.peer_bytes.map(p => `${p.peer}=${bytesText(p.bytes)}`).join(","); }

/** Where a pull's bytes came from, as one sentence for the expanded row. */
export function sourcesText(pull) {
  const parts = [`${bytesText(pull.registry_bytes)} from the registry`];
  for (const p of pull.peer_bytes) parts.push(`${bytesText(p.bytes)} from ${p.peer}`);
  parts.push(`${bytesText(pull.cached_bytes)} already held`);
  return parts.join(", ");
}
