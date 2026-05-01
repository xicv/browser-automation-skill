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
import { readFileSync, writeFileSync, existsSync, appendFileSync, unlinkSync, chmodSync, mkdirSync, openSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
import { execSync, spawn } from 'node:child_process';
import { homedir } from 'node:os';

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
    case 'daemon-start':
      return await runDaemonStart(flags);
    case 'daemon-stop':
      return runDaemonStop();
    case 'daemon-status':
      return runDaemonStatus();
    case 'snapshot':
    case 'click':
    case 'fill':
    case 'login':
      process.stderr.write(
        `playwright-driver.mjs: real mode for verb='${verb}' deferred to Phase 4 part 4b; ` +
          `use BROWSER_SKILL_LIB_STUB=1 or route via --tool=playwright-cli\n`
      );
      process.exit(41);
    default:
      process.stderr.write(`playwright-driver.mjs: unknown verb '${verb}'\n`);
      process.exit(2);
  }
}

// --- Daemon lifecycle ---
// daemon-start spawns a detached node child that calls launchServer (chromium)
// and writes ${BROWSER_SKILL_HOME}/playwright-lib-daemon.json with PID +
// wsEndpoint. The parent process polls the state file (up to 10s), prints
// the state, and exits. Subsequent verb invocations connect via the
// wsEndpoint. daemon-stop SIGTERMs the PID and removes the state file.
//
// State file mode 0600; directory mode 0700 (matches BROWSER_SKILL_HOME).

async function runDaemonStart(flags) {
  if (flags['internal-server'] === true) {
    return await daemonChildMain(flags);
  }

  const existing = readDaemonState();
  if (existing && isPidAlive(existing.pid)) {
    process.stdout.write(
      JSON.stringify({ event: 'daemon-already-running', ...existing }) + '\n'
    );
    process.exit(0);
  }

  // Stale state file (PID dead) — clear it before spawning.
  if (existing) {
    try { unlinkSync(daemonStatePath()); } catch (_) {}
  }

  const childArgv = [
    fileURLToPath(import.meta.url),
    'daemon-start',
    '--internal-server',
  ];
  if (flags.headed) childArgv.push('--headed');

  // Capture daemon child stderr to a log under BROWSER_SKILL_HOME instead of
  // /dev/null so launch failures aren't silent. The log is gitignored
  // (.browser-skill/captures pattern); mode 0600 inherits from parent dir.
  mkdirSync(browserSkillHome(), { recursive: true, mode: 0o700 });
  const logPath = join(browserSkillHome(), 'playwright-lib-daemon.log');
  const stderrFd = openSync(logPath, 'a', 0o600);

  const child = spawn(process.execPath, childArgv, {
    detached: true,
    stdio: ['ignore', 'ignore', stderrFd],
    env: process.env,
  });
  child.unref();

  const stateFile = daemonStatePath();
  const deadline = Date.now() + 10000;
  while (Date.now() < deadline) {
    if (existsSync(stateFile)) {
      const state = readDaemonState();
      if (state && isPidAlive(state.pid)) {
        process.stdout.write(
          JSON.stringify({ event: 'daemon-started', ...state }) + '\n'
        );
        process.exit(0);
      }
    }
    await sleep(100);
  }

  process.stderr.write(
    'playwright-driver.mjs::daemon-start: timed out waiting for daemon to come up\n'
  );
  process.exit(30);
}

async function daemonChildMain(flags) {
  const { chromium } = loadPlaywright();
  const headless = !flags.headed;
  const server = await chromium.launchServer({ headless });
  const wsEndpoint = server.wsEndpoint();

  const state = {
    pid: process.pid,
    ws_endpoint: wsEndpoint,
    started_at: new Date().toISOString(),
    browser: 'chromium',
    headless,
  };

  const stateFile = daemonStatePath();
  mkdirSync(dirname(stateFile), { recursive: true, mode: 0o700 });
  writeFileSync(stateFile, JSON.stringify(state, null, 2));
  chmodSync(stateFile, 0o600);

  const cleanup = async () => {
    try { await server.close(); } catch (_) {}
    try { unlinkSync(stateFile); } catch (_) {}
    process.exit(0);
  };
  process.on('SIGTERM', cleanup);
  process.on('SIGINT', cleanup);

  // Block forever (until signal).
  await new Promise(() => {});
}

function runDaemonStop() {
  const state = readDaemonState();
  if (!state) {
    process.stdout.write('{"event":"daemon-not-running"}\n');
    process.exit(0);
  }
  if (isPidAlive(state.pid)) {
    try { process.kill(state.pid, 'SIGTERM'); } catch (_) {}
  }
  // Brief wait for the daemon to clean up its state file.
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && existsSync(daemonStatePath())) {
    // Busy-wait — sleep helper is async; sync wait is fine for ≤5s shutdown.
    const now = Date.now();
    while (Date.now() - now < 50) { /* ~50ms tick */ }
  }
  try { unlinkSync(daemonStatePath()); } catch (_) {}
  process.stdout.write(
    JSON.stringify({ event: 'daemon-stopped', pid: state.pid }) + '\n'
  );
  process.exit(0);
}

function runDaemonStatus() {
  const state = readDaemonState();
  if (state && isPidAlive(state.pid)) {
    process.stdout.write(
      JSON.stringify({ event: 'daemon-running', ...state }) + '\n'
    );
    process.exit(0);
  }
  process.stdout.write('{"event":"daemon-not-running"}\n');
  process.exit(0);
}

function browserSkillHome() {
  return process.env.BROWSER_SKILL_HOME || join(homedir(), '.browser-skill');
}

function daemonStatePath() {
  return join(browserSkillHome(), 'playwright-lib-daemon.json');
}

function readDaemonState() {
  const p = daemonStatePath();
  if (!existsSync(p)) return null;
  try {
    return JSON.parse(readFileSync(p, 'utf-8'));
  } catch (_) {
    return null;
  }
}

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
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
  const userAgent = flags['user-agent'];

  const { chromium } = loadPlaywright();

  // If daemon is running, attach to it and create a new context. Page
  // persists in the daemon process for subsequent verbs (snapshot/click/fill
  // in part 4b). If no daemon, do a one-shot launch + close — useful as a
  // smoke test but no state for later verbs to use.
  const daemon = readDaemonState();
  const useDaemon = daemon && isPidAlive(daemon.pid);

  let browser, attached = false;
  if (useDaemon) {
    browser = await chromium.connect(daemon.ws_endpoint);
    attached = true;
  } else {
    browser = await chromium.launch({ headless: !headed });
  }

  try {
    const contextOptions = { viewport };
    if (storageStatePath) contextOptions.storageState = storageStatePath;
    if (userAgent)        contextOptions.userAgent    = userAgent;

    // When attached: close any pre-existing contexts so the agent's
    // "current context" is unambiguous (snapshot picks the most-recent).
    if (attached) {
      for (const old of browser.contexts()) {
        try { await old.close(); } catch (_) {}
      }
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
        attached_to_daemon: attached,
      }) + '\n'
    );

    if (attached) {
      // Disconnect — context + page stay alive in the daemon.
      await browser.close();
    } else {
      await context.close();
      await browser.close();
    }
    process.exit(0);
  } catch (err) {
    try { await browser.close(); } catch (_) {}
    process.stderr.write(
      `playwright-driver.mjs::open: ${err && err.message ? err.message : String(err)}\n`
    );
    process.exit(30);
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
