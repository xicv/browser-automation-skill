// scripts/lib/node/playwright-driver.mjs
//
// Node ESM bridge between the playwright-lib bash adapter and the real
// `playwright` package. Speaks skill-flag surface (--url, --ref, --selector,
// --text, --secret-stdin, --depth, --headed, --storage-state) so adapters
// don't have to translate to a binary's positional CLI.
//
// Stub mode (BROWSER_SKILL_LIB_STUB=1):
//   Mirror tests/stubs/playwright-cli — hash argv, look up fixture, print, exit.
//   Lets the bats suite verify the adapter contract without a real browser.
//
// Real mode (default):
//   Lazy-import playwright; launch chromium; optionally apply storageState;
//   dispatch the verb; emit JSON events + final result; close cleanly.
//   Implementation deferred — this file currently throws when stub mode is off
//   so the contract is established but real-mode work lands in a follow-up PR.
//
// Spec: docs/superpowers/specs/2026-04-30-tool-adapter-extension-model-design.md §2
//       docs/superpowers/specs/2026-05-01-token-efficient-adapter-output-design.md §3

import { createHash } from 'node:crypto';
import { readFileSync, existsSync, appendFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const argv = process.argv.slice(2);

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
} else {
  realDispatch(argv);
}

function stubDispatch(args) {
  const logFile = process.env.STUB_LOG_FILE;
  if (logFile) {
    const ts = new Date().toISOString();
    appendFileSync(logFile, `--- ${ts} ---\n${args.join('\n')}\n`);
  }

  const hash = sha256NulJoined(args);
  const fixturesDir =
    process.env.PLAYWRIGHT_LIB_FIXTURES_DIR ||
    join(repoRoot(), 'tests/fixtures/playwright-lib');
  const fixturePath = join(fixturesDir, `${hash}.json`);

  if (existsSync(fixturePath)) {
    process.stdout.write(readFileSync(fixturePath, 'utf-8'));
    process.exit(0);
  }

  const argvJson = JSON.stringify(args);
  process.stdout.write(
    `{"status":"error","reason":"no fixture for argv-hash ${hash}","argv":${argvJson}}\n`
  );
  process.exit(41);
}

function realDispatch(_args) {
  process.stderr.write(
    'playwright-driver.mjs: real mode not yet implemented — set BROWSER_SKILL_LIB_STUB=1 for now\n'
  );
  process.exit(41);
}

function sha256NulJoined(args) {
  const hash = createHash('sha256');
  for (const a of args) {
    hash.update(a, 'utf-8');
    hash.update(Buffer.from([0]));
  }
  return hash.digest('hex');
}

function repoRoot() {
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, '..', '..', '..');
}
