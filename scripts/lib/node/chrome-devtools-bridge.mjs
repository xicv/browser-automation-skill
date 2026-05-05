#!/usr/bin/env node
// scripts/lib/node/chrome-devtools-bridge.mjs
//
// Bridge between the chrome-devtools-mcp adapter (bash) and the upstream
// chrome-devtools-mcp MCP server (`npx chrome-devtools-mcp@latest`, JSON-RPC
// 2.0 NDJSON over stdio). Mirrors `scripts/lib/node/playwright-driver.mjs`
// in shape: stub-mode branch up front, real-mode below.
//
// Stub mode (BROWSER_SKILL_LIB_STUB=1):
//   - No MCP server spawned.
//   - argv hashed (sha256 of args joined+terminated by NUL — matches the
//     `printf '%s\0' "$@" | shasum -a 256` form so fixtures generated for the
//     phase-5 part-1 bash stub work unchanged).
//   - Fixture under ${CHROME_DEVTOOLS_MCP_FIXTURES_DIR} is echoed.
//   - Miss → error JSON + exit 41 (EXIT_TOOL_UNSUPPORTED_OP).
//   - argv logged to ${STUB_LOG_FILE}.
//
// Real mode (default):
//   - Stateless one-shot (open / snapshot / eval / audit, when no daemon):
//     spawn ${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp} per call, initialize,
//     dispatch, exit. Original phase-5 part 1c behaviour.
//   - Daemon mode (phase-5 part 1c-ii): `daemon-start` spawns a detached child
//     that holds ONE long-lived MCP server child + the eN ↔ uid ref map +
//     a TCP loopback IPC server. State written to
//     ${BROWSER_SKILL_HOME}/cdt-mcp-daemon.json (mode 0600, dir 0700).
//   - Stateful verbs (click / fill) require a running daemon — they connect
//     over IPC and translate `ref: eN` → `uid` server-side before tools/call.
//     Without daemon → exit 41 with hint.
//   - Stateful verbs `inspect` / `extract` still exit 41 — bundled with their
//     verb-script counterparts in phase-5 part 1e.
//
// Argv shape: `bridge.mjs <verb> [...args]` — same as the bash adapter passes.
//
// Tests:
//   tests/chrome-devtools-bridge_real.bats       — one-shot real mode (part 1c)
//   tests/chrome-devtools-mcp_daemon_e2e.bats    — daemon + click/fill (part 1c-ii)
// Both invoke this against tests/stubs/mcp-server-stub.mjs (a node script
// speaking the same MCP wire protocol) so CI runs without
// `npx chrome-devtools-mcp@latest` (which needs network + Chrome).

import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import {
  readFileSync, writeFileSync, existsSync, appendFileSync,
  unlinkSync, chmodSync, mkdirSync, openSync,
} from 'node:fs';
import { createServer, createConnection } from 'node:net';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';
import readline from 'node:readline';

const argv = process.argv.slice(2);

// ----------------------------------------------------------------------------
// Stub mode (unchanged from part 1b)
// ----------------------------------------------------------------------------

function stubDispatch(args) {
  const logFile = process.env.STUB_LOG_FILE;
  if (logFile) {
    const ts = new Date().toISOString().replace(/\.\d+Z$/, 'Z');
    let chunk = `--- ${ts} ---\n`;
    for (const a of args) chunk += `${a}\n`;
    appendFileSync(logFile, chunk);
  }

  const data = args.map((a) => a + '\0').join('');
  const hash = createHash('sha256').update(data).digest('hex');

  const here = dirname(fileURLToPath(import.meta.url));
  const fixturesDir =
    process.env.CHROME_DEVTOOLS_MCP_FIXTURES_DIR ||
    join(here, '..', '..', '..', 'tests', 'fixtures', 'chrome-devtools-mcp');
  const fixturePath = join(fixturesDir, `${hash}.json`);

  try {
    process.stdout.write(readFileSync(fixturePath, 'utf8'));
  } catch {
    process.stdout.write(
      JSON.stringify({
        status: 'error',
        reason: `no fixture for argv-hash ${hash}`,
        argv: args,
      }) + '\n'
    );
    process.exit(41);
  }
}

// ----------------------------------------------------------------------------
// Real mode — constants
// ----------------------------------------------------------------------------

