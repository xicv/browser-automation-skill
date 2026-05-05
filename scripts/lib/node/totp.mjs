#!/usr/bin/env node
// scripts/lib/node/totp.mjs — pure-node RFC 6238 TOTP code generator.
//
// Reads base32-encoded shared secret from stdin (typical TOTP issuer output:
// "JBSWY3DPEHPK3PXP" etc.), produces the 6-digit code for the current 30s
// window. No external dependencies (uses node's crypto module).
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

import { createHmac } from 'node:crypto';

function base32Decode(b32) {
  const ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  const cleaned = b32.toUpperCase().replace(/=+$/g, '').replace(/\s+/g, '');
  let bits = '';
  for (const ch of cleaned) {
    const i = ALPHABET.indexOf(ch);
    if (i < 0) throw new Error(`invalid base32 character: '${ch}'`);
    bits += i.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) {
    bytes.push(parseInt(bits.slice(i, i + 8), 2));
  }
  return Buffer.from(bytes);
}

function totpAt(secretBase32, timestampSec, digits = 6, period = 30, alg = 'sha1') {
  const counter = Math.floor(timestampSec / period);
  const counterBuf = Buffer.alloc(8);
  // Big-endian 64-bit counter. Math.floor + lossy 32-bit handling for the
  // upper word — acceptable for any timestamp before year ~2106.
  counterBuf.writeUInt32BE(Math.floor(counter / 0x100000000), 0);
  counterBuf.writeUInt32BE(counter >>> 0, 4);
  const key = base32Decode(secretBase32);
  const hmac = createHmac(alg, key).update(counterBuf).digest();
  const offset = hmac[hmac.length - 1] & 0x0f;
  const truncated =
    ((hmac[offset] & 0x7f) << 24) |
    (hmac[offset + 1] << 16) |
    (hmac[offset + 2] << 8) |
    hmac[offset + 3];
  const code = truncated % Math.pow(10, digits);
  return String(code).padStart(digits, '0');
}

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
