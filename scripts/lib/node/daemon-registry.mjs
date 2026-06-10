// scripts/lib/node/daemon-registry.mjs
//
// Source of truth for live daemon ownership per session. See: P0a design.
//
// Registry file: $BROWSER_SKILL_HOME/runtime/registry.json
// Dir mode 0700, file mode 0600. No credentials stored.
//
// Entry keyed by session name (or "default"):
//   { adapter, pid, ipc_port, cdp_endpoint, started_at, last_used_at }
//
// Readers MUST treat an entry as stale unless process.kill(pid, 0) succeeds.
// Stale entries are pruned on every read.
//
// Write semantics (race-safety):
//   All mutations go through _writeRaw which writes to a per-pid temp file
//   then renames over registry.json — atomic on any POSIX fs (same directory).
//   The temp file is opened O_CREAT with mode 0o600 so there is no window
//   where the file is world-readable.
//
//   writeRegistryEntry and removeRegistryEntry hold an advisory lockfile
//   (registry.json.lock, acquired via O_CREAT|O_EXCL) around read-merge-write
//   so concurrent daemon starts don't clobber each other's entries.
//   Lock retry: every 50 ms up to 2 s; stale lock (>5 s old) is broken.

import { readFileSync, writeFileSync, existsSync, mkdirSync, openSync, closeSync, renameSync, unlinkSync, statSync, constants } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';

function browserSkillHome() {
  return process.env.BROWSER_SKILL_HOME || join(homedir(), '.browser-skill');
}

export function registryPath() {
  return join(browserSkillHome(), 'runtime', 'registry.json');
}

function isPidAlive(pid) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (_) {
    return false;
  }
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

/**
 * readRawRegistry — reads and parses the registry file without any side effects.
 * Returns {} if file missing or unparseable.
 */
function readRawRegistry() {
  const p = registryPath();
  if (!existsSync(p)) return {};
  try {
    return JSON.parse(readFileSync(p, 'utf-8'));
  } catch (_) {
    return {};
  }
}

/**
 * _writeRaw — atomically writes data to registry.json.
 * Writes to a per-pid temp file (mode 0o600) then renames over the target.
 * No window where the file is world-readable.
 */
function _writeRaw(data) {
  const p = registryPath();
  const dir = dirname(p);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const tmp = `${p}.tmp.${process.pid}`;
  // Open with mode 0o600 so the file is never world-readable, even transiently.
  const fd = openSync(tmp, constants.O_CREAT | constants.O_WRONLY | constants.O_TRUNC, 0o600);
  try {
    writeFileSync(fd, JSON.stringify(data, null, 2));
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, p);
}

/**
 * _acquireLock — advisory lock via O_CREAT|O_EXCL.
 * Retries every 50 ms up to 2 s. Breaks stale locks older than 5 s.
 * Returns the lock path (caller must release with _releaseLock).
 */
function _acquireLock(lockPath) {
  const deadline = Date.now() + 2000;
  let staleChecked = false;
  while (Date.now() < deadline) {
    try {
      const fd = openSync(lockPath, constants.O_CREAT | constants.O_EXCL | constants.O_WRONLY, 0o600);
      closeSync(fd);
      return lockPath;
    } catch (e) {
      if (e.code !== 'EEXIST') throw e;
      // Check for stale lock once.
      if (!staleChecked) {
        staleChecked = true;
        try {
          const st = statSync(lockPath);
          if (Date.now() - st.mtimeMs > 5000) {
            try { unlinkSync(lockPath); } catch (_) {}
            continue;
          }
        } catch (_) { /* lock vanished between check and stat */ }
      }
      // Busy-wait ~50 ms.
      const t = Date.now();
      while (Date.now() - t < 50) { /* spin */ }
    }
  }
  // Could not acquire — proceed without lock rather than hanging the daemon.
  return null;
}

/**
 * _releaseLock — removes the advisory lockfile.
 */
function _releaseLock(lockPath) {
  if (!lockPath) return;
  try { unlinkSync(lockPath); } catch (_) {}
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/**
 * readRegistry — reads, prunes stale entries, rewrites, returns live entries.
 * Returns {} if file missing or unparseable.
 */
export function readRegistry() {
  const raw = readRawRegistry();

  // Prune stale (dead pid) entries.
  let pruned = false;
  const live = {};
  for (const [key, entry] of Object.entries(raw)) {
    if (entry && typeof entry.pid === 'number' && isPidAlive(entry.pid)) {
      live[key] = entry;
    } else {
      pruned = true;
    }
  }

  // Rewrite only if we actually removed something.
  if (pruned) {
    _writeRaw(live);
  }

  return live;
}

/**
 * writeRegistryEntry — merges/upserts one entry, atomically rewrites file.
 * Holds advisory lock around read-merge-write to minimize concurrent-start races.
 */
export function writeRegistryEntry(sessionName, entry) {
  const lockPath = `${registryPath()}.lock`;
  const lock = _acquireLock(lockPath);
  try {
    const current = readRawRegistry();
    current[sessionName] = { ...entry };
    _writeRaw(current);
  } finally {
    _releaseLock(lock);
  }
}

/**
 * removeRegistryEntry — removes one entry, atomically rewrites file.
 * Holds advisory lock around read-merge-write to minimize concurrent-start races.
 */
export function removeRegistryEntry(sessionName) {
  const lockPath = `${registryPath()}.lock`;
  const lock = _acquireLock(lockPath);
  try {
    const current = readRawRegistry();
    delete current[sessionName];
    _writeRaw(current);
  } finally {
    _releaseLock(lock);
  }
}

/**
 * liveEntryFor — returns entry if pid is alive, else null (and prunes).
 */
export function liveEntryFor(sessionName) {
  const reg = readRegistry();
  return reg[sessionName] || null;
}
