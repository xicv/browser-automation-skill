// scripts/lib/node/totp-core.mjs — pure-node RFC 6238 TOTP primitives.
//
// Extracted from totp.mjs (phase-5 part 4-ii) so playwright-driver.mjs can
// import the same logic for auto-replay (phase-5 part 4-iii). totp.mjs
// remains the CLI shim that reads stdin and calls totpAt().
//
// No external deps — uses node's built-in crypto module.

import { createHmac } from 'node:crypto';

const BASE32_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

export function base32Decode(b32) {
  const cleaned = b32.toUpperCase().replace(/=+$/g, '').replace(/\s+/g, '');
  let bits = '';
  for (const ch of cleaned) {
    const i = BASE32_ALPHABET.indexOf(ch);
    if (i < 0) throw new Error(`invalid base32 character: '${ch}'`);
    bits += i.toString(2).padStart(5, '0');
  }
  const bytes = [];
  for (let i = 0; i + 8 <= bits.length; i += 8) {
    bytes.push(parseInt(bits.slice(i, i + 8), 2));
  }
  return Buffer.from(bytes);
}

// totpAt — produce a TOTP code for a given timestamp (seconds since epoch).
// Defaults: 6 digits, 30s period, HMAC-SHA1 (per common TOTP issuer practice).
export function totpAt(secretBase32, timestampSec, digits = 6, period = 30, alg = 'sha1') {
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

// totpNow — convenience wrapper using Date.now().
export function totpNow(secretBase32, digits = 6, period = 30, alg = 'sha1') {
  return totpAt(secretBase32, Math.floor(Date.now() / 1000), digits, period, alg);
}
