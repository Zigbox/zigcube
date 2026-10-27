// Fixtures for the in-browser mock of the proposed Zigcube API (docs/api.md).
// Everything here is illustrative. The diagnostics follow DIAGNOSTICS.md and docs/keys.md; the
// ZBX-E0501 text is HANDOFF's example, since Zigbox's registry is not available to the mock.

import { ZC_CODES } from "./codes.js";

/** Digests the fake runtime knows (HANDOFF: fixtures/images.zon). Anything else fails to start. */
export const KNOWN_IMAGES = new Set(["b3:51aa9c03", "b3:9d20c4f1"]);

export const HELLO = {
  name: "hello",
  image: "b3:51aa9c03",
  command: ["sh", "-c", "while true; do sleep 1; done"],
  env: [["GREETING", "hello"], ["API_TOKEN", "s3cr3t"]],
  limits: { cpu_millis: 500, memory_bytes: 134217728 },
};

export const NODE_CAPACITY = { cpu_millis: 4000, memory_bytes: 8589934592 };
export const LEASE_TTL_MS = 10000;

const omitted = { causes: 0, while: 0, context: 0, fixes: 0 };

export function digestShort(d) {
  return d.length > 14 ? d.slice(0, 7) + "…" + d.slice(-2) : d;
}

export function diagImageNotFound(digest, node, replica) {
  return {
    code: "ZBX-E0501", severity: "error", blame: "user", summary: "image not found",
    causes: [`digest ${digestShort(digest)} is not in this node's store`],
    while: [`starting replica ${replica} on ${node}`],
    context: { node, replica, image: digest },
    fixes: [
      { sentence: "check the digest in broken.zon, or pull the image first" },
      { sentence: "then apply the corrected file", command: "zcube apply broken.zon" },
    ],
    omitted: { ...omitted },
  };
}

export function diagStoreDown(backend) {
  const where = backend === "sqlite" ? "sqlite file /var/lib/zcube/zcube.db" : "postgres at 127.0.0.1:5432";
  return {
    code: "ZC-E0201", severity: "error", blame: "external", summary: "can't reach the store backend",
    causes: ["connection refused", `${where} is not accepting connections`],
    while: ["reading desired state for the request"],
    context: { backend },
    fixes: backend === "sqlite"
      ? [{ sentence: "check the file exists and zcube-server may read it", command: "ls -l /var/lib/zcube/zcube.db" }]
      : [{ sentence: "start it", command: "sudo systemctl start postgresql" },
         { sentence: "check that it is listening", command: "pg_isready -h 127.0.0.1" }],
    omitted: { ...omitted },
  };
}

export function diagCompacted(from, compacted) {
  return {
    code: "ZC-E0203", severity: "error", blame: "user", summary: "that revision was compacted away",
    causes: [`watch asked to resume at revision ${from}, but history before ${compacted + 1} is gone`],
    while: ["resuming a watch"],
    context: { from: String(from), compacted_revision: String(compacted) },
    fixes: [{ sentence: "list the current state and watch again from the revision the list returns" }],
    omitted: { ...omitted },
  };
}

export function diagFutureRevision(from, current) {
  return {
    code: "ZC-E0204", severity: "error", blame: "user", summary: "that revision does not exist yet",
    causes: [`asked for revision ${from}, the store is at ${current}`],
    while: [], context: {}, fixes: [{ sentence: "use a revision returned by this store" }], omitted: { ...omitted },
  };
}

export function diagNotFound(what) {
  return {
    code: "ZC-E0101", severity: "error", blame: "user", summary: "no such resource",
    causes: [`${what} does not exist`], while: [], context: {},
    fixes: [{ sentence: "list what exists", command: "zcube get service" }], omitted: { ...omitted },
  };
}

/** The registry the mock serves from /v1/codes: Zigcube's real codes plus the proposals. */
export const CODES = [
  ...ZC_CODES,
  {
    code: "ZBX-E0501", severity: "error", blame: "user", summary: "image not found",
    explanation: "The runtime on the node has no image with that digest in its store, so the\nreplica cannot start. The digest in the service file is wrong, or the image\nwas never pulled to this node.\n\n(Illustrative text. The real explanation comes from Zigbox's registry.)",
  },
  {
    code: "ZC-E0101", severity: "error", blame: "user", summary: "no such resource",
    explanation: "PROPOSED. The API was asked for a service, replica or node that does not\nexist. Placeholder until the owner assigns the 01xx range.",
  },
  {
    code: "ZC-E0102", severity: "error", blame: "environment", summary: "can't reach zcube-server",
    explanation: "PROPOSED, raised by the console itself. The browser could not complete a\nrequest to zcube-server: it is down, unreachable from this machine, or a\nproxy dropped the connection. Workloads keep running; the console shows the\nlast state it received until the connection comes back.",
  },
  {
    code: "ZC-E0103", severity: "error", blame: "environment", summary: "zcube-server sent a reply the console can't read",
    explanation: "PROPOSED, raised by the console itself. The reply was not JSON, or lacked\nthe fields the API promises. The server and the console are probably\ndifferent versions.",
  },
];
