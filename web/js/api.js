// The API client. One entry point, `get`, over a transport that is either the browser's fetch or
// the mock. Every failure leaves here as an `ApiError` carrying diagnostics: the server's own
// when it sent them, a console-made one (marked `origin: "console"`) when it could not.

export class ApiError extends Error {
  constructor(status, diagnostics, requestId, origin = "server") {
    super(diagnostics[0]?.summary || "request failed");
    this.status = status;
    this.diagnostics = diagnostics;
    this.requestId = requestId;
    this.origin = origin;
  }
  get code() { return this.diagnostics[0]?.code; }
  get aborted() { return false; }
}

export function fetchTransport(base = "") {
  return async (method, path, { signal } = {}) => {
    const res = await fetch(base + path, { method, signal, headers: { accept: "application/json" }, cache: "no-store" });
    let body = null;
    try { body = await res.json(); } catch { body = undefined; }
    return { status: res.status, headers: { "x-request-id": res.headers.get("x-request-id") || "" }, body };
  };
}

function consoleDiagnostic(code, summary, cause, fixes, context = {}) {
  const severity = "error";
  return { code, severity, blame: "environment", summary, causes: [cause], while: [], context, fixes, omitted: { causes: 0, while: 0, context: 0, fixes: 0 } };
}

export function createClient(transport, { origin = location.origin } = {}) {
  async function get(path, { signal } = {}) {
    let res;
    try {
      res = await transport("GET", path, { signal });
    } catch (e) {
      if (e?.name === "AbortError") throw e;
      throw new ApiError(0, [consoleDiagnostic("ZC-E0102", "can't reach zcube-server", `GET ${path.split("?")[0]} failed: ${e?.message || "network error"}`,
        [{ sentence: "check that zcube-server is running and reachable from this browser", command: `curl -fsS ${origin}/v1/status` }],
        { url: origin + path.split("?")[0] })], "", "console");
    }
    const requestId = res.headers["x-request-id"] || res.body?.request_id || "";
    if (res.status >= 200 && res.status < 300) {
      if (res.body === undefined || res.body === null || typeof res.body !== "object") {
        throw new ApiError(res.status, [consoleDiagnostic("ZC-E0103", "zcube-server sent a reply the console can't read", `GET ${path.split("?")[0]} answered ${res.status} with a body that is not a JSON object`,
          [{ sentence: "make sure the console and zcube-server come from the same release", command: "zcube --version" }])], requestId, "console");
      }
      return { body: res.body, requestId };
    }
    const diagnostics = res.body?.diagnostics;
    if (Array.isArray(diagnostics) && diagnostics.length) throw new ApiError(res.status, diagnostics, requestId);
    throw new ApiError(res.status, [consoleDiagnostic("ZC-E0103", "zcube-server sent a reply the console can't read", `GET ${path.split("?")[0]} answered ${res.status} without a diagnostic`,
      [{ sentence: "make sure the console and zcube-server come from the same release", command: "zcube --version" }])], requestId, "console");
  }
  return { get };
}
