#!/usr/bin/env node
// scripts/lib/node/url-pattern-resolver.mjs
//
// Phase 11 part 1-i. URL → archetype resolution.
//
// Stdin:  {"patterns":[{"url_pattern":"/devices/:id","archetype_id":"…"}], "url":"https://…"}
// Stdout: {"matched_pattern":"/devices/:id","archetype_id":"devices-detail"}  on hit
//         null                                                                 on miss
//
// First-match-wins (callers reorder patterns to express priority).
// Pattern is a pathname pattern; matched against the URL's pathname (URL
// parsed with a placeholder origin so relative URLs work).
//
// Matcher subset (deliberate; v1):
//   :name   → matches one path segment (non-slash chars)
//   *       → matches any chars including slashes
//   literal → matched verbatim
//
// Why not the URLPattern web standard? Because the global `URLPattern` is
// only stable in Node 23.8+; GitHub Actions runners still default to Node
// 20 (see https://github.blog/changelog/2025-09-19-...). A hand-rolled
// matcher keeps behavior deterministic across all supported Node versions
// and removes the npm-polyfill cost. URLPattern can replace this when the
// CI baseline lifts to Node 24+ (target: mid-2026).

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

// Compile pattern → RegExp. :name matches one segment; * matches anything.
function compile(pattern) {
  // Escape regex metachars EXCEPT the two we re-introduce (`:` and `*`).
  const escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&");
  // :name → [^/]+ (one segment)
  const withNamed = escaped.replace(/:[A-Za-z_][\w$]*/g, "[^/]+");
  // * → .* (anything, slashes included)
  const withStar = withNamed.replace(/\*/g, ".*");
  return new RegExp("^" + withStar + "/?$");
}

for (const p of patterns) {
  if (typeof p?.url_pattern !== "string") continue;
  let re;
  try {
    re = compile(p.url_pattern);
  } catch {
    continue;
  }
  if (re.test(pathname)) {
    process.stdout.write(JSON.stringify({
      matched_pattern: p.url_pattern,
      archetype_id: p.archetype_id,
    }));
    process.exit(0);
  }
}

process.stdout.write("null");