const MCP_PROTOCOL_VERSION = '2024-11-05';
const INIT_TIMEOUT_MS = 5000;
const CALL_TIMEOUT_MS = 30000;
const AUDIT_TIMEOUT_MS = 60000;  // lighthouse can take ~30-60s
const SHUTDOWN_TIMEOUT_MS = 5000;
const IPC_TIMEOUT_MS = parseInt(process.env.BROWSER_SKILL_LIB_TIMEOUT_MS || '30000', 10);

// ----------------------------------------------------------------------------
// Real mode — entry dispatcher
// ----------------------------------------------------------------------------

async function realDispatch(args) {
  if (args.length === 0) {
    throw withExit(2, 'bridge: no verb supplied');
  }
  const verb = args[0];
  const verbArgs = args.slice(1);

  // Daemon lifecycle verbs.
  if (verb === 'daemon-start')  return await runDaemonStart(verbArgs);
  if (verb === 'daemon-stop')   return runDaemonStop();
  if (verb === 'daemon-status') return runDaemonStatus();

  // Stateful verbs (click / fill) require a running daemon.
  if (verb === 'click' || verb === 'fill') {
    return await runStatefulViaDaemon(verb, verbArgs);
  }

  // Stateful verbs not yet wired (inspect / extract) — keep the part 1c hint.
  if (verb === 'inspect' || verb === 'extract') {
    process.stderr.write(
      `chrome-devtools-bridge: real-mode verb '${verb}' deferred to phase-05 part 1e ` +
        `(verb scripts + daemon dispatch land together)\n`
    );
    process.exit(41);
  }

  // Stateless verbs (open / snapshot / eval / audit). When daemon is running,
  // route through it so the same MCP server child + state are reused. Without
  // daemon, fall back to one-shot (spawn-per-call) — original part 1c path.
  if (isDaemonAlive()) {
    return await runStatelessViaDaemon(verb, verbArgs);
  }
  return await runStatelessOneShot(verb, verbArgs);
}

// ----------------------------------------------------------------------------
// Stateless one-shot path (verbatim from part 1c — preserved for daemon-off)
// ----------------------------------------------------------------------------

async function runStatelessOneShot(verb, verbArgs) {
  const tx = translateVerb(verb, verbArgs);
  if (tx.tool === null) {
    // Should not happen — caller already filtered click/fill/inspect/extract.
    throw withExit(41, `verb '${verb}' has no MCP tool mapping`);
  }

  const bin = process.env.CHROME_DEVTOOLS_MCP_BIN || 'chrome-devtools-mcp';
  let child;
  try {
    child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  } catch (err) {
    throw withExit(41, `failed to spawn MCP server '${bin}': ${err.message}`);
  }

  let childExited = false;
  let childExitCode = null;
  child.on('exit', (code) => {
    childExited = true;
    childExitCode = code;
  });
  child.on('error', (err) => {
    childExited = true;
    process.stderr.write(`chrome-devtools-bridge: child error: ${err.message}\n`);
  });

  const reader = makeJsonRpcReader(child.stdout);

  try {
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: 'browser-skill', version: '0.10' },
      },
    });
    const initResp = await reader.waitFor(1, INIT_TIMEOUT_MS);
    if (initResp.error) {
      throw withExit(42, `MCP initialize failed: ${initResp.error.message}`);
    }

    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      method: 'notifications/initialized',
    });

    const callTimeout = verb === 'audit' ? AUDIT_TIMEOUT_MS : CALL_TIMEOUT_MS;
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/call',
      params: { name: tx.tool, arguments: tx.args },
    });
    const callResp = await reader.waitFor(2, callTimeout);
    if (callResp.error) {
      throw withExit(42, `MCP tools/call '${tx.tool}' failed: ${callResp.error.message}`);
    }

    const summary = shapeResponse(verb, tx, callResp.result);
    process.stdout.write(JSON.stringify(summary) + '\n');
  } finally {
    try { child.stdin.end(); } catch (_) { /* ignore */ }
    if (!childExited) {
      await waitForExit(child, SHUTDOWN_TIMEOUT_MS).catch(() => {
        try { child.kill('SIGTERM'); } catch (_) { /* ignore */ }
      });
    }
  }

  if (childExitCode !== null && childExitCode !== 0) {
    process.stderr.write(
      `chrome-devtools-bridge: MCP server exited with code ${childExitCode}\n`
    );
  }
}

