// Dev-time helper: regenerates codes.js from the Zigcube registry so the mock's `explain` text
// is the real text. Run from the repo root: node web/mock/gen-codes.mjs
import { readFileSync, writeFileSync } from "node:fs";
const src = readFileSync("src/diag/codes.zig", "utf8");
const body = src.slice(src.indexOf("pub const registry"), src.indexOf("/// The longest tag"));
const out = [];
for (const m of body.matchAll(/\.code = \.(\w+),\s*\.severity = \.(?:@")?(\w+)"?,\s*\.blame = \.(\w+),\s*\.summary = "([^"]*)",\s*\.explanation =\s*((?:\s*\\\\[^\n]*\n)+)/g)) {
  const explanation = m[5].split("\n").map(l => l.trim()).filter(l => l.startsWith("\\\\")).map(l => l.slice(2)).join("\n");
  out.push({ code: "ZC-" + m[1], severity: m[2], blame: m[3], summary: m[4], explanation });
}
const head = "// Generated from src/diag/codes.zig by web/mock/gen-codes.mjs. Do not edit by hand.\n";
writeFileSync("web/mock/codes.js", head + "export const ZC_CODES = " + JSON.stringify(out, null, 2) + ";\n");
console.log(out.length + " codes");
