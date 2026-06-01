#!/usr/bin/env node
// scripts/lib/node/mcp-server.mjs
//
// Phase 14 (Proposal 2): expose browser-skill verbs as MCP tools (JSON-RPC
// 2.0 NDJSON over stdio). Protocol version 2024-11-05 — matches the version
// our chrome-devtools-bridge CLIENT already speaks, so we converge on one
// wire format across the codebase.
//
// Why: lets agent-browser / midscene / Stagehand / browser-use / Claude Code
// / OpenAI Codex reuse our cache + telemetry + secrets vault without
// re-implementing them.
// We become the SHARED MIDDLEWARE other browser agents delegate to.
//
// Surface: browser_open, browser_snapshot, browser_click, browser_fill,
// browser_extract, browser_list-sites.
// Each tool spawns the matching scripts/browser-<verb>.sh and returns the
// verb's single-line summary JSON as MCP `content[0].text`.
//
// Env-var passthrough is WHITELISTED (Path 2). The MCP client's full env is
// NEVER inherited blindly — only well-known skill / VLM / OS / test prefixes
// flow through. Two reasons:
//   1. AP-7 alignment — MCP clients may carry their OWN secrets (API keys for
//      OpenAI, Anthropic, etc.); passing those into our bash verbs could land
//      them in stats.jsonl's argv_bytes count or observed-snapshot capture.
//   2. Determinism — verb behaviour shouldn't depend on whatever stray env
//      the client process happened to have set.
// See ENV_WHITELIST_PREFIXES + ENV_WHITELIST_EXACT below.