// ----------------------------------------------------------------------------
// Stateful verbs via daemon IPC
// ----------------------------------------------------------------------------

async function runStatefulViaDaemon(verb, verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      `chrome-devtools-bridge: ${verb} requires running daemon ` +
        `(run: node chrome-devtools-bridge.mjs daemon-start)\n`
    );
    process.exit(41);
  }

  const ref = verbArgs[0];
  if (!ref) throw withExit(2, `verb '${verb}' requires a ref (eN)`);

  if (verb === 'click') {
    const reply = await ipcCall({ verb: 'click', ref });
    emitReply(reply);
    process.exit(reply.status === 'error' ? 30 : 0);
  }
  // fill
  let text = '';
  if (verbArgs[1] === '--secret-stdin') {
    text = await readAllStdin();
    // Strip trailing newline that printf '%s\n' adds — secret should not include it.
    if (text.endsWith('\n')) text = text.slice(0, -1);
  } else if (typeof verbArgs[1] === 'string') {
    text = verbArgs[1];
  } else {
    throw withExit(2, `fill requires text VALUE or --secret-stdin`);
  }
  const reply = await ipcCall({ verb: 'fill', ref, text });
  // Defensive: scrub any echoed text from the reply before emitting.
  if (reply && typeof reply === 'object') delete reply.text;
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

