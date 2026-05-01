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
import { createServer, createConnection } from 'node:net';
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
    case 'snapshot':
      return await runSnapshot(flags);
    case 'click':
      return await runClick(flags);
    case 'fill':
      return await runFill(flags);
    case 'daemon-start':
      return await runDaemonStart(flags);
    case 'daemon-stop':
      return runDaemonStop();
    case 'daemon-status':
      return runDaemonStatus();
    case 'login':
      process.stderr.write(
        `playwright-driver.mjs: real mode for verb='${verb}' deferred to Phase 4 part 4d; ` +
          `use BROWSER_SKILL_LIB_STUB=1 or route via --tool=playwright-cli\n`
      );
      process.exit(41);
    default:
      process.stderr.write(`playwright-driver.mjs: unknown verb '${verb}'\n`);
      process.exit(2);
  }
}

// --- Stateful verbs (route through IPC daemon) ---
// chromium.connect()-based clients can't share state across processes.
// The daemon (started via daemon-start) holds browser+context+page+refMap
// internally and exposes verb operations over a Unix socket. Verb processes
// here are thin clients: send one JSON line, read one JSON line, exit.

async function runSnapshot(flags) {
  const reply = await ipcCall({ verb: 'snapshot' });
  emitDaemonReply(reply);
  process.exit(reply.event === 'error' ? 30 : 0);
}

async function runClick(flags) {
  if (!flags.ref) {
    process.stderr.write('playwright-driver.mjs::click: --ref eN is required\n');
    process.exit(2);
  }
  const reply = await ipcCall({ verb: 'click', ref: flags.ref });
  emitDaemonReply(reply);
  process.exit(reply.event === 'error' ? 30 : 0);
}

async function runFill(flags) {
  if (!flags.ref) {
    process.stderr.write('playwright-driver.mjs::fill: --ref eN is required\n');
    process.exit(2);
  }
  let text = flags.text;
  if (flags['secret-stdin']) {
    if (typeof flags.text === 'string') {
      process.stderr.write('playwright-driver.mjs::fill: --text and --secret-stdin are mutually exclusive\n');
      process.exit(2);
    }
    text = await readAllStdin();
  }
  if (typeof text !== 'string' || text.length === 0) {
    process.stderr.write('playwright-driver.mjs::fill: --text VALUE or --secret-stdin required\n');
    process.exit(2);
  }
  const reply = await ipcCall({ verb: 'fill', ref: flags.ref, text });
  // Replace the text field in the reply (defensive; daemon should not echo it).
  delete reply.text;
  emitDaemonReply(reply);
  process.exit(reply.event === 'error' ? 30 : 0);
}

function emitDaemonReply(reply) {
  if (reply.event === 'snapshot' && Array.isArray(reply.refs)) {
    // Compact eN-indexed listing the agent can read directly.
    const summary = { ...reply, ref_count: reply.refs.length };
    delete summary.refs;
    process.stdout.write(JSON.stringify(summary) + '\n');
    for (const r of reply.refs) {
      const tail = r.name ? ` "${r.name}"` : '';
      process.stdout.write(`${r.id} ${r.role}${tail}\n`);
    }
    return;
  }
  process.stdout.write(JSON.stringify(reply) + '\n');
}

async function ipcCall(msg) {
  const state = readDaemonState();
  if (!state || !isPidAlive(state.pid) || !state.ipc_port) {
    process.stderr.write(
      `playwright-driver.mjs: stateful verb '${msg.verb}' requires running daemon ` +
        `(run: node playwright-driver.mjs daemon-start)\n`
    );
    process.exit(41);
  }
  return await new Promise((resolve, reject) => {
    const conn = createConnection({ host: state.ipc_host || '127.0.0.1', port: state.ipc_port });
    let buf = '';
    let settled = false;
    const t = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { conn.destroy(); } catch (_) {}
      reject(new Error(`ipcCall: timeout waiting for daemon reply (verb=${msg.verb})`));
    }, parseInt(process.env.BROWSER_SKILL_LIB_TIMEOUT_MS || '30000', 10));

    conn.on('connect', () => {
      conn.write(JSON.stringify(msg) + '\n');
    });
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf-8');
      const nl = buf.indexOf('\n');
      if (nl < 0 || settled) return;
      settled = true;
      clearTimeout(t);
      try {
        resolve(JSON.parse(buf.slice(0, nl)));
      } catch (e) {
        reject(e);
      } finally {
        try { conn.end(); } catch (_) {}
      }
    });
    conn.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(t);
      reject(e);
    });
  });
}

function readAllStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf-8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
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

  // The daemon HOLDS the browser handle + current context + current page.
  // Verb clients send commands; the daemon mutates this state and replies.
  // This sidesteps the chromium.connect cross-process state-sharing limit.
  const browser = await chromium.connect(wsEndpoint);
  let context = null;
  let page = null;
  let refMap = null;

  // IPC over TCP loopback (not Unix socket) — Unix-socket sun_path is capped
  // at 104 chars on macOS; bats temp paths exceed it. Loopback + random port
  // sidesteps the limit cleanly and matches Playwright's own launchServer
  // which uses ws://localhost:PORT.
  const ipcServer = createServer((conn) => {
    let buf = '';
    conn.setEncoding('utf-8');
    conn.on('data', async (chunk) => {
      buf += chunk;
      let nl;
      while ((nl = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, nl);
        buf = buf.slice(nl + 1);
        if (!line) continue;
        let reply;
        try {
          const msg = JSON.parse(line);
          reply = await dispatch(msg);
        } catch (err) {
          reply = { event: 'error', message: err && err.message ? err.message : String(err) };
        }
        try { conn.write(JSON.stringify(reply) + '\n'); } catch (_) {}
      }
    });
    conn.on('error', () => { /* client closed mid-write; ignore */ });
  });

  async function dispatch(msg) {
    switch (msg.verb) {
      case 'open': {
        if (context) { try { await context.close(); } catch (_) {} }
        const opts = { viewport: { width: 1280, height: 800 } };
        if (msg.viewport)        opts.viewport     = msg.viewport;
        if (msg.storage_state)   opts.storageState = msg.storage_state;
        if (msg.user_agent)      opts.userAgent    = msg.user_agent;
        context = await browser.newContext(opts);
        page = await context.newPage();
        const resp = await page.goto(msg.url, { waitUntil: 'domcontentloaded' });
        return {
          event: 'navigated',
          url: page.url(),
          title: await page.title(),
          status: resp ? resp.status() : null,
          attached_to_daemon: true,
        };
      }
      case 'snapshot': {
        if (!page) return { event: 'error', message: 'no open page (run open --url first)' };
        // Playwright 1.59 dropped page.accessibility. Use ariaSnapshot which
        // returns the agent-readable YAML format, then parse out interactive
        // (role, name) pairs to assign eN refs the agent can click/fill by.
        const yaml = await page.ariaSnapshot();
        const refs = parseAriaSnapshot(yaml);
        refMap = refs;
        try {
          const refsFile = join(browserSkillHome(), 'playwright-lib-refs.json');
          mkdirSync(dirname(refsFile), { recursive: true, mode: 0o700 });
          writeFileSync(refsFile, JSON.stringify({
            page_url: page.url(),
            captured_at: new Date().toISOString(),
            aria_yaml: yaml,
            refs,
          }, null, 2));
          chmodSync(refsFile, 0o600);
        } catch (_) { /* non-fatal */ }
        return { event: 'snapshot', page_url: page.url(), aria_yaml: yaml, refs };
      }
      case 'click': {
        if (!page) return { event: 'error', message: 'no open page' };
        if (!refMap) return { event: 'error', message: 'no refs (run snapshot first)' };
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            message: `ref '${msg.ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        await locatorFor(page, entry).click();
        return { event: 'click', ref: entry.id, role: entry.role, name: entry.name || null, status: 'ok' };
      }
      case 'fill': {
        if (!page) return { event: 'error', message: 'no open page' };
        if (!refMap) return { event: 'error', message: 'no refs (run snapshot first)' };
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return { event: 'error', message: `ref '${msg.ref}' not found in last snapshot` };
        }
        const text = typeof msg.text === 'string' ? msg.text : '';
        // Playwright echoes the fill arg in error logs (e.g. "fill(\"<text>\")"
        // — would leak the secret). Wrap + scrub before returning so the
        // client never sees the secret in any path.
        try {
          await locatorFor(page, entry).fill(text);
        } catch (err) {
          let safeMessage = err && err.message ? err.message : String(err);
          if (text && safeMessage.includes(text)) {
            safeMessage = safeMessage.split(text).join('<redacted>');
          }
          return { event: 'error', message: `fill failed: ${safeMessage}` };
        }
        return {
          event: 'fill',
          ref: entry.id,
          role: entry.role,
          name: entry.name || null,
          text_length: text.length,
          status: 'ok',
        };
      }
      default:
        return { event: 'error', message: `unknown verb '${msg.verb}'` };
    }
  }

  await new Promise((resolve, reject) => {
    ipcServer.listen(0, '127.0.0.1', () => resolve());
    ipcServer.once('error', reject);
  });
  const ipcPort = ipcServer.address().port;

  const state = {
    pid: process.pid,
    ws_endpoint: wsEndpoint,
    ipc_host: '127.0.0.1',
    ipc_port: ipcPort,
    started_at: new Date().toISOString(),
    browser: 'chromium',
    headless,
  };

  const stateFile = daemonStatePath();
  mkdirSync(dirname(stateFile), { recursive: true, mode: 0o700 });
  writeFileSync(stateFile, JSON.stringify(state, null, 2));
  chmodSync(stateFile, 0o600);

  const cleanup = async () => {
    try { await ipcServer.close(); } catch (_) {}
    try { if (context) await context.close(); } catch (_) {}
    try { await browser.close(); } catch (_) {}
    try { await server.close(); } catch (_) {}
    try { unlinkSync(stateFile); } catch (_) {}
    process.exit(0);
  };
  process.on('SIGTERM', cleanup);
  process.on('SIGINT', cleanup);

  // Block forever (until signal).
  await new Promise(() => {});
}

// Roles considered "interactive" for the purposes of assigning eN refs.
// Plus 'heading' (when named) so agents can disambiguate sections.
const INTERACTIVE_ROLES = new Set([
  'button', 'link', 'textbox', 'searchbox', 'combobox',
  'checkbox', 'radio', 'menuitem', 'menuitemcheckbox', 'menuitemradio',
  'option', 'tab', 'switch', 'slider', 'spinbutton',
]);

// Parse Playwright's ariaSnapshot YAML output and emit eN-tagged interactive
// refs. Each line of the form `  - role "name":` or `  - role:` produces a
// (role, name) tuple — we keep only roles agents typically click/fill, plus
// named headings for landmarking.
//
// Example input:
//   - heading "Example Domain" [level=1]
//   - link "Learn more"
//   - paragraph: This domain is for use in documentation examples …
//
// Output: [{id:"e1", role:"heading", name:"Example Domain"},
//          {id:"e2", role:"link", name:"Learn more"}]
function parseAriaSnapshot(yaml) {
  const refs = [];
  let n = 0;
  const re = /^\s*-\s+([a-z][a-z]+)(?:\s+"([^"]*)")?[\s:[]/gm;
  let m;
  while ((m = re.exec(yaml)) !== null) {
    const role = m[1];
    const name = m[2] || '';
    if (INTERACTIVE_ROLES.has(role) || (role === 'heading' && name)) {
      n += 1;
      refs.push({ id: `e${n}`, role, name });
    }
  }
  return refs;
}

function locatorFor(page, entry) {
  // Resolve a Locator from the (role, name) stored in the ref-map. Uses
  // Playwright's getByRole — most stable cross-call locator. Limitation:
  // pages with weak ARIA may have ambiguous (role, name) pairs; .first()
  // picks the first match.
  const opts = {};
  if (entry.name) opts.name = entry.name;
  return page.getByRole(entry.role, opts).first();
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

  // If a daemon with an IPC socket is running, route through it so the
  // context+page persists for subsequent stateful verbs (snapshot/click/fill).
  // Otherwise: one-shot launch + close — useful as a smoke test, no state.
  const daemon = readDaemonState();
  if (daemon && isPidAlive(daemon.pid) && daemon.ipc_port) {
    const reply = await ipcCall({
      verb: 'open',
      url,
      viewport,
      storage_state: storageStatePath || undefined,
      user_agent: userAgent || undefined,
    });
    process.stdout.write(JSON.stringify(reply) + '\n');
    process.exit(reply.event === 'error' ? 30 : 0);
  }

  const browser = await chromium.launch({ headless: !headed });
  const attached = false;
  try {
    const contextOptions = { viewport };
    if (storageStatePath) contextOptions.storageState = storageStatePath;
    if (userAgent)        contextOptions.userAgent    = userAgent;

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