import readline from 'node:readline';
import { spawn, execSync } from 'node:child_process';
import { readFileSync, readdirSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS_DIR = join(HERE, '..', '..');
const ADAPTERS_DIR = join(HERE, '..', 'tool');
// BROWSER_SKILL_MCP_TOOLS_JSON env override lets tests point at a tmp JSON
// to verify auto-discovery picks up additions/removals.
const MCP_TOOLS_JSON = process.env.BROWSER_SKILL_MCP_TOOLS_JSON
  || join(HERE, 'mcp-tools.json');
const MCP_PROTOCOL_VERSION = '2024-11-05';
const SERVER_INSTRUCTIONS =
  'Use browser-skill for real browser automation. Prefer browser_open, browser_snapshot, browser_click, browser_fill, browser_extract, and browser_list-sites before shell fallbacks. Use eN refs from snapshots when possible, falling back to selectors only when needed. Never pass secrets through MCP arguments; use local credential/session workflows.';

// --- Auto-discovery (Phase 14+ A1) ---
//
// Tool definitions are AUTO-DERIVED at server startup by combining:
//   1. mcp-tools.json — allowlist + per-verb metadata (description, required,
//      oneOf, schemaExtras, excludeFlags). Adding a verb to MCP = 1 JSON entry.
//   2. scripts/lib/tool/<adapter>.sh::tool_capabilities() — flag discovery.
//      Run once per adapter at startup; flags union → schema properties.
//
// Result: the TOOLS array below is the OLD hand-maintained version (kept as
// fallback if discovery fails for any reason). buildToolsAutoDiscovered()
// runs at module load and OVERWRITES TOOLS with the discovered set when it
// succeeds. Adding a verb to an adapter + an entry in mcp-tools.json now
// exposes it via MCP without editing this file.

function readAdapterCapabilities(adapterFile) {
  // Source the adapter in a subshell + invoke tool_capabilities; parse JSON.
  // The adapter ABI guarantees tool_capabilities() returns valid JSON; if it
  // doesn't, skip the adapter (logged to stderr) so one bad adapter doesn't
  // sink discovery.
  try {
    const out = execSync(
      `bash -c 'source "${adapterFile}" >/dev/null 2>&1 && tool_capabilities'`,
      { stdio: ['ignore', 'pipe', 'pipe'] },
    ).toString();
    return JSON.parse(out);
  } catch (e) {
    process.stderr.write(`mcp-server: capability read failed for ${adapterFile}: ${e.message}\n`);
    return null;
  }
}

function discoverFlagsByVerb() {
  // Returns: { <verb>: { flags: Set<string>, adapters: string[] } }
  const byVerb = {};
  let adapterFiles;
  try {
    adapterFiles = readdirSync(ADAPTERS_DIR).filter((f) => f.endsWith('.sh'));
  } catch {
    return byVerb;
  }
  for (const file of adapterFiles) {
    const adapterName = file.replace(/\.sh$/, '');
    const caps = readAdapterCapabilities(join(ADAPTERS_DIR, file));
    if (!caps || !caps.verbs) continue;
    for (const [verb, def] of Object.entries(caps.verbs)) {
      if (!byVerb[verb]) byVerb[verb] = { flags: new Set(), adapters: [] };
      for (const flag of def.flags || []) {
        byVerb[verb].flags.add(flag.replace(/^--/, ''));
      }
      byVerb[verb].adapters.push(adapterName);
    }
  }
  return byVerb;
}

function loadToolsJson() {
  try {
    const raw = readFileSync(MCP_TOOLS_JSON, 'utf8');
    const parsed = JSON.parse(raw);
    // Strip _doc and _schema sentinel keys; what remains is the verb allowlist.
    const out = {};
    for (const [k, v] of Object.entries(parsed)) {
      if (k.startsWith('_')) continue;
      out[k] = v;
    }
    return out;
  } catch (e) {
    process.stderr.write(`mcp-server: mcp-tools.json read failed: ${e.message}\n`);
    return null;
  }
}

function buildToolsAutoDiscovered() {
  const verbMeta = loadToolsJson();
  if (!verbMeta) return null;
  const discovered = discoverFlagsByVerb();
  const tools = [];

  for (const [verb, meta] of Object.entries(verbMeta)) {
    const verbScript = `browser-${verb}.sh`;
    const scriptPath = join(SCRIPTS_DIR, verbScript);
    if (!existsSync(scriptPath)) {
      process.stderr.write(`mcp-server: skipping ${verb} (no ${verbScript})\n`);
      continue;
    }
    const discInfo = discovered[verb] || { flags: new Set(), adapters: [] };
    const excludeFlags = new Set(meta.excludeFlags || []);
    const schemaExtras = meta.schemaExtras || {};

    // Build properties: union of (adapter flags - excluded) + extra schemaExtras
    // keys (e.g. ref/selector for verbs whose wrappers accept them even though
    // some adapters don't declare them) + globals (site, tool).
    const properties = {};
    for (const flag of discInfo.flags) {
      if (excludeFlags.has(flag)) continue;
      properties[flag] = schemaExtras[flag] || { type: 'string' };
    }
    // Extras not covered by adapter flags (constraint targets, e.g. fill.selector).
    for (const [extraKey, extraSchema] of Object.entries(schemaExtras)) {
      if (extraKey === 'site' || extraKey === 'tool') continue;
      if (excludeFlags.has(extraKey)) continue;
      if (!(extraKey in properties)) properties[extraKey] = extraSchema;
    }
    // Globals: site (always), tool (always — enum derived from adapters that
    // support this verb).
    properties.site = schemaExtras.site || { type: 'string' };
    if (!('tool' in properties)) {
      properties.tool = {
        type: 'string',
        description: 'Adapter override',
        enum: discInfo.adapters.length
          ? discInfo.adapters
          : ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'],
      };
    }

    const inputSchema = {
      type: 'object',
      properties,
      additionalProperties: false,
    };
    if (meta.required) inputSchema.required = meta.required;
    // NOTE: meta.oneOf is NOT emitted into inputSchema — the Anthropic Messages
    // API rejects top-level oneOf/anyOf/allOf and would poison the whole
    // tools[] payload. Constraint is enforced at runtime in handleToolsCall.

    tools.push({
      name: `browser_${verb}`,
      description: meta.description,
      inputSchema,
      verbScript,
      argMap: makeArgMap(meta, verb),
      oneOf: meta.oneOf || null,
    });
  }

  return tools.length > 0 ? tools : null;
}

// Phase 12 amendment (2026-05-22): verbs whose summary is dominated by an
// inline uniform-shape array. The MCP server auto-appends --format=toon for
// these UNLESS the client explicitly set `format:"json"` in tool args.
// Mirrors docs/superpowers/specs/2026-05-22-toon-output-amendment.md §2.
const TOON_ELIGIBLE_VERBS = new Set([
  'list-sites',
  'list-sessions',
  'history',
  'tab-list',
  'stats',
  // 'extract' is eligible only in --scrape mode (excluded from MCP); the
  // auto-flip stays off for the single-page extract that IS exposed.
  'doctor',
]);

function makeArgMap(meta, verb) {
  const required = meta.required || [];
  const isToonEligible = TOON_ELIGIBLE_VERBS.has(verb);
  // Generic argMap: emit required flags first (so `text` always lands as
  // `--text VAL`, deterministic ordering), then optional flags, then site/tool
  // last for human-readability of stub-log argv.
  return (args) => {
    const out = [];
    // Required first.
    for (const key of required) {
      if (args[key] === undefined || args[key] === null) continue;
      _emitArg(out, key, args[key]);
    }
    // Optional next (anything not in required + not site/tool/format).
    const skip = new Set([...required, 'site', 'tool', 'format']);
    for (const [k, v] of Object.entries(args)) {
      if (skip.has(k)) continue;
      if (v === undefined || v === null) continue;
      _emitArg(out, k, v);
    }
    // Globals last.
    if (args.site) out.push('--site', args.site);
    if (args.tool) out.push('--tool', args.tool);
    // Phase 12 auto-flip rule (amendment §4): if verb is TOON-eligible and
    // client did NOT specify format, default to toon. Explicit json/toon
    // honored as-is.
    let format = args.format;
    if (!format && isToonEligible) format = 'toon';
    if (format) out.push('--format', format);
    return out;
  };
}

function _emitArg(out, key, value) {
  if (typeof value === 'boolean') {
    if (value) out.push(`--${key}`);
    return;
  }
  out.push(`--${key}`, String(value));
}

// Legacy static TOOLS — kept as fallback if auto-discovery fails (e.g.
// mcp-tools.json missing in a stripped-down install). On boot, we try
// auto-discovery first; on success, this constant is OVERWRITTEN below.
let TOOLS = [
  {
    name: 'browser_open',
    description:
      'Open a URL via the routed browser adapter. Returns a summary JSON line ' +
      'with verb, tool, status, url, duration_ms. Auto-derives a post-condition ' +
      'check (url-include) so adapter-lies/redirect-to-login surface as ' +
      'oblivious_success in stats.jsonl.',
    inputSchema: {
      type: 'object',
      properties: {
        url:  { type: 'string', description: 'URL to navigate to' },
        site: { type: 'string', description: 'Registered site name (see browser-add-site)' },
        tool: {
          type: 'string',
          description: 'Adapter override',
          enum: ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'],
        },
      },
      required: ['url'],
      additionalProperties: false,
    },
    verbScript: 'browser-open.sh',
    argMap: (args) => {
      const out = ['--url', args.url];
      if (args.site) out.push('--site', args.site);
      if (args.tool) out.push('--tool', args.tool);
      return out;
    },
  },
  {
    name: 'browser_snapshot',
    description:
      'Capture an eN-indexed accessibility snapshot. Heavy YAML (> 2 KB) is ' +
      'persisted under captures/snapshots/ and returned via snapshot_path + ' +
      'n_refs in the summary; small payloads stay inline. With capture=true ' +
      'the full body is also archived under captures/NNN/.',
    inputSchema: {
      type: 'object',
      properties: {
        site:    { type: 'string' },
        tool:    { type: 'string', enum: ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'] },
        capture: { type: 'boolean', description: 'Persist under captures/NNN/ (Phase 7)' },
      },
      additionalProperties: false,
    },
    verbScript: 'browser-snapshot.sh',
    argMap: (args) => {
      const out = [];
      if (args.site)    out.push('--site', args.site);
      if (args.tool)    out.push('--tool', args.tool);
      if (args.capture) out.push('--capture');
      return out;
    },
  },
  // Stage 2 — Phase 14 bundle.
  {
    name: 'browser_click',
    description:
      'Click an element by eN ref (preferred — stable across the session ' +
      'until the page mutates) or by CSS selector. Provide exactly one of ' +
      'ref or selector.',
    inputSchema: {
      type: 'object',
      properties: {
        ref:      { type: 'string', description: 'eN ref from a prior browser_snapshot call' },
        selector: { type: 'string', description: 'CSS selector (fallback when ref unavailable)' },
        site:     { type: 'string' },
        tool:     { type: 'string', enum: ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'] },
      },
      additionalProperties: false,
    },
    verbScript: 'browser-click.sh',
    oneOf: [{ required: ['ref'] }, { required: ['selector'] }],
    argMap: (args) => {
      const out = [];
      if (args.ref)      out.push('--ref', args.ref);
      if (args.selector) out.push('--selector', args.selector);
      if (args.site)     out.push('--site', args.site);
      if (args.tool)     out.push('--tool', args.tool);
      return out;
    },
  },
  {
    name: 'browser_fill',
    description:
      'Fill an input by eN ref or CSS selector with the given text. NOTE: ' +
      'this tool deliberately does NOT expose a "secret" field — MCP has no ' +
      'stdin channel and putting secrets in tool arguments would land them ' +
      'in the request transcript. For secret values use scripts/browser-fill.sh ' +
      'directly with --secret-stdin (AP-7).',
    inputSchema: {
      type: 'object',
      properties: {
        ref:      { type: 'string' },
        selector: { type: 'string' },
        text:     { type: 'string', description: 'Plain-text value to type (NEVER pass secrets here)' },
        site:     { type: 'string' },
        tool:     { type: 'string', enum: ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'] },
      },
      required: ['text'],
      additionalProperties: false,
    },
    verbScript: 'browser-fill.sh',
    oneOf: [{ required: ['ref'] }, { required: ['selector'] }],
    argMap: (args) => {
      const out = [];
      if (args.ref)      out.push('--ref', args.ref);
      if (args.selector) out.push('--selector', args.selector);
      out.push('--text', args.text);
      if (args.site)     out.push('--site', args.site);
      if (args.tool)     out.push('--tool', args.tool);
      return out;
    },
  },
  {
    name: 'browser_extract',
    description:
      'Extract data via CSS selector or evaluated JS. selector returns ' +
      'concatenated text content of matched nodes; eval returns the JS ' +
      'expression result. --scrape multi-URL mode is intentionally NOT ' +
      'exposed via MCP (use scripts/browser-extract.sh --scrape directly).',
    inputSchema: {
      type: 'object',
      properties: {
        selector: { type: 'string', description: 'CSS selector to extract text from' },
        eval:     { type: 'string', description: 'JS expression evaluated in page context' },
        site:     { type: 'string' },
        tool:     { type: 'string', enum: ['playwright-cli', 'playwright-lib', 'chrome-devtools-mcp', 'obscura'] },
      },
      additionalProperties: false,
    },
    verbScript: 'browser-extract.sh',
    oneOf: [{ required: ['selector'] }, { required: ['eval'] }],
    argMap: (args) => {
      const out = [];
      if (args.selector) out.push('--selector', args.selector);
      if (args.eval)     out.push('--eval', args.eval);
      if (args.site)     out.push('--site', args.site);
      if (args.tool)     out.push('--tool', args.tool);
      return out;
    },
  },
];

// --- Env whitelist (Phase 14 Path 2) ---
// Only env vars with a whitelisted prefix OR an exact-match name are passed
// to verb children. Everything else is dropped. This protects skill verbs
// from being polluted (or having their stats.jsonl polluted) by whatever
// the MCP client happened to have in its process env.
const ENV_WHITELIST_PREFIXES = [
  'BROWSER_SKILL_',        // skill internals (HOME, TRACE_ID, etc.)
  'BROWSER_STATS_',        // stats post-condition / model injection
  'CLAUDE_',               // CLAUDE_MODEL, CLAUDE_USAGE_*, CLAUDE_SESSION_ID
  'MIDSCENE_MODEL_',       // local-VLM endpoint config (Path 2 motivation)
  'PLAYWRIGHT_',           // PLAYWRIGHT_CLI_BIN + test injection
  'CHROME_DEVTOOLS_',      // CHROME_DEVTOOLS_MCP_BIN
  'CHROME_USER_DATA_DIR',  // session loading for cdt-mcp (Phase 5 part 1f)
  'OBSCURA_',              // obscura adapter knobs
  'STUB_',                 // STUB_LOG_FILE etc — test injection seam
  'FIXTURES_',             // CHROME_DEVTOOLS_MCP_FIXTURES_DIR etc — test seam
  'MCP_',                  // future MCP-specific overrides
];
const ENV_WHITELIST_EXACT = new Set([
  // POSIX / shell essentials. Verb scripts assume these exist.
  'PATH', 'HOME', 'USER', 'LOGNAME', 'TMPDIR', 'TMP', 'TEMP',
  'LANG', 'LC_ALL', 'LC_CTYPE', 'TERM', 'SHELL', 'TZ', 'PWD',
  // Node + npm essentials so spawned bash can still find tooling.
  'NODE_PATH', 'NPM_CONFIG_PREFIX',
]);

function filteredEnv() {
  const out = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (ENV_WHITELIST_EXACT.has(key)) {
      out[key] = value;
      continue;
    }
    for (const prefix of ENV_WHITELIST_PREFIXES) {
      if (key.startsWith(prefix)) {
        out[key] = value;
        break;
      }
    }
  }
  return out;
}

// Auto-discovery replaces the legacy hand-maintained TOOLS array when
// mcp-tools.json is present + at least one verb resolves. Falls back to
// the static array on any failure (defensive: a stripped-down install
// missing mcp-tools.json or with broken adapter capabilities still works).
const _discovered = buildToolsAutoDiscovered();
if (_discovered && _discovered.length > 0) {
  TOOLS = _discovered;
}
const TOOLS_BY_NAME = Object.fromEntries(TOOLS.map((t) => [t.name, t]));

// --- Protocol I/O ---

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

// --- Method handlers ---

function handleInitialize(id /* , params */) {
  reply(id, {
    protocolVersion: MCP_PROTOCOL_VERSION,
    capabilities: { tools: {} },
    instructions: SERVER_INSTRUCTIONS,
    serverInfo: {
      name: 'browser-skill',
      version: '0.1.0',
    },
  });
}

function handleToolsList(id) {
  reply(id, {
    tools: TOOLS.map((t) => ({
      name: t.name,
      description: t.description,
      inputSchema: t.inputSchema,
    })),
  });
}

// Runtime XOR validator. Anthropic API rejects top-level oneOf in JSON Schema,
// so mutual-exclusion constraints (e.g. click: ref XOR selector) are stored
// on the tool struct as `tool.oneOf` and enforced HERE before spawn. Returns
// null on success, or an error message string on violation.
function validateOneOf(args, oneOf) {
  if (!oneOf) return null;
  const present = (k) => args[k] !== undefined && args[k] !== null && args[k] !== '';
  const hits = oneOf.filter((g) => (g.required || []).every(present));
  if (hits.length === 1) return null;
  const labels = oneOf.map((g) => (g.required || []).join('+')).join(' OR ');
  if (hits.length === 0) {
    return `must provide exactly one of: ${labels}`;
  }
  return `must provide exactly one of: ${labels} (got multiple)`;
}

function handleToolsCall(id, params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  const tool = TOOLS_BY_NAME[name];
  if (!tool) {
    replyError(id, -32602, `Unknown tool: ${name}`);
    return;
  }

  const oneOfErr = validateOneOf(args, tool.oneOf);
  if (oneOfErr) {
    replyError(id, -32602, `Invalid arguments for ${name}: ${oneOfErr}`);
    return;
  }

  let scriptArgs;
  try {
    scriptArgs = tool.argMap(args);
  } catch (e) {
    replyError(id, -32602, `Invalid arguments: ${e.message}`);
    return;
  }

  const scriptPath = join(SCRIPTS_DIR, tool.verbScript);
  const child = spawn('bash', [scriptPath, ...scriptArgs], {
    env: filteredEnv(),
    stdio: ['ignore', 'pipe', 'pipe'],
  });

  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (d) => { stdout += d.toString('utf8'); });
  child.stderr.on('data', (d) => { stderr += d.toString('utf8'); });

  child.on('close', (code) => {
    const lines = stdout.replace(/\n+$/, '').split('\n');
    const lastLine = lines[lines.length - 1] ?? '';
    let summary;
    let contentText;
    try {
      summary = JSON.parse(lastLine);
      contentText = JSON.stringify(summary);
    } catch {
      if (code === 0 && stdout.length > 0) {
        // Phase 12 amendment (2026-05-22): verb emitted non-JSON (e.g. TOON
        // for tabular verbs). Pass stdout through verbatim as text content;
        // the LLM is expected to read TOON natively. summary remains a
        // synthetic ok-status envelope for isError/_meta computation only.
        summary = { status: 'ok' };
        contentText = stdout;
      } else {
        summary = {
          status: 'error',
          stdout: stdout.slice(0, 2048),
          stderr: stderr.slice(0, 2048),
          exitCode: code,
        };
        contentText = JSON.stringify(summary);
      }
    }
    reply(id, {
      content: [{ type: 'text', text: contentText }],
      isError: code !== 0 && summary.status !== 'ok',
      _meta: {
        exitCode: code,
        stderr: stderr.length > 0 ? stderr.slice(0, 2048) : undefined,
      },
    });
  });

  child.on('error', (e) => {
    replyError(id, -32603, `Failed to spawn ${tool.verbScript}: ${e.message}`);
  });
}

function handleMessage(msg) {
  switch (msg.method) {
    case 'initialize':                return handleInitialize(msg.id, msg.params);
    case 'notifications/initialized': return;  // notification — no reply
    case 'tools/list':                return handleToolsList(msg.id);
    case 'tools/call':                return handleToolsCall(msg.id, msg.params);
    case 'ping':                      return reply(msg.id, {});
    default:
      if (msg.id !== undefined) {
        replyError(msg.id, -32601, `Method not found: ${msg.method}`);
      }
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', (line) => {
  if (!line.trim()) return;
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    process.stderr.write(`mcp-server: bad JSON line: ${e.message}\n`);
    return;
  }
  try {
    handleMessage(msg);
  } catch (e) {
    if (msg && msg.id !== undefined) {
      replyError(msg.id, -32603, `Internal error: ${e.message}`);
    }
  }
});
