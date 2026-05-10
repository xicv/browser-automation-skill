#!/usr/bin/env node
// scripts/lib/node/url-pattern-resolver.mjs
//
// Phase 11 part 1-i. URL → archetype resolution via web-standard URLPattern API
// (Node 20+, no npm deps).
//
// Stdin:  {"patterns":[{"url_pattern":"/devices/:id","archetype_id":"…"}], "url":"https://…"}
// Stdout: {"matched_pattern":"/devices/:id","archetype_id":"devices-detail"}  on hit
//         null                                                                 on miss
//
// First-match-wins (callers reorder patterns to express priority).
// Pattern is interpreted as a pathname pattern; the URL's pathname is the test
// surface. Relative URLs are parsed against a placeholder origin so they work.

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;

let payload;
try {
  payload = JSON.parse(stdin || "{}");
} catch {
  process.stdout.write("null");
  process.exit(0);
}

const patterns = Array.isArray(payload.patterns) ? payload.patterns : [];
const url = typeof payload.url === "string" ? payload.url : "";

let pathname;
try {
  pathname = new URL(url, "https://placeholder.local").pathname;
} catch {
  process.stdout.write("null");
  process.exit(0);
}

for (const p of patterns) {
  if (typeof p?.url_pattern !== "string") continue;
  let pat;
  try {
    pat = new URLPattern({ pathname: p.url_pattern });
  } catch {
    continue;
  }
  if (pat.test({ pathname })) {
    process.stdout.write(JSON.stringify({
      matched_pattern: p.url_pattern,
      archetype_id: p.archetype_id,
    }));
    process.exit(0);
  }
}

process.stdout.write("null");
