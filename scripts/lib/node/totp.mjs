#!/usr/bin/env node
// scripts/lib/node/totp.mjs — CLI shim around scripts/lib/node/totp-core.mjs.
//
// Reads base32-encoded shared secret from stdin (typical TOTP issuer output:
// "JBSWY3DPEHPK3PXP" etc.), produces the 6-digit code for the current 30s
// window. Core logic lives in totp-core.mjs so playwright-driver.mjs can
// import the same primitives for auto-replay (phase-5 part 4-iii).
//
// CLI:
//   echo -n 'BASE32SECRET' | node totp.mjs
//   → 6-digit code on stdout
//
// Optional env vars:
//   TOTP_TIME_T (integer seconds since epoch) — override "now" for tests.
//                Lets bats verify against RFC 6238 §A test vectors.
//   TOTP_DIGITS (default 6) — code length.
//   TOTP_PERIOD (default 30) — time-step in seconds.
//   TOTP_ALG    (default SHA1) — HMAC algorithm. Most providers use SHA1.

import { totpAt } from './totp-core.mjs';

async function readAllStdin() {
  return new Promise((resolve, reject) => {
    let data = '';
    process.stdin.setEncoding('utf-8');
    process.stdin.on('data', (chunk) => { data += chunk; });
    process.stdin.on('end', () => resolve(data));
    process.stdin.on('error', reject);
  });
}

const secret = (await readAllStdin()).trim();
if (!secret) {
  process.stderr.write('totp: empty secret on stdin\n');
  process.exit(2);
}

const t = process.env.TOTP_TIME_T
  ? parseInt(process.env.TOTP_TIME_T, 10)
  : Math.floor(Date.now() / 1000);
const digits = parseInt(process.env.TOTP_DIGITS || '6', 10);
const period = parseInt(process.env.TOTP_PERIOD || '30', 10);
const alg = (process.env.TOTP_ALG || 'sha1').toLowerCase();

try {
  const code = totpAt(secret, t, digits, period, alg);
  process.stdout.write(code + '\n');
  process.exit(0);
} catch (err) {
  process.stderr.write(`totp: ${err && err.message ? err.message : err}\n`);
  process.exit(1);
}
