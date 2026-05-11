#!/usr/bin/env node
// scripts/lib/node/url-pattern-cluster.mjs
//
// Phase 11 part 2-ii. Cluster URLs by templated pathname.
//
// Stdin:  {"urls": ["https://...", ...]}
// Stdout: {"clusters": [{"templated": "/devices/:id", "urls": [...], "count": N}, ...]}
//
// Heuristic:
//   numeric segment   (^[0-9]+$)                                       → :id
//   UUID segment      (8-4-4-4-12 hex)                                 → :uuid
//   slug segment      (^[a-z0-9_]+(-[a-z0-9_]+)+$/i + length ≥ 5)      → :slug
//   other segments    → verbatim
//
// Slug heuristic (Pick A2) — locked decision:
//   - Requires at least ONE hyphen separating alphanumeric groups.
//   - Each side of every hyphen must be ≥1 char of [a-zA-Z0-9_].
//   - Total segment length ≥ 5 chars (filters short codes like `a-b` or
//     `1-2` which are more likely to be opaque identifiers than slugs).
//   - All-numeric is already caught by the numeric branch above (which
//     fires before slug detection in this `if`-chain order).
//
// Cross-site clustering not in scope (caller passes per-site URLs).

let stdin = "";
process.stdin.setEncoding("utf8");
for await (const chunk of process.stdin) stdin += chunk;

let payload;
try {
  payload = JSON.parse(stdin || "{}");
} catch {
  process.stdout.write(JSON.stringify({ clusters: [] }));
  process.exit(0);
}

const urls = Array.isArray(payload.urls) ? payload.urls : [];

const UUID_RE = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
const NUMERIC_RE = /^[0-9]+$/;
const SLUG_RE = /^[a-z0-9_]+(-[a-z0-9_]+)+$/i;
const MIN_SLUG_LEN = 5;

function templatePathname(pathname) {
  // Split preserves the leading "/" as an empty first element.
  const parts = pathname.split("/");
  const templated = parts.map((seg) => {
    if (seg === "") return seg;
    if (UUID_RE.test(seg)) return ":uuid";
    if (NUMERIC_RE.test(seg)) return ":id";
    // Pick A2: slug heuristic. Fires after numeric/UUID; only on hyphenated
    // multi-group segments of length >= MIN_SLUG_LEN.
    if (seg.length >= MIN_SLUG_LEN && SLUG_RE.test(seg)) return ":slug";
    return seg;
  });
  return templated.join("/");
}

const buckets = new Map();
for (const url of urls) {
  if (typeof url !== "string") continue;
  let pathname;
  try {
    pathname = new URL(url, "https://placeholder.local").pathname;
  } catch {
    continue;
  }
  const templated = templatePathname(pathname);
  // Skip URLs whose templated form is identical to the original (no
  // numeric/UUID segment matched) AND that haven't been seen before. This
  // is what filters slug-shaped segments out of cluster proposals.
  // (Identical templates DO still get bucketed if they collide; only the
  // single-occurrence non-template URLs get suppressed below by the
  // threshold filter.)
  const bucket = buckets.get(templated) || [];
  bucket.push(url);
  buckets.set(templated, bucket);
}

// Only emit clusters where the templated form differs from at least one
// constituent URL's pathname — otherwise it's just N copies of the same
// literal URL, which isn't a "pattern".
const clusters = [];
for (const [templated, urlList] of buckets) {
  let hasTemplating = false;
  for (const url of urlList) {
    let pathname;
    try {
      pathname = new URL(url, "https://placeholder.local").pathname;
    } catch {
      continue;
    }
    if (pathname !== templated) {
      hasTemplating = true;
      break;
    }
  }
  if (!hasTemplating) continue;
  clusters.push({ templated, urls: urlList, count: urlList.length });
}

process.stdout.write(JSON.stringify({ clusters }));
