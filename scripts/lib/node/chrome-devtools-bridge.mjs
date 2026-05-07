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

  // Stateful verbs (click / fill / select / hover / drag / upload) require a
  // running daemon — refMap precondition.
  if (verb === 'click' || verb === 'fill' || verb === 'select'
      || verb === 'hover' || verb === 'drag' || verb === 'upload') {
    return await runStatefulViaDaemon(verb, verbArgs);
  }

  // route is daemon-state-mutating (registers rules in the daemon's
  // routeRules slot). Daemon-required (like the stateful verbs above) but
  // doesn't depend on refMap.
  if (verb === 'route') {
    return await runRouteViaDaemon(verbArgs);
  }

  // tab-list is read-only enumeration but daemon-required so it can cache
  // results in the daemon's `tabs` slot (8-ii / 8-iii will mutate the same
  // slot — landing 8-i daemon-required avoids retroactively changing the
  // contract later). No args.
  if (verb === 'tab-list') {
    return await runTabListViaDaemon(verbArgs);
  }

  // tab-switch is the first state-mutation on tabs[] — adds currentTab
  // pointer (1-based tab_id). Mutex selector: --by-index N | --by-url-pattern.
  if (verb === 'tab-switch') {
    return await runTabSwitchViaDaemon(verbArgs);
  }

  // tab-close splices from tabs[] + closes upstream page + nulls currentTab
  // on match. Mutex selector: --tab-id N | --by-url-pattern STR.
  if (verb === 'tab-close') {
    return await runTabCloseViaDaemon(verbArgs);
  }

  // Multi-call verbs (inspect / extract) — phase-05 part 1e-ii. Route through
  // daemon if running (shared long-lived MCP child); otherwise spawn one-shot
  // and run all sub-calls before shutdown.
  if (verb === 'inspect' || verb === 'extract') {
    return await runInspectOrExtract(verb, verbArgs);
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
    child = spawn(bin, mcpSpawnArgs(), { stdio: ['pipe', 'pipe', 'inherit'] });
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

// runTabListViaDaemon — read-only enumeration of tabs/pages held by the
// daemon. No args. Daemon-side dispatch calls upstream MCP `list_pages`,
// normalizes to [{tab_id, url, title}], caches in `tabs` slot, returns.
async function runTabListViaDaemon(_verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      'chrome-devtools-bridge: tab-list requires running daemon ' +
        '(run: node chrome-devtools-bridge.mjs daemon-start)\n'
    );
    process.exit(41);
  }
  const reply = await ipcCall({ verb: 'tab-list' });
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

// runTabCloseViaDaemon — close a tab. Mutex selectors (already enforced
// bash-side; bridge re-validates). Argv shape: `tab-close --tab-id N` |
// `tab-close --by-url-pattern STR`. Daemon splices the matching entry from
// tabs[], asks upstream MCP to close the page, nulls currentTab on match.
async function runTabCloseViaDaemon(verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      'chrome-devtools-bridge: tab-close requires running daemon ' +
        '(run: node chrome-devtools-bridge.mjs daemon-start)\n'
    );
    process.exit(41);
  }
  const msg = { verb: 'tab-close' };
  for (let i = 0; i < verbArgs.length; i++) {
    if (verbArgs[i] === '--tab-id')          msg.tab_id = parseInt(verbArgs[++i], 10);
    if (verbArgs[i] === '--by-url-pattern')  msg.by_url_pattern = verbArgs[++i];
  }
  if (msg.tab_id === undefined && msg.by_url_pattern === undefined) {
    throw withExit(2, 'tab-close requires --tab-id N or --by-url-pattern STR');
  }
  if (msg.tab_id !== undefined && msg.by_url_pattern !== undefined) {
    throw withExit(2, '--tab-id and --by-url-pattern are mutually exclusive');
  }
  const reply = await ipcCall(msg);
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

