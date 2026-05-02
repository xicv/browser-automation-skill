#!/usr/bin/env node
// scripts/lib/node/chrome-devtools-bridge.mjs
//
// Bridge between the chrome-devtools-mcp adapter (bash) and the upstream
// chrome-devtools-mcp MCP server (`npx chrome-devtools-mcp@latest`, JSON-RPC
// over stdio). Mirrors `scripts/lib/node/playwright-driver.mjs` in shape:
// stub-mode branch up front, real-mode below.
//
// Stub mode (BROWSER_SKILL_LIB_STUB=1):
//   - No MCP server spawned.
//   - argv hashed (sha256 of args joined+terminated by NUL — matches the
//     `printf '%s\0' "$@" | shasum -a 256` form so fixtures generated for the
//     phase-5 part-1 bash stub work unchanged).
//   - Fixture under ${CHROME_DEVTOOLS_MCP_FIXTURES_DIR} (defaults to
//     tests/fixtures/chrome-devtools-mcp/ relative to this file) is echoed.
//   - Miss → error JSON + exit 41 (EXIT_TOOL_UNSUPPORTED_OP).
//   - argv logged to ${STUB_LOG_FILE} (one arg per line, prefixed by an
//     ISO-8601 separator) so bats argv-shape assertions stay valid.
//
// Real mode (default): NOT IMPLEMENTED in this PR. Throws with a self-healing
// hint pointing at phase-05 part 1c. The MCP wire transport (initialize
// handshake + tools/call) lives there.
//
// Canonical hash form (verify with one-liner):
//   $ printf '%s\0' inspect --capture-console | shasum -a 256
//   af343073058e3234c08e7193ef4da40b433aad63631ecae8119edfe432aa31a5  -
//   $ node -e "const{createHash}=require('crypto'); \
//       console.log(createHash('sha256') \
//         .update(['inspect','--capture-console'].map(a=>a+'\0').join('')) \
//         .digest('hex'))"
//   af343073058e3234c08e7193ef4da40b433aad63631ecae8119edfe432aa31a5

import { createHash } from 'node:crypto';
import { readFileSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
  process.exit(0);
}

throw new Error(
  "chrome-devtools-bridge: real-mode MCP transport deferred to phase-05 part 1c; " +
    "set BROWSER_SKILL_LIB_STUB=1 to use stub mode against tests/fixtures/chrome-devtools-mcp/"
);

function stubDispatch(args) {
  const logFile = process.env.STUB_LOG_FILE;
  if (logFile) {
    const ts = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    let chunk = `--- ${ts} ---\n`;
    for (const a of args) chunk += `${a}\n`;
    appendFileSync(logFile, chunk);
  }

  const data = args.map((a) => a + "\0").join("");
  const hash = createHash("sha256").update(data).digest("hex");

  const here = dirname(fileURLToPath(import.meta.url));
  const fixturesDir =
    process.env.CHROME_DEVTOOLS_MCP_FIXTURES_DIR ||
    join(here, "..", "..", "..", "tests", "fixtures", "chrome-devtools-mcp");
  const fixturePath = join(fixturesDir, `${hash}.json`);

  try {
    process.stdout.write(readFileSync(fixturePath, "utf8"));
  } catch {
    process.stdout.write(
      JSON.stringify({
        status: "error",
        reason: `no fixture for argv-hash ${hash}`,
        argv: args,
      }) + "\n"
    );
    process.exit(41);
  }
}
