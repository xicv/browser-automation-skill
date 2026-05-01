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
import { createRequire } from 'node:module';
import { execSync } from 'node:child_process';

const argv = process.argv.slice(2);

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
} else {
  realDispatch(argv).catch((err) => {
    process.stderr.write(
      `playwright-driver.mjs: unhandled error: ${err && err.stack ? err.stack : String(err)}\n`
    );
    process.exit(1);
  });
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

async function realDispatch(args) {
  const verb = args[0];
  const flags = parseFlags(args.slice(1));

  switch (verb) {
    case 'open':
      return await runOpen(flags);
    case 'snapshot':
    case 'click':
    case 'fill':
    case 'login':
      // Stateful verbs require a long-lived browser the agent can revisit
      // across invocations (e.g. snapshot returns refs that click/fill
      // address later). That's a daemon-mode design — Phase 4 part 4.
      // Until then: stub mode + playwright-cli adapter for these flows.
      process.stderr.write(
        `playwright-driver.mjs: real mode for verb='${verb}' requires daemon mode (Phase 4 part 4); ` +
          `use BROWSER_SKILL_LIB_STUB=1 or route via --tool=playwright-cli\n`
      );
      process.exit(41);
    default:
      process.stderr.write(`playwright-driver.mjs: unknown verb '${verb}'\n`);
      process.exit(2);
  }
}

function parseFlags(args) {
  const out = { _positional: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const key = a.slice(2);
      const next = args[i + 1];
      if (next !== undefined && !next.startsWith('--')) {
        out[key] = next;
        i += 1;
      } else {
        out[key] = true;
      }
    } else {
      out._positional.push(a);
    }
  }
  return out;
}

async function runOpen(flags) {
  const url = flags.url;
  if (!url) {
    process.stderr.write('playwright-driver.mjs::open: --url is required\n');
    process.exit(2);
  }
  const headed = flags.headed === true;
  const viewport = flags.viewport
    ? parseViewport(flags.viewport)
    : { width: 1280, height: 800 };
  const storageStatePath = flags['storage-state'];

  const { chromium } = loadPlaywright();

  const browser = await chromium.launch({ headless: !headed });
  try {
    const contextOptions = { viewport };
    if (storageStatePath) {
      contextOptions.storageState = storageStatePath;
    }
    if (flags['user-agent']) {
      contextOptions.userAgent = flags['user-agent'];
    }
    const context = await browser.newContext(contextOptions);
    const page = await context.newPage();

    const response = await page.goto(url, { waitUntil: 'domcontentloaded' });
    const title = await page.title();
    const finalUrl = page.url();

    process.stdout.write(
      JSON.stringify({
        event: 'navigated',
        url: finalUrl,
        title,
        status: response ? response.status() : null,
      }) + '\n'
    );

    await context.close();
    await browser.close();
    process.exit(0);
  } catch (err) {
    try {
      await browser.close();
    } catch (_) {}
    process.stderr.write(
      `playwright-driver.mjs::open: ${err && err.message ? err.message : String(err)}\n`
    );
    process.exit(30); // EXIT_NETWORK_ERROR
  }
}

// loadPlaywright resolves the `playwright` package by walking up from the
// driver's location (project node_modules), then falling back to the npm
// global root (BROWSER_SKILL_NPM_GLOBAL or `npm root -g`). Necessary because
// users typically install playwright globally, but ESM `import('playwright')`
// only walks up from the script's directory — not into ~/global node_modules.
function loadPlaywright() {
  const req = createRequire(import.meta.url);

  // First try local resolution (works if a project node_modules exists).
  try {
    return req('playwright');
  } catch (_) {
    // Fall through to global lookup.
  }

  let npmRoot = process.env.BROWSER_SKILL_NPM_GLOBAL;
  if (!npmRoot) {
    try {
      npmRoot = execSync('npm root -g', { encoding: 'utf-8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
    } catch (_) {
      process.stderr.write(
        'playwright-driver.mjs: cannot locate `playwright` — install it (`npm i -g playwright && playwright install chromium`)\n'
      );
      process.exit(21); // EXIT_TOOL_MISSING
    }
  }

  try {
    return req(join(npmRoot, 'playwright'));
  } catch (err) {
    process.stderr.write(
      `playwright-driver.mjs: cannot load playwright from ${npmRoot}: ${err && err.message ? err.message : err}\n`
    );
    process.exit(21);
  }
}

function parseViewport(spec) {
  const m = /^(\d+)x(\d+)$/.exec(spec);
  if (!m) {
    process.stderr.write(`--viewport must be WxH (got: ${spec})\n`);
    process.exit(2);
  }
  return { width: parseInt(m[1], 10), height: parseInt(m[2], 10) };
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