async function runStatelessViaDaemon(verb, verbArgs) {
  // Prepare msg from verbArgs (parallel to translateVerb but for daemon shape).
  let msg;
  switch (verb) {
    case 'open': {
      const url = verbArgs[0] ?? '';
      if (!url) throw withExit(2, "verb 'open' requires a URL");
      msg = { verb: 'open', url };
      break;
    }
    case 'snapshot':
      msg = { verb: 'snapshot' };
      break;
    case 'eval': {
      const script = verbArgs[0] ?? '';
      if (!script) throw withExit(2, "verb 'eval' requires an expression");
      msg = { verb: 'eval', script };
      break;
    }
    case 'audit':
      msg = { verb: 'audit' };
      break;
    default:
      throw withExit(2, `unknown verb: ${verb}`);
  }
  const reply = await ipcCall(msg, verb === 'audit' ? AUDIT_TIMEOUT_MS : IPC_TIMEOUT_MS);
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

function emitReply(reply) {
  process.stdout.write(JSON.stringify(reply) + '\n');
}

// ----------------------------------------------------------------------------
// IPC client
// ----------------------------------------------------------------------------

function ipcCall(msg, timeoutMs) {
  const state = readDaemonState();
  if (!state || !isPidAlive(state.pid) || !state.port) {
    process.stderr.write(
      `chrome-devtools-bridge: ${msg.verb} requires running daemon ` +
        `(run: node chrome-devtools-bridge.mjs daemon-start)\n`
    );
    process.exit(41);
  }
  const t = typeof timeoutMs === 'number' ? timeoutMs : IPC_TIMEOUT_MS;
  return new Promise((resolve, reject) => {
    const conn = createConnection({ host: state.host || '127.0.0.1', port: state.port });
    let buf = '';
    let settled = false;
    const timer = setTimeout(() => {
      if (settled) return;
      settled = true;
      try { conn.destroy(); } catch (_) { /* ignore */ }
      reject(new Error(`ipcCall: timeout waiting for daemon reply (verb=${msg.verb})`));
    }, t);

    conn.on('connect', () => {
      conn.write(JSON.stringify(msg) + '\n');
    });
    conn.on('data', (chunk) => {
      buf += chunk.toString('utf-8');
      const nl = buf.indexOf('\n');
      if (nl < 0 || settled) return;
      settled = true;
      clearTimeout(timer);
      try {
        resolve(JSON.parse(buf.slice(0, nl)));
      } catch (e) {
        reject(e);
      } finally {
        try { conn.end(); } catch (_) { /* ignore */ }
      }
    });
    conn.on('error', (e) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
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

// ----------------------------------------------------------------------------
// Daemon lifecycle (start / stop / status)
// ----------------------------------------------------------------------------

async function runDaemonStart(verbArgs) {
  const isInternalServer = verbArgs.includes('--internal-server');
  if (isInternalServer) {
    return await daemonChildMain();
  }

  const existing = readDaemonState();
  if (existing && isPidAlive(existing.pid)) {
    process.stdout.write(
      JSON.stringify({ event: 'daemon-already-running', ...existing }) + '\n'
    );
    process.exit(0);
  }
  if (existing) {
    try { unlinkSync(daemonStatePath()); } catch (_) { /* ignore */ }
  }

  mkdirSync(browserSkillHome(), { recursive: true, mode: 0o700 });
  const logPath = join(browserSkillHome(), 'cdt-mcp-daemon.log');
  const stderrFd = openSync(logPath, 'a', 0o600);

  const child = spawn(process.execPath, [
    fileURLToPath(import.meta.url),
    'daemon-start',
    '--internal-server',
  ], {
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
    'chrome-devtools-bridge::daemon-start: timed out waiting for daemon to come up ' +
      `(see ${logPath} for child stderr)\n`
  );
  process.exit(30);
}

function runDaemonStop() {
  const state = readDaemonState();
  if (!state) {
    process.stdout.write('{"event":"daemon-not-running"}\n');
    process.exit(0);
  }
  if (isPidAlive(state.pid)) {
    try { process.kill(state.pid, 'SIGTERM'); } catch (_) { /* ignore */ }
  }
  // Wait briefly for daemon to clean up its state file.
  const deadline = Date.now() + 5000;
  while (Date.now() < deadline && existsSync(daemonStatePath())) {
    const now = Date.now();
    while (Date.now() - now < 50) { /* ~50ms tick */ }
  }
  try { unlinkSync(daemonStatePath()); } catch (_) { /* ignore */ }
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

// ----------------------------------------------------------------------------
// Daemon child main — long-lived MCP server child + IPC server + ref map.
// ----------------------------------------------------------------------------

async function daemonChildMain() {
  const bin = process.env.CHROME_DEVTOOLS_MCP_BIN || 'chrome-devtools-mcp';

  let mcpChild;
  try {
    mcpChild = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  } catch (err) {
    process.stderr.write(`daemon: failed to spawn MCP server '${bin}': ${err.message}\n`);
    process.exit(41);
  }
  mcpChild.on('exit', (code) => {
    process.stderr.write(`daemon: MCP server exited (code=${code}); shutting down\n`);
    cleanup().then(() => process.exit(42)).catch(() => process.exit(42));
  });

  const reader = makeJsonRpcReader(mcpChild.stdout);

  // Initialize handshake (once, shared across all subsequent calls).
  await sendJsonRpc(mcpChild.stdin, {
    jsonrpc: '2.0',
    id: 1,
    method: 'initialize',
    params: {
      protocolVersion: MCP_PROTOCOL_VERSION,
      capabilities: {},
      clientInfo: { name: 'browser-skill', version: '0.10' },
    },
  });
  const initResp = await reader.waitFor(1, INIT_TIMEOUT_MS);
  if (initResp.error) {
    process.stderr.write(`daemon: MCP initialize failed: ${initResp.error.message}\n`);
    process.exit(42);
  }
  await sendJsonRpc(mcpChild.stdin, {
    jsonrpc: '2.0',
    method: 'notifications/initialized',
  });

  // Daemon-side state.
  let nextMcpId = 100;
  let refMap = null;

  async function mcpCall(name, callArgs, timeoutMs) {
    const id = ++nextMcpId;
    await sendJsonRpc(mcpChild.stdin, {
      jsonrpc: '2.0',
      id,
      method: 'tools/call',
      params: { name, arguments: callArgs },
    });
    const resp = await reader.waitFor(id, timeoutMs ?? CALL_TIMEOUT_MS);
    if (resp.error) {
      throw new Error(`MCP tools/call '${name}' failed: ${resp.error.message}`);
    }
    return resp.result;
  }

  // IPC server (TCP loopback, ephemeral port — sun_path 104-char cap workaround).
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
          reply = {
            event: 'error',
            status: 'error',
            message: err && err.message ? err.message : String(err),
          };
        }
        try { conn.write(JSON.stringify(reply) + '\n'); } catch (_) { /* ignore */ }
      }
    });
    conn.on('error', () => { /* client closed mid-write; ignore */ });
  });

  async function dispatch(msg) {
    switch (msg.verb) {
      case 'open': {
        const url = msg.url;
        const result = await mcpCall('navigate_page', { url });
        return {
          verb: 'open',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/navigate_page',
          status: result?.isError ? 'error' : 'ok',
          url,
          message: extractText(result),
          attached_to_daemon: true,
        };
      }
      case 'snapshot': {
        const result = await mcpCall('take_snapshot', {});
        const elements = extractSnapshotElements(result);
        const refs = elements.map((el, i) => ({
          id: `e${i + 1}`,
          role: el.role,
          name: el.name,
          uid: el.uid,
        }));
        refMap = refs;
        return {
          verb: 'snapshot',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/take_snapshot',
          status: 'ok',
          refs,
          attached_to_daemon: true,
        };
      }
      case 'click': {
        if (!refMap) {
          return {
            event: 'error',
            verb: 'click',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            verb: 'click',
            ref: msg.ref,
            status: 'error',
            message: `ref '${msg.ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        const result = await mcpCall('click', { uid: entry.uid });
        return {
          verb: 'click',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/click',
          status: result?.isError ? 'error' : 'ok',
          ref: entry.id,
          uid: entry.uid,
          message: extractText(result),
        };
      }
      case 'fill': {
        if (!refMap) {
          return {
            event: 'error',
            verb: 'fill',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            verb: 'fill',
            ref: msg.ref,
            status: 'error',
            message: `ref '${msg.ref}' not found in last snapshot`,
          };
        }
        const text = typeof msg.text === 'string' ? msg.text : '';
        try {
          await mcpCall('fill', { uid: entry.uid, text });
        } catch (err) {
          // Defensive: if the upstream echoes the text in its error, redact.
          let safe = err && err.message ? err.message : String(err);
          if (text && safe.includes(text)) safe = safe.split(text).join('<redacted>');
          return {
            event: 'error',
            verb: 'fill',
            ref: entry.id,
            uid: entry.uid,
            status: 'error',
            message: `fill failed: ${safe}`,
          };
        }
        return {
          verb: 'fill',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/fill',
          status: 'ok',
          ref: entry.id,
          uid: entry.uid,
        };
      }
      case 'eval': {
        const result = await mcpCall('evaluate_script', { script: msg.script });
        return {
          verb: 'eval',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/evaluate_script',
          status: 'ok',
          value: extractText(result),
          attached_to_daemon: true,
        };
      }
      case 'audit': {
        const result = await mcpCall('lighthouse_audit', {}, AUDIT_TIMEOUT_MS);
        return {
          verb: 'audit',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/lighthouse_audit',
          status: 'ok',
          message: extractText(result),
          scores: result?.scores ?? null,
          attached_to_daemon: true,
        };
      }
      default:
        return { event: 'error', status: 'error', message: `unknown verb '${msg.verb}'` };
    }
  }

  await new Promise((resolve, reject) => {
    ipcServer.listen(0, '127.0.0.1', () => resolve());
    ipcServer.once('error', reject);
  });
  const port = ipcServer.address().port;

  const stateFile = daemonStatePath();
  mkdirSync(dirname(stateFile), { recursive: true, mode: 0o700 });
  const state = {
    pid: process.pid,
    host: '127.0.0.1',
    port,
    mcp_bin: bin,
    started_at: new Date().toISOString(),
    schema_version: 1,
  };
  writeFileSync(stateFile, JSON.stringify(state, null, 2));
  chmodSync(stateFile, 0o600);

  let cleanedUp = false;
  async function cleanup() {
    if (cleanedUp) return;
    cleanedUp = true;
    try { ipcServer.close(); } catch (_) { /* ignore */ }
    try { mcpChild.stdin.end(); } catch (_) { /* ignore */ }
    try { mcpChild.kill('SIGTERM'); } catch (_) { /* ignore */ }
    try { unlinkSync(stateFile); } catch (_) { /* ignore */ }
  }
  const onSignal = async () => {
    await cleanup();
    process.exit(0);
  };
  process.on('SIGTERM', onSignal);
  process.on('SIGINT', onSignal);

  // Block forever (until signal).
  await new Promise(() => {});
}

// ----------------------------------------------------------------------------
// Translation + shaping (one-shot real mode)
// ----------------------------------------------------------------------------

function translateVerb(verb, args) {
  switch (verb) {
    case 'open': {
      const url = args[0] ?? '';
      if (!url) throw withExit(2, "verb 'open' requires a URL");
      return { tool: 'navigate_page', args: { url }, verb };
    }
    case 'snapshot':
      return { tool: 'take_snapshot', args: {}, verb };
    case 'eval': {
      const script = args[0] ?? '';
      if (!script) throw withExit(2, "verb 'eval' requires an expression");
      return { tool: 'evaluate_script', args: { script }, verb };
    }
    case 'audit':
      return { tool: 'lighthouse_audit', args: {}, verb };
    case 'click':
    case 'fill':
    case 'inspect':
    case 'extract':
      return { tool: null, args: null, verb };
    default:
      throw withExit(2, `unknown verb: ${verb}`);
  }
}

function shapeResponse(verb, tx, result) {
  const base = {
    verb,
    tool: 'chrome-devtools-mcp',
    why: `mcp/${tx.tool}`,
    status: result?.isError ? 'error' : 'ok',
  };
  switch (verb) {
    case 'open': {
      const text = extractText(result);
      const url = tx.args.url;
      return { ...base, url, message: text };
    }
    case 'snapshot': {
      const elements = extractSnapshotElements(result);
      const refs = elements.map((el, i) => ({
        id: `e${i + 1}`,
        role: el.role,
        name: el.name,
        uid: el.uid,
      }));
      return { ...base, refs };
    }
    case 'eval': {
      const text = extractText(result);
      return { ...base, value: text };
    }
    case 'audit': {
      const text = extractText(result);
      const scores = result?.scores ?? null;
      return { ...base, message: text, scores };
    }
    default:
      return { ...base, raw: result };
  }
}

function extractText(result) {
  const content = result?.content ?? [];
  const textBlock = content.find((b) => b?.type === 'text');
  return textBlock?.text ?? '';
}

function extractSnapshotElements(result) {
  const content = result?.content ?? [];
  const snap = content.find((b) => b?.type === 'snapshot');
  return snap?.elements ?? [];
}

// ----------------------------------------------------------------------------
// JSON-RPC NDJSON over stdio
// ----------------------------------------------------------------------------

function sendJsonRpc(writable, msg) {
  return new Promise((resolve, reject) => {
    const line = JSON.stringify(msg) + '\n';
    writable.write(line, (err) => (err ? reject(err) : resolve()));
  });
}

function makeJsonRpcReader(readable) {
  const pending = new Map();
  const queue = new Map();

  const rl = readline.createInterface({ input: readable, terminal: false });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id === undefined) return;
    const p = pending.get(msg.id);
    if (p) {
      clearTimeout(p.timer);
      pending.delete(msg.id);
      p.resolve(msg);
    } else {
      queue.set(msg.id, msg);
    }
  });

  return {
    waitFor(id, timeoutMs) {
      if (queue.has(id)) {
        const m = queue.get(id);
        queue.delete(id);
        return Promise.resolve(m);
      }
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => {
          pending.delete(id);
          reject(withExit(43, `timeout waiting for MCP response id=${id} after ${timeoutMs}ms`));
        }, timeoutMs);
        pending.set(id, { resolve, reject, timer });
      });
    },
  };
}

function waitForExit(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    if (child.exitCode !== null) return resolve(child.exitCode);
    const timer = setTimeout(() => reject(new Error('child did not exit in time')), timeoutMs);
    child.once('exit', (code) => {
      clearTimeout(timer);
      resolve(code);
    });
  });
}

function withExit(code, message) {
  const err = new Error(message);
  err.exitCode = code;
  return err;
}

// ----------------------------------------------------------------------------
// Daemon state-file helpers
// ----------------------------------------------------------------------------

function browserSkillHome() {
  return process.env.BROWSER_SKILL_HOME || join(homedir(), '.browser-skill');
}

function daemonStatePath() {
  return join(browserSkillHome(), 'cdt-mcp-daemon.json');
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

function isDaemonAlive() {
  const s = readDaemonState();
  return !!(s && isPidAlive(s.pid) && s.port);
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

// ----------------------------------------------------------------------------
// Entry point — placed at end so all top-level `const` declarations above
// have completed initialization before realDispatch's body references them.
// ----------------------------------------------------------------------------

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
  process.exit(0);
}

realDispatch(argv).catch((err) => {
  process.stderr.write(`chrome-devtools-bridge: ${err.message}\n`);
  process.exit(typeof err.exitCode === 'number' ? err.exitCode : 1);
});
