#!/usr/bin/env node
// bin/cli.mjs — symlink-safe entry-point for the browser-automation-skill MCP
// server. npm installs this file as ~/.../.bin/browser-automation-skill via
// a symlink; the bash script we delegate to (scripts/browser-mcp.sh) uses
// `cd "$(dirname ...)" && pwd` which does NOT resolve the symlink and would
// look for scripts/lib/common.sh inside .bin/ if invoked directly.
//
// import.meta.url is resolved by Node against the realpath of the loaded
// module, so fileURLToPath(...) here returns this file's true location
// inside the published package — letting us reliably locate scripts/.
//
// We forward argv + stdio so the spawned bash process speaks JSON-RPC
// over the same stdio channel its MCP client opened to us.

import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, resolve } from 'node:path';
import { existsSync } from 'node:fs';

const here = dirname(fileURLToPath(import.meta.url));
const pkgRoot = resolve(here, '..');
const script = resolve(pkgRoot, 'scripts/browser-mcp.sh');

if (!existsSync(script)) {
  console.error(
    `browser-automation-skill: missing entry script at ${script}.\n` +
      'Reinstall the package or report a packaging bug.'
  );
  process.exit(1);
}

const args = process.argv.slice(2);
const child = spawn('bash', [script, ...(args.length ? args : ['serve'])], {
  stdio: 'inherit',
  env: process.env,
});

child.on('error', (err) => {
  console.error(`browser-automation-skill: failed to spawn bash: ${err.message}`);
  process.exit(127);
});

child.on('exit', (code, signal) => {
  if (signal) {
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 0);
});

for (const sig of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(sig, () => {
    if (!child.killed) child.kill(sig);
  });
}
