#!/usr/bin/env node
// scripts/lib/node/mcp-server.mjs
//
// Phase 14 (Proposal 2): expose browser-skill verbs as MCP tools (JSON-RPC
// 2.0 NDJSON over stdio). Protocol version 2024-11-05 — matches the version
// our chrome-devtools-bridge CLIENT already speaks, so we converge on one
// wire format across the codebase.
//
// Why: lets agent-browser / midscene / Stagehand / browser-use / Claude Code
// reuse our cache + telemetry + secrets vault without re-implementing them.
// We become the SHARED MIDDLEWARE other browser agents delegate to.
//
// Stage 1 surface (this commit): browser_open + browser_snapshot.
// Stage 2 surface (followup): browser_click, browser_fill, browser_extract.
// Each tool spawns the matching scripts/browser-<verb>.sh and returns the
// verb's single-line summary JSON as MCP `content[0].text`.

import readline from 'node:readline';
import { spawn } from 'node:child_process';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const SCRIPTS_DIR = join(HERE, '..', '..');
const MCP_PROTOCOL_VERSION = '2024-11-05';

// Tool registry. Each entry maps an MCP tool to a bash verb script + an arg
// translator. Schema is JSON Schema draft-07 so clients can validate before
// calling.
const TOOLS = [
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
];

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

function handleToolsCall(id, params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  const tool = TOOLS_BY_NAME[name];
  if (!tool) {
    replyError(id, -32602, `Unknown tool: ${name}`);
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
    env: process.env,
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
    try {
      summary = JSON.parse(lastLine);
    } catch {
      summary = {
        status: code === 0 ? 'ok' : 'error',
        stdout: stdout.slice(0, 2048),
        stderr: stderr.slice(0, 2048),
        exitCode: code,
      };
    }
    reply(id, {
      content: [{ type: 'text', text: JSON.stringify(summary) }],
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
