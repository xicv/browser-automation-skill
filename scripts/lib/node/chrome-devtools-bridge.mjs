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
// Real mode (default — phase-5 part 1c):
//   - Spawns ${CHROME_DEVTOOLS_MCP_BIN:-chrome-devtools-mcp} with stdio piped.
//   - Sends initialize handshake (MCP protocolVersion 2024-11-05).
//   - Translates verb argv → MCP tools/call.
//   - Reads response, shapes into skill summary JSON, exits.
//   - Stateless verbs (open / snapshot / eval / audit) work end-to-end.
//   - Stateful verbs (click / fill / inspect / extract) need eN→uid
//     persistence across calls — exit 41 with hint pointing at part 1c-ii.
//
// Argv shape: `bridge.mjs <verb> [...args]` — same as the bash adapter passes.
//
// Tests: tests/chrome-devtools-bridge_real.bats invokes this against
// tests/stubs/mcp-server-stub.mjs (a node script speaking the same MCP wire
// protocol) so CI runs without `npx chrome-devtools-mcp@latest` (which needs
// network + Chrome).

import { createHash } from 'node:crypto';
import { spawn } from 'node:child_process';
import { readFileSync, appendFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
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
// Real mode (phase-5 part 1c)
// ----------------------------------------------------------------------------

const MCP_PROTOCOL_VERSION = '2024-11-05';
const INIT_TIMEOUT_MS = 5000;
const CALL_TIMEOUT_MS = 30000;
const AUDIT_TIMEOUT_MS = 60000;  // lighthouse can take ~30-60s
const SHUTDOWN_TIMEOUT_MS = 5000;

async function realDispatch(args) {
  if (args.length === 0) {
    throw withExit(2, 'bridge: no verb supplied');
  }
  const verb = args[0];
  const verbArgs = args.slice(1);

  const tx = translateVerb(verb, verbArgs);
  if (tx.tool === null) {
    process.stderr.write(
      `chrome-devtools-bridge: real-mode verb '${verb}' deferred to phase-05 part 1c-ii ` +
        `(needs eN→uid state persistence across calls)\n`
    );
    process.exit(41);
  }

  const bin = process.env.CHROME_DEVTOOLS_MCP_BIN || 'chrome-devtools-mcp';
  let child;
  try {
    child = spawn(bin, [], { stdio: ['pipe', 'pipe', 'inherit'] });
  } catch (err) {
    throw withExit(41, `failed to spawn MCP server '${bin}': ${err.message}`);
  }

  // Track child exit so we can fail fast if it dies mid-call.
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
    // 1. Initialize handshake.
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: {
        protocolVersion: MCP_PROTOCOL_VERSION,
        capabilities: {},
        clientInfo: { name: 'browser-skill', version: '0.9' },
      },
    });
    const initResp = await reader.waitFor(1, INIT_TIMEOUT_MS);
    if (initResp.error) {
      throw withExit(42, `MCP initialize failed: ${initResp.error.message}`);
    }

    // Notify server we're initialized (per MCP spec — client → server notification).
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      method: 'notifications/initialized',
    });

    // 2. tools/call
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

    // 3. Shape and emit summary.
    const summary = shapeResponse(verb, tx, callResp.result);
    process.stdout.write(JSON.stringify(summary) + '\n');
  } finally {
    // 4. Clean shutdown.
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

// translateVerb VERB ARGS → {tool, args, verb} or {tool: null} for deferred.
function translateVerb(verb, args) {
  switch (verb) {
    case 'open': {
      // First positional arg is URL (adapter strips --url to positional).
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
      // Stateful — needs eN→uid persistence. Deferred to part 1c-ii.
      return { tool: null, args: null, verb };
    default:
      throw withExit(2, `unknown verb: ${verb}`);
  }
}

// shapeResponse VERB TX MCP_RESULT → skill summary object.
// Translates uid → eN refs at the adapter boundary (token-efficient-output
// spec §5). For non-snapshot verbs, passes through key fields.
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
        uid: el.uid,  // kept for traceability; cdt-mcp's native id
      }));
      return { ...base, refs };
    }
    case 'eval': {
      const text = extractText(result);
      return { ...base, value: text };
    }
    case 'audit': {
      // Lighthouse stub returns scores in result.scores; real upstream may differ.
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

// sendJsonRpc — write a JSON object as a single NDJSON line on the writable.
function sendJsonRpc(writable, msg) {
  return new Promise((resolve, reject) => {
    const line = JSON.stringify(msg) + '\n';
    writable.write(line, (err) => (err ? reject(err) : resolve()));
  });
}

// makeJsonRpcReader — NDJSON line reader keyed by id. Supports waiting for a
// specific id with a timeout. Notifications (no id) are buffered + ignored.
function makeJsonRpcReader(readable) {
  const pending = new Map();   // id → {resolve, reject, timer}
  const queue = new Map();      // id → message (arrived before waitFor)

  const rl = readline.createInterface({ input: readable, terminal: false });
  rl.on('line', (line) => {
    if (!line.trim()) return;
    let msg;
    try { msg = JSON.parse(line); } catch { return; }
    if (msg.id === undefined) return;  // notifications — ignore for now
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
// Entry point — placed at end so all top-level `const` declarations above
// have completed initialization before realDispatch's body references them
// (avoid temporal-dead-zone errors on synchronous reads inside the async fn).
// ----------------------------------------------------------------------------

if (process.env.BROWSER_SKILL_LIB_STUB === '1') {
  stubDispatch(argv);
  process.exit(0);
}

realDispatch(argv).catch((err) => {
  process.stderr.write(`chrome-devtools-bridge: ${err.message}\n`);
  process.exit(typeof err.exitCode === 'number' ? err.exitCode : 1);
});