// runTabSwitchViaDaemon — switch active tab. Mutex on the two selectors,
// already enforced bash-side; bridge re-validates defensively. Argv shape:
// `tab-switch --by-index N` | `tab-switch --by-url-pattern STR`. Daemon
// resolves selector to tab_id, calls MCP select_page, updates currentTab.
async function runTabSwitchViaDaemon(verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      'chrome-devtools-bridge: tab-switch requires running daemon ' +
        '(run: node chrome-devtools-bridge.mjs daemon-start)\n'
    );
    process.exit(41);
  }
  const msg = { verb: 'tab-switch' };
  for (let i = 0; i < verbArgs.length; i++) {
    if (verbArgs[i] === '--by-index')        msg.by_index = parseInt(verbArgs[++i], 10);
    if (verbArgs[i] === '--by-url-pattern')  msg.by_url_pattern = verbArgs[++i];
  }
  if (msg.by_index === undefined && msg.by_url_pattern === undefined) {
    throw withExit(2, 'tab-switch requires --by-index N or --by-url-pattern STR');
  }
  if (msg.by_index !== undefined && msg.by_url_pattern !== undefined) {
    throw withExit(2, '--by-index and --by-url-pattern are mutually exclusive');
  }
  const reply = await ipcCall(msg);
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

// runRouteViaDaemon — register a network-route rule in the daemon. Args
// shape from adapter: `route <pattern> <action> [--status N] [--body STR | --body-stdin]`.
// Daemon stores {pattern, action} (block | allow) or
// {pattern, action: 'fulfill', status, body} in routeRules and best-effort
// calls MCP route_url tool.
//
// Phase 6 part 7-ii: fulfill action adds synthetic responses. Body via
// --body-stdin reads from this process's stdin (passthrough from
// browser-route.sh, mirrors fill --secret-stdin). Body verbatim — no trailing
// newline strip (HTTP bodies are content, not credentials).
async function runRouteViaDaemon(verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      'chrome-devtools-bridge: route requires running daemon ' +
        '(run: node chrome-devtools-bridge.mjs daemon-start)\n'
    );
    process.exit(41);
  }
  const pattern = verbArgs[0];
  const action = verbArgs[1];
  if (!pattern) throw withExit(2, "route requires <pattern>");
  if (!action) throw withExit(2, "route requires <action>");
  const msg = { verb: 'route', pattern, action };
  let useBodyStdin = false;
  let bodyInline;
  for (let i = 2; i < verbArgs.length; i++) {
    switch (verbArgs[i]) {
      case '--status': msg.status = Number(verbArgs[++i]); break;
      case '--body':   bodyInline = verbArgs[++i]; break;
      case '--body-stdin': useBodyStdin = true; break;
      default: break;
    }
  }
  if (action === 'fulfill') {
    if (useBodyStdin && bodyInline !== undefined) {
      throw withExit(2, "route fulfill: --body and --body-stdin are mutually exclusive");
    }
    if (useBodyStdin) {
      msg.body = await readAllStdin();
    } else if (bodyInline !== undefined) {
      msg.body = bodyInline;
    }
  }
  const reply = await ipcCall(msg);
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

