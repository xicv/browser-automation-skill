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
//   - tools/call name=click            → "clicked <uid>" content (phase-5 part 1c-ii)
//   - tools/call name=fill             → "filled <uid> with <text>" content (phase-5 part 1c-ii)
//   - tools/call name=list_console_messages   → 2 canned messages (phase-5 part 1e-ii)
//   - tools/call name=list_network_requests   → 1 canned request (phase-5 part 1e-ii)
//   - tools/call name=take_screenshot         → canned path (phase-5 part 1e-ii)
//   - tools/call name=press_key               → "pressed <key>" content (phase-6 part 1)
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

// Log the spawn argv once so tests can verify the bridge forwards CLI args
// (phase-5 part 1f: --user-data-dir passthrough).
if (LOG) {
  try {
    appendFileSync(LOG, `--- spawn-argv: ${JSON.stringify(process.argv.slice(2))} ---\n`);
  } catch (_) { /* ignore */ }
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
    case 'click': {
      const uid = args.uid ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `clicked ${uid}` }],
        isError: false,
      });
      break;
    }
    case 'fill': {
      const uid = args.uid ?? '<missing>';
      const text = typeof args.text === 'string' ? args.text : '';
      reply(id, {
        content: [{ type: 'text', text: `filled ${uid} with ${text}` }],
        isError: false,
      });
      break;
    }
    case 'list_console_messages': {
      reply(id, {
        content: [{ type: 'text', text: 'console: 2 messages' }],
        messages: [
          { level: 'log',   text: 'hello world' },
          { level: 'error', text: 'oops' },
        ],
        isError: false,
      });
      break;
    }
    case 'list_network_requests': {
      reply(id, {
        content: [{ type: 'text', text: 'network: 1 request' }],
        requests: [{ url: 'https://example.com/api', method: 'GET', status: 200 }],
        isError: false,
      });
      break;
    }
    case 'take_screenshot': {
      reply(id, {
        content: [{ type: 'text', text: 'screenshot saved' }],
        path: '/tmp/cdt-mcp-stub-screenshot.png',
        isError: false,
      });
      break;
    }
    case 'press_key': {
      const key = args.key ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `pressed ${key}` }],
        isError: false,
      });
      break;
    }
    case 'wait_for': {
      const selector = args.selector ?? '<missing>';
      const state = args.state ?? 'visible';
      reply(id, {
        content: [{ type: 'text', text: `waited for ${selector} to be ${state}` }],
        isError: false,
      });
      break;
    }
    case 'hover': {
      const uid = args.uid ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `hovered ${uid}` }],
        isError: false,
      });
      break;
    }
    case 'drag': {
      const src = args.src_uid ?? '<missing>';
      const dst = args.dst_uid ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `dragged ${src} → ${dst}` }],
        isError: false,
      });
      break;
    }
    case 'upload_file': {
      const uid = args.uid ?? '<missing>';
      const path = args.path ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `uploaded ${path} to ${uid}` }],
        isError: false,
      });
      break;
    }
    case 'route_url': {
      const pattern = args.pattern ?? '<missing>';
      const action = args.action ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `routed ${pattern} → ${action}` }],
        isError: false,
      });
      break;
    }
    case 'list_pages': {
      // Phase-6 part 8-i: canned 2-tab enumeration. Real upstream returns
      // a pages array; bridge normalizes to {tab_id, url, title}.
      reply(id, {
        content: [{ type: 'text', text: 'list_pages: 2 pages' }],
        pages: [
          { url: 'https://example.com/',     title: 'Example Domain' },
          { url: 'https://example.org/news', title: 'News' },
        ],
        isError: false,
      });
      break;
    }
    case 'select_page': {
      // Phase-6 part 8-ii: focus the page identified by tab_id. Best-effort
      // upstream tool name; real upstream may use targets.activate or similar.
      const tab_id = args.tab_id ?? '<missing>';
      const url = args.url ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `selected tab ${tab_id} (${url})` }],
        isError: false,
      });
      break;
    }
    case 'close_page': {
      // Phase-6 part 8-iii: close the page identified by tab_id. Best-effort
      // upstream tool name; real upstream may use targets.close or similar.
      const tab_id = args.tab_id ?? '<missing>';
      const url = args.url ?? '<missing>';
      reply(id, {
        content: [{ type: 'text', text: `closed tab ${tab_id} (${url})` }],
        isError: false,
      });
      break;
    }
    case 'select_option': {
      const uid = args.uid ?? '<missing>';
      let by;
      if (args.value !== undefined)      by = `value=${args.value}`;
      else if (args.label !== undefined) by = `label=${args.label}`;
      else if (args.index !== undefined) by = `index=${args.index}`;
      else                                by = 'no-mode';
      reply(id, {
        content: [{ type: 'text', text: `selected ${uid} by ${by}` }],
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
