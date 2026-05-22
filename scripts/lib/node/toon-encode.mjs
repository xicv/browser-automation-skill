#!/usr/bin/env node
// scripts/lib/node/toon-encode.mjs
//
// Phase 12 (TOON output mode amendment, 2026-05-22). Thin Node CLI wrapper
// around the vendored @toon-format/toon encoder. Reads a JSON document on
// stdin and writes the TOON-encoded form on stdout. Exits non-zero on parse
// or encode failure with a single-line error on stderr.
//
// Why a separate binary instead of folding into the bash side: bash can't do
// TOON serialisation safely (escaping/quoting/unicode); jq doesn't speak
// TOON. The reference TOON impl is `@toon-format/toon` (MIT, npm). We vendor
// it under vendor/ to preserve the skill's pre-bundled-node-files pattern
// (no npm install needed at use time — the file is part of the published
// tarball + the git checkout).
//
// Usage:
//   echo '{"foo":"bar","users":[{"id":1,"name":"Alice"}]}' \
//     | node scripts/lib/node/toon-encode.mjs
//
// Exit codes:
//   0 — encoded successfully
//   2 — stdin not valid JSON                    (EXIT_USAGE_ERROR equivalent)
//   3 — encoder threw (invalid TOON-eligible shape, etc.)

import { encode } from './vendor/toon.mjs';

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

(async () => {
  let raw;
  try {
    raw = await readStdin();
  } catch (e) {
    process.stderr.write(`toon-encode: stdin read failed: ${e.message}\n`);
    process.exit(3);
  }
  if (!raw.trim()) {
    process.stderr.write('toon-encode: empty stdin\n');
    process.exit(2);
  }
  let data;
  try {
    data = JSON.parse(raw);
  } catch (e) {
    process.stderr.write(`toon-encode: stdin is not JSON: ${e.message}\n`);
    process.exit(2);
  }
  let out;
  try {
    out = encode(data);
  } catch (e) {
    process.stderr.write(`toon-encode: encode failed: ${e.message}\n`);
    process.exit(3);
  }
  process.stdout.write(out);
  if (!out.endsWith('\n')) process.stdout.write('\n');
})();