async function runStatefulViaDaemon(verb, verbArgs) {
  if (!isDaemonAlive()) {
    process.stderr.write(
      `chrome-devtools-bridge: ${verb} requires running daemon ` +
        `(run: node chrome-devtools-bridge.mjs daemon-start)\n`
    );
    process.exit(41);
  }

  // Drag has 2-ref argv shape: `drag <src-ref> <dst-ref>`; all other stateful
  // verbs use the single-ref shape `<verb> <ref> [...rest]`.
  if (verb === 'drag') {
    const srcRef = verbArgs[0];
    const dstRef = verbArgs[1];
    if (!srcRef || !dstRef) {
      throw withExit(2, "drag requires both <src-ref> and <dst-ref> (eN values)");
    }
    const reply = await ipcCall({ verb: 'drag', src_ref: srcRef, dst_ref: dstRef });
    emitReply(reply);
    process.exit(reply.status === 'error' ? 30 : 0);
  }

  const ref = verbArgs[0];
  if (!ref) throw withExit(2, `verb '${verb}' requires a ref (eN)`);

  if (verb === 'upload') {
    // Phase-6 part 6: argv shape is `upload <ref> <path>` (path comes second).
    // Security validation already done bash-side (existence, regular-file,
    // sensitive-pattern reject); bridge just forwards.
    const path = verbArgs[1];
    if (!path) throw withExit(2, "upload requires <path>");
    const reply = await ipcCall({ verb: 'upload', ref, path });
    emitReply(reply);
    process.exit(reply.status === 'error' ? 30 : 0);
  }

  if (verb === 'click') {
    const reply = await ipcCall({ verb: 'click', ref });
    emitReply(reply);
    process.exit(reply.status === 'error' ? 30 : 0);
  }

  if (verb === 'hover') {
    // Phase-6 part 3: pointer hover. Refs only for now; --selector path is
    // a follow-up sub-part if user demand surfaces.
    const reply = await ipcCall({ verb: 'hover', ref });
    emitReply(reply);
    process.exit(reply.status === 'error' ? 30 : 0);
  }

  if (verb === 'select') {
    // Phase-6 part 2: select an <option> by value | label | index. Exactly
    // one of these must be supplied. Argv shape from the adapter:
    //   select <ref> --value VAL
    //   select <ref> --label LABEL
    //   select <ref> --index N
    const msg = { verb: 'select', ref };
    for (let i = 1; i < verbArgs.length; i++) {
      switch (verbArgs[i]) {
        case '--value': msg.value = verbArgs[++i]; break;
        case '--label': msg.label = verbArgs[++i]; break;
        case '--index': msg.index = verbArgs[++i]; break;
        default: break;
      }
    }
    if (msg.value === undefined && msg.label === undefined && msg.index === undefined) {
      throw withExit(2, "select requires one of --value, --label, or --index");
    }
    const reply = await ipcCall(msg);
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
    case 'press': {
      const key = verbArgs[0] ?? '';
      if (!key) throw withExit(2, "verb 'press' requires a --key value");
      msg = { verb: 'press', key };
      break;
    }
    case 'wait': {
      const selector = verbArgs[0] ?? '';
      if (!selector) throw withExit(2, "verb 'wait' requires a --selector value");
      msg = { verb: 'wait', selector };
      for (let i = 1; i < verbArgs.length; i++) {
        if (verbArgs[i] === '--state')   msg.state   = verbArgs[++i];
        if (verbArgs[i] === '--timeout') msg.timeout = parseInt(verbArgs[++i], 10);
      }
      break;
    }
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
// Multi-call verbs: inspect / extract (phase-05 part 1e-ii)
// ----------------------------------------------------------------------------

async function runInspectOrExtract(verb, verbArgs) {
  const msg = translateInspectExtract(verb, verbArgs);
  let reply;
  if (isDaemonAlive()) {
    reply = await ipcCall(msg);
  } else {
    reply = await withMcpClient(async (mcpCall) => {
      if (verb === 'inspect') return await dispatchInspect(mcpCall, msg);
      return await dispatchExtract(mcpCall, msg);
    });
  }
  emitReply(reply);
  process.exit(reply.status === 'error' ? 30 : 0);
}

// translateInspectExtract VERB ARGS → daemon message shape.
function translateInspectExtract(verb, args) {
  const msg = { verb };
  for (let i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--capture-console': msg.capture_console = true; break;
      case '--capture-network': msg.capture_network = true; break;
      case '--screenshot':       msg.screenshot       = true; break;
      case '--selector':         msg.selector         = args[++i]; break;
      case '--eval':             msg.eval             = args[++i]; break;
      default: break;
    }
  }
  return msg;
}

// dispatchInspect — sequential MCP calls aggregated into one summary.
// Order: console → network → screenshot → selector. Each only runs if its
// flag is set; absent flags produce no MCP call (and no result field).
async function dispatchInspect(mcpCall, msg) {
  const summary = {
    verb: 'inspect',
    tool: 'chrome-devtools-mcp',
    why: 'mcp/inspect',
    status: 'ok',
  };
  if (msg.capture_console) {
    const r = await mcpCall('list_console_messages', {});
    summary.console_messages = r?.messages ?? [];
  }
  if (msg.capture_network) {
    const r = await mcpCall('list_network_requests', {});
    summary.network_requests = r?.requests ?? [];
  }
  if (msg.screenshot) {
    const r = await mcpCall('take_screenshot', {});
    summary.screenshot_path = r?.path ?? null;
  }
  if (msg.selector) {
    const safeSel = JSON.stringify(msg.selector);
    const script =
      `Array.from(document.querySelectorAll(${safeSel})).map(el => el.textContent ? el.textContent.trim() : '')`;
    const r = await mcpCall('evaluate_script', { script });
    summary.matches = extractText(r);
  }
  return summary;
}

// dispatchExtract — single evaluate_script tools/call. --selector wraps in
// querySelectorAll → join textContent; --eval passes the raw script through.
async function dispatchExtract(mcpCall, msg) {
  let script;
  if (msg.selector) {
    const safeSel = JSON.stringify(msg.selector);
    script =
      `Array.from(document.querySelectorAll(${safeSel})).map(el => el.textContent ? el.textContent.trim() : '').join('\\n')`;
  } else if (msg.eval) {
    script = msg.eval;
  } else {
    return {
      event: 'error',
      verb: 'extract',
      status: 'error',
      message: 'extract requires --selector or --eval',
    };
  }
  const r = await mcpCall('evaluate_script', { script });
  return {
    verb: 'extract',
    tool: 'chrome-devtools-mcp',
    why: 'mcp/evaluate_script',
    status: 'ok',
    selector: msg.selector ?? null,
    eval: msg.eval ?? null,
    value: extractText(r),
  };
}

// withMcpClient — spawn the upstream MCP server, run the initialize handshake
// once, hand the caller a ready `mcpCall(name, args, timeoutMs)` closure, and
// shut the child down on return. Used for one-shot multi-call verbs (inspect/
// extract when no daemon is running).
async function withMcpClient(fn) {
  const bin = process.env.CHROME_DEVTOOLS_MCP_BIN || 'chrome-devtools-mcp';
  let child;
  try {
    child = spawn(bin, mcpSpawnArgs(), { stdio: ['pipe', 'pipe', 'inherit'] });
  } catch (err) {
    throw withExit(41, `failed to spawn MCP server '${bin}': ${err.message}`);
  }

  let childExited = false;
  let childExitCode = null;
  child.on('exit', (code) => { childExited = true; childExitCode = code; });
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
        clientInfo: { name: 'browser-skill', version: '0.13' },
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

    const mcpCall = makeMcpCall(child, reader, 100);
    return await fn(mcpCall);
  } finally {
    try { child.stdin.end(); } catch (_) { /* ignore */ }
    if (!childExited) {
      await waitForExit(child, SHUTDOWN_TIMEOUT_MS).catch(() => {
        try { child.kill('SIGTERM'); } catch (_) { /* ignore */ }
      });
    }
    if (childExitCode !== null && childExitCode !== 0) {
      process.stderr.write(
        `chrome-devtools-bridge: MCP server exited with code ${childExitCode}\n`
      );
    }
  }
}

