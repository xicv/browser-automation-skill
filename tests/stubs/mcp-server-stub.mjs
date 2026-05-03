#!/usr/bin/env node
// tests/stubs/mcp-server-stub.mjs
//
// Mock of the upstream chrome-devtools-mcp MCP server for bridge real-mode
// tests. Speaks JSON-RPC 2.0 NDJSON over stdio (one JSON object per line) —
// the standard MCP stdio transport.
//
// Handles:
//   - initialize           → capabilities envelope
//   - tools/call name=navigate_page    → "navigated to <url>" content
//   - tools/call name=take_snapshot    → canned 2-element accessibility tree
//   - tools/call name=evaluate_script  → echoes the script back
//   - tools/call name=lighthouse_audit → canned score object
//   - any other method/tool            → JSON-RPC error -32601
//
// Logs each received message (one JSON per line) to ${MCP_STUB_LOG_FILE}
// so bats can assert handshake order + tool args. Logs raw line received
// rather than parsed object so order-of-fields stays stable for grep tests.

import readline from 'node:readline';
import { appendFileSync } from 'node:fs';

const LOG = process.env.MCP_STUB_LOG_FILE;

function log(line) {
  if (LOG) {
    try { appendFileSync(LOG, line + '\n'); } catch (_) { /* ignore */ }
  }
}

function send(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

function reply(id, result) {
  send({ jsonrpc: '2.0', id, result });
}

function replyError(id, code, message) {
  send({ jsonrpc: '2.0', id, error: { code, message } });
}

function handleToolsCall(id, params) {
  const name = params?.name;
  const args = params?.arguments ?? {};
  switch (name) {
    case 'navigate_page': {
      const url = args.url ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `navigated to ${url}` }],
        isError: false,
      });
      break;
    }
    case 'take_snapshot': {
      reply(id, {
        content: [
          {
            type: 'snapshot',
            elements: [
              { uid: 'cdp-uid-1234', role: 'button', name: 'Submit' },
              { uid: 'cdp-uid-5678', role: 'link', name: 'Home' },
            ],
          },
        ],
        isError: false,
      });
      break;
    }
    case 'evaluate_script': {
      const script = args.script ?? args.expression ?? '';
      reply(id, {
        content: [{ type: 'text', text: `eval result for: ${script}` }],
        isError: false,
      });
      break;
    }
    case 'lighthouse_audit': {
      reply(id, {
        content: [{ type: 'text', text: 'lighthouse score: 0.95' }],
        scores: { performance: 0.95, accessibility: 1.0 },
        isError: false,
      });
      break;
    }
    default:
      replyError(id, -32601, `tool not found: ${name}`);
  }
}

function handleMessage(line) {
  log(line);
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (_) {
    return;  // ignore malformed input
  }
  const { id, method, params } = msg;
  switch (method) {
    case 'initialize':
      reply(id, {
        protocolVersion: '2024-11-05',
        capabilities: {},
        serverInfo: { name: 'mcp-server-stub', version: '0.0.0' },
      });
      break;
    case 'initialized':
    case 'notifications/initialized':
      // Notifications have no id/response.
      break;
    case 'tools/call':
      handleToolsCall(id, params);
      break;
    default:
      if (id !== undefined) replyError(id, -32601, `method not found: ${method}`);
  }
}

const rl = readline.createInterface({ input: process.stdin, terminal: false });
rl.on('line', handleMessage);
rl.on('close', () => process.exit(0));