// mcpSpawnArgs — CLI args forwarded to the spawned upstream MCP server child.
// Phase-5 part 1f: when CHROME_USER_DATA_DIR is set, append `--user-data-dir
// DIR` so the upstream Chrome reuses the profile directory (cookies,
// localStorage, extensions persist). User provides the directory; capturing
// or automating user-data-dir creation is out of scope.
function mcpSpawnArgs() {
  const args = [];
  if (process.env.CHROME_USER_DATA_DIR) {
    args.push('--user-data-dir', process.env.CHROME_USER_DATA_DIR);
  }
  return args;
}

// makeMcpCall — id-tracking factory for repeated tools/call invocations on a
// single MCP child + reader pair. Used by both daemonChildMain (long-lived)
// and withMcpClient (one-shot). Starts at startId+1 (so init's id=1 doesn't
// collide).
function makeMcpCall(child, reader, startId = 100) {
  let nextId = startId;
  return async function mcpCall(name, args, timeoutMs) {
    const id = ++nextId;
    await sendJsonRpc(child.stdin, {
      jsonrpc: '2.0',
      id,
      method: 'tools/call',
      params: { name, arguments: args },
    });
    const resp = await reader.waitFor(id, timeoutMs ?? CALL_TIMEOUT_MS);
    if (resp.error) {
      throw new Error(`MCP tools/call '${name}' failed: ${resp.error.message}`);
    }
    return resp.result;
  };
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
    mcpChild = spawn(bin, mcpSpawnArgs(), { stdio: ['pipe', 'pipe', 'inherit'] });
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
  let refMap = null;
  const routeRules = [];  // Phase-6 part 7: array of {pattern, action} entries.
  let tabs = [];          // Phase-6 part 8-i: array of {tab_id, url, title}.
                          //   Replaced (not appended) on each list_pages call.
  let currentTab = null;  // Phase-6 part 8-ii: tab_id (number) of the active
                          //   tab, or null if never set. Source of truth is
                          //   tabs[] — currentTab is just the pointer.
                          //   8-iii will null this out if the closed tab matches.
  const mcpCall = makeMcpCall(mcpChild, reader, 100);

  // refreshTabs — call upstream list_pages and normalize to tabs[]. Shared by
  // 'tab-list' and 'tab-switch' (the latter auto-refreshes when tabs[] empty).
  // Returns the tabs[] array (also stored in the closure-scoped `tabs`).
  async function refreshTabs() {
    const result = await mcpCall('list_pages', {});
    const raw = result?.pages ?? result?.tabs ?? [];
    tabs = (Array.isArray(raw) ? raw : []).map((p, i) => ({
      tab_id: i + 1,
      url:    typeof p?.url   === 'string' ? p.url   : '',
      title:  typeof p?.title === 'string' ? p.title : '',
    }));
    return tabs;
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
      case 'inspect': {
        const summary = await dispatchInspect(mcpCall, msg);
        return { ...summary, attached_to_daemon: true };
      }
      case 'extract': {
        const summary = await dispatchExtract(mcpCall, msg);
        return { ...summary, attached_to_daemon: true };
      }
      case 'press': {
        // Phase-6 part 1: keyboard press. MCP `press_key` accepts a `key`
        // arg (e.g. "Enter", "Tab", "Escape", "ArrowDown", "Cmd+S").
        // Stateless w.r.t. refMap — acts on the focused element or page.
        const result = await mcpCall('press_key', { key: msg.key });
        return {
          verb: 'press',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/press_key',
          status: result?.isError ? 'error' : 'ok',
          key: msg.key,
          message: extractText(result),
          attached_to_daemon: true,
        };
      }
      case 'wait': {
        // Phase-6 part 4: explicit wait for an element to reach a state.
        // MCP `wait_for` accepts {selector, state?, timeout?}. State defaults
        // to "visible"; timeout defaults to MCP server's default.
        const callArgs = { selector: msg.selector };
        if (msg.state)   callArgs.state   = msg.state;
        if (msg.timeout) callArgs.timeout = msg.timeout;
        const result = await mcpCall('wait_for', callArgs);
        return {
          verb: 'wait',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/wait_for',
          status: result?.isError ? 'error' : 'ok',
          selector: msg.selector,
          state: msg.state ?? 'visible',
          timeout: msg.timeout ?? null,
          message: extractText(result),
          attached_to_daemon: true,
        };
      }
      case 'tab-list': {
        // Phase-6 part 8-i: read-only enumeration. Calls upstream MCP
        // `list_pages` (best-effort name; real upstream may use a different
        // tool). Result normalized to [{tab_id, url, title}] where `tab_id`
        // is bridge-assigned (1-based, stable per call). Replaces — not
        // appends — the cache. Phase-6 part 8-ii adds `is_current: true`
        // on the entry whose tab_id matches the daemon's currentTab pointer.
        try {
          await refreshTabs();
        } catch (err) {
          return {
            event: 'error',
            verb: 'tab-list',
            status: 'error',
            message: `mcp/list_pages failed: ${err && err.message ? err.message : err}`,
          };
        }
        const annotated = tabs.map((t) => (
          currentTab !== null && t.tab_id === currentTab ? { ...t, is_current: true } : t
        ));
        return {
          verb: 'tab-list',
          tool: 'chrome-devtools-mcp',
          why:  'mcp/list_pages',
          status: 'ok',
          tabs: annotated,
          tab_count: annotated.length,
          current_tab_id: currentTab,
          attached_to_daemon: true,
        };
      }
      case 'tab-close': {
        // Phase-6 part 8-iii: close a tab. Mutex selector. Auto-refresh
        // tabs[] when empty (mirrors tab-switch). Splice matching entry,
        // call upstream MCP `close_page` (best-effort name), and null
        // `currentTab` if it pointed at the closed tab. tab_id values
        // remain stable on remaining entries (no renumbering — agents
        // holding a tab_id reference shouldn't see it silently rebound).
        if (tabs.length === 0) {
          try {
            await refreshTabs();
          } catch (err) {
            return {
              event: 'error',
              verb: 'tab-close',
              status: 'error',
              message: `auto-refresh failed: ${err && err.message ? err.message : err}`,
            };
          }
        }
        if (tabs.length === 0) {
          return {
            event: 'error',
            verb: 'tab-close',
            status: 'error',
            message: 'no tabs available (upstream returned empty page list)',
          };
        }
        let idx = -1;
        if (msg.tab_id !== undefined) {
          idx = tabs.findIndex((t) => t.tab_id === msg.tab_id);
          if (idx < 0) {
            return {
              event: 'error',
              verb: 'tab-close',
              tab_id: msg.tab_id,
              tab_count: tabs.length,
              status: 'error',
              message: `tab_id ${msg.tab_id} not found`,
            };
          }
        } else if (typeof msg.by_url_pattern === 'string' && msg.by_url_pattern) {
          idx = tabs.findIndex((t) => t.url.includes(msg.by_url_pattern));
          if (idx < 0) {
            return {
              event: 'error',
              verb: 'tab-close',
              by_url_pattern: msg.by_url_pattern,
              status: 'error',
              message: `no tab url contains pattern: ${msg.by_url_pattern}`,
            };
          }
        } else {
          return {
            event: 'error',
            verb: 'tab-close',
            status: 'error',
            message: 'tab-close requires --tab-id or --by-url-pattern',
          };
        }
        const closed = tabs[idx];
        let mcpAck = null;
        try {
          const result = await mcpCall('close_page', { tab_id: closed.tab_id, url: closed.url });
          mcpAck = extractText(result);
        } catch (err) {
          mcpAck = `mcp-close_page-failed: ${err && err.message ? err.message : err}`;
        }
        tabs.splice(idx, 1);
        if (currentTab === closed.tab_id) currentTab = null;
        return {
          verb: 'tab-close',
          tool: 'chrome-devtools-mcp',
          why:  'mcp/close_page',
          status: 'ok',
          closed_tab: { ...closed },
          current_tab_id: currentTab,
          tab_count: tabs.length,
          mcp_ack: mcpAck,
          attached_to_daemon: true,
        };
      }
      case 'tab-switch': {
        // Phase-6 part 8-ii: switch active tab via mutex selectors.
        // --by-index (1-based) | --by-url-pattern (substring-contains).
        // Auto-refreshes tabs[] when empty so agents don't have to remember
        // to call tab-list first. Updates `currentTab` pointer and asks the
        // upstream MCP to focus the corresponding page (best-effort
        // `select_page` — real upstream may differ).
        if (tabs.length === 0) {
          try {
            await refreshTabs();
          } catch (err) {
            return {
              event: 'error',
              verb: 'tab-switch',
              status: 'error',
              message: `auto-refresh failed: ${err && err.message ? err.message : err}`,
            };
          }
        }
        if (tabs.length === 0) {
          return {
            event: 'error',
            verb: 'tab-switch',
            status: 'error',
            message: 'no tabs available (upstream returned empty page list)',
          };
        }
        let target = null;
        if (msg.by_index !== undefined) {
          const idx = msg.by_index;
          if (!Number.isInteger(idx) || idx < 1 || idx > tabs.length) {
            return {
              event: 'error',
              verb: 'tab-switch',
              by_index: idx,
              tab_count: tabs.length,
              status: 'error',
              message: `--by-index ${idx} out of range (1..${tabs.length})`,
            };
          }
          target = tabs[idx - 1];
        } else if (typeof msg.by_url_pattern === 'string' && msg.by_url_pattern) {
          target = tabs.find((t) => t.url.includes(msg.by_url_pattern)) || null;
          if (!target) {
            return {
              event: 'error',
              verb: 'tab-switch',
              by_url_pattern: msg.by_url_pattern,
              status: 'error',
              message: `no tab url contains pattern: ${msg.by_url_pattern}`,
            };
          }
        } else {
          return {
            event: 'error',
            verb: 'tab-switch',
            status: 'error',
            message: 'tab-switch requires --by-index or --by-url-pattern',
          };
        }
        let mcpAck = null;
        try {
          const result = await mcpCall('select_page', { tab_id: target.tab_id, url: target.url });
          mcpAck = extractText(result);
        } catch (err) {
          mcpAck = `mcp-select_page-failed: ${err && err.message ? err.message : err}`;
        }
        currentTab = target.tab_id;
        return {
          verb: 'tab-switch',
          tool: 'chrome-devtools-mcp',
          why:  'mcp/select_page',
          status: 'ok',
          current_tab: { ...target },
          mcp_ack: mcpAck,
          attached_to_daemon: true,
        };
      }
      case 'route': {
        // Phase-6 part 7: register a network-route rule.
        // 7-i: block | allow.
        // 7-ii: fulfill — synthetic responses, requires status + body.
        const allowed = ['block', 'allow', 'fulfill'];
        if (!allowed.includes(msg.action)) {
          return {
            event: 'error',
            verb: 'route',
            status: 'error',
            message: `route action must be one of ${allowed.join(', ')} (got: ${msg.action})`,
          };
        }
        let rule;
        if (msg.action === 'fulfill') {
          if (!Number.isInteger(msg.status) || msg.status < 100 || msg.status > 599) {
            return {
              event: 'error',
              verb: 'route',
              status: 'error',
              message: `route fulfill --status must be integer in 100-599 (got: ${msg.status})`,
            };
          }
          if (typeof msg.body !== 'string') {
            return {
              event: 'error',
              verb: 'route',
              status: 'error',
              message: 'route fulfill requires --body STR or --body-stdin',
            };
          }
          rule = { pattern: msg.pattern, action: 'fulfill', status: msg.status, body: msg.body };
        } else {
          rule = { pattern: msg.pattern, action: msg.action };
        }
        routeRules.push(rule);
        // Best-effort MCP `route_url` invocation. Real upstream may use a
        // different tool name (e.g. network.setRequestInterception); upstream
        // binding hardening tracked downstream.
        let mcpAck = null;
        try {
          const callArgs = msg.action === 'fulfill'
            ? { pattern: msg.pattern, action: msg.action, status: msg.status, body: msg.body }
            : { pattern: msg.pattern, action: msg.action };
          const result = await mcpCall('route_url', callArgs);
          mcpAck = extractText(result);
        } catch (err) {
          mcpAck = `mcp-route_url-failed: ${err && err.message ? err.message : err}`;
        }
        const reply = {
          verb: 'route',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/route_url',
          status: 'ok',
          pattern: msg.pattern,
          action: msg.action,
          rule_count: routeRules.length,
          mcp_ack: mcpAck,
          attached_to_daemon: true,
        };
        if (msg.action === 'fulfill') {
          reply.fulfill_status = msg.status;
          reply.body_bytes = Buffer.byteLength(msg.body, 'utf8');
          // Body itself NOT echoed in reply — agent sent it; avoid re-emitting
          // potentially large or sensitive content. body_bytes is the contract.
        }
        return reply;
      }
      case 'upload': {
        // Phase-6 part 6: file upload to <input type=file>. eN→uid translation
        // + path forwarded to MCP `upload_file` tool. Bash-side validates the
        // path before reaching the daemon (existence + regular-file + reject
        // sensitive patterns); bridge just forwards.
        if (!refMap) {
          return {
            event: 'error',
            verb: 'upload',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            verb: 'upload',
            ref: msg.ref,
            status: 'error',
            message: `ref '${msg.ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        const result = await mcpCall('upload_file', { uid: entry.uid, path: msg.path });
        return {
          verb: 'upload',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/upload_file',
          status: result?.isError ? 'error' : 'ok',
          ref: entry.id,
          uid: entry.uid,
          path: msg.path,
          message: extractText(result),
        };
      }
      case 'drag': {
        // Phase-6 part 5: pointer drag from src → dst. Both refs translated
        // via refMap to uids. MCP `drag` tool accepts {src_uid, dst_uid}.
        if (!refMap) {
          return {
            event: 'error',
            verb: 'drag',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const srcEntry = refMap.find((r) => r.id === msg.src_ref);
        const dstEntry = refMap.find((r) => r.id === msg.dst_ref);
        if (!srcEntry) {
          return {
            event: 'error',
            verb: 'drag',
            src_ref: msg.src_ref,
            status: 'error',
            message: `src ref '${msg.src_ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        if (!dstEntry) {
          return {
            event: 'error',
            verb: 'drag',
            dst_ref: msg.dst_ref,
            status: 'error',
            message: `dst ref '${msg.dst_ref}' not found in last snapshot`,
          };
        }
        const result = await mcpCall('drag', { src_uid: srcEntry.uid, dst_uid: dstEntry.uid });
        return {
          verb: 'drag',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/drag',
          status: result?.isError ? 'error' : 'ok',
          src_ref: srcEntry.id,
          src_uid: srcEntry.uid,
          dst_ref: dstEntry.id,
          dst_uid: dstEntry.uid,
          message: extractText(result),
        };
      }
      case 'hover': {
        // Phase-6 part 3: pointer hover. eN→uid translation; calls MCP
        // `hover` tool with the resolved uid. Stateful (refMap precondition
        // mirrors click/fill/select).
        if (!refMap) {
          return {
            event: 'error',
            verb: 'hover',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            verb: 'hover',
            ref: msg.ref,
            status: 'error',
            message: `ref '${msg.ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        const result = await mcpCall('hover', { uid: entry.uid });
        return {
          verb: 'hover',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/hover',
          status: result?.isError ? 'error' : 'ok',
          ref: entry.id,
          uid: entry.uid,
          message: extractText(result),
        };
      }
      case 'select': {
        // Phase-6 part 2: pick an <option> from a <select> element. Stateful
        // — needs eN→uid translation from the most recent snapshot. Exactly
        // one of value/label/index drives the choice (caller-validated).
        if (!refMap) {
          return {
            event: 'error',
            verb: 'select',
            status: 'error',
            message: 'no refs (run snapshot first)',
          };
        }
        const entry = refMap.find((r) => r.id === msg.ref);
        if (!entry) {
          return {
            event: 'error',
            verb: 'select',
            ref: msg.ref,
            status: 'error',
            message: `ref '${msg.ref}' not found in last snapshot (${refMap.length} refs available)`,
          };
        }
        const callArgs = { uid: entry.uid };
        if (msg.value !== undefined) callArgs.value = msg.value;
        if (msg.label !== undefined) callArgs.label = msg.label;
        if (msg.index !== undefined) callArgs.index = parseInt(msg.index, 10);
        const result = await mcpCall('select_option', callArgs);
        return {
          verb: 'select',
          tool: 'chrome-devtools-mcp',
          why: 'mcp/select_option',
          status: result?.isError ? 'error' : 'ok',
          ref: entry.id,
          uid: entry.uid,
          value: msg.value ?? null,
          label: msg.label ?? null,
          index: msg.index !== undefined ? parseInt(msg.index, 10) : null,
          message: extractText(result),
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
    case 'press': {
      const key = args[0] ?? '';
      if (!key) throw withExit(2, "verb 'press' requires a --key value");
      return { tool: 'press_key', args: { key }, verb };
    }
    case 'wait': {
      // Argv shape from adapter: wait <selector> [--state STATE] [--timeout MS]
      const selector = args[0] ?? '';
      if (!selector) throw withExit(2, "verb 'wait' requires a --selector value");
      const callArgs = { selector };
      for (let i = 1; i < args.length; i++) {
        if (args[i] === '--state')   callArgs.state   = args[++i];
        if (args[i] === '--timeout') callArgs.timeout = parseInt(args[++i], 10);
      }
      return { tool: 'wait_for', args: callArgs, verb };
    }
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
    case 'press': {
      const text = extractText(result);
      return { ...base, key: tx.args.key, message: text };
    }
    case 'wait': {
      const text = extractText(result);
      return {
        ...base,
        selector: tx.args.selector,
        state: tx.args.state ?? 'visible',
        timeout: tx.args.timeout ?? null,
        message: text,
      };
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
