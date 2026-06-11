#!/usr/bin/env node
// scripts/lib/node/flow-parse.mjs — flow YAML parser (P0c fix, Phase 9 part 1-i).
//
// Reads a flow YAML file path from argv[2], parses with vendored js-yaml 4.2.0,
// validates required fields, and emits the same normalized JSON shape that the
// original hand-rolled flow_parse produced on stdout:
//
//   {"_kind":"meta","name":"...","site":"...","session":"...","vars":{...}}
//   {"_kind":"step","step_index":0,"verb":"snapshot","args":{...}}
//   {"_kind":"step","step_index":1,"verb":"fill","args":{...}}
//   ...
//
// Replaces the hand-rolled bash parser so that YAML double-quoted strings with
// inner escape sequences (e.g. "input[name=\"qual_file\"]") are decoded
// correctly rather than passing backslash-escape sequences through literally.
//
// Template placeholders (${var}, ${refs.NAME}) are preserved literally: they
// are replaced with unique sentinels before YAML parsing and restored after so
// that js-yaml never sees the bare `${` token (which is invalid YAML syntax in
// an unquoted flow-map value).
//
// Usage:
//   node scripts/lib/node/flow-parse.mjs <flow-file.yaml>
//
// Exit codes:
//   0 — parsed and emitted successfully
//   2 — usage / validation error (EXIT_USAGE_ERROR equivalent)

import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import { randomBytes } from 'node:crypto';

// Load vendored js-yaml 4.2.0 CJS build via createRequire (ESM→CJS bridge).
// Extension is .cjs (not .js) so Node respects the CJS format even in an
// "type":"module" package — .js would be treated as ESM by the runtime.
const require = createRequire(import.meta.url);
const jsyaml = require('./vendor/js-yaml.cjs');

const EXIT_USAGE_ERROR = 2;

function die(msg) {
  process.stderr.write(`flow-parse: ${msg}\n`);
  process.exit(EXIT_USAGE_ERROR);
}

const flowFile = process.argv[2];
if (!flowFile) {
  die('usage: flow-parse.mjs <flow-file.yaml>');
}

let raw;
try {
  raw = readFileSync(flowFile, 'utf8');
} catch (e) {
  die(`cannot read file '${flowFile}': ${e.message}`);
}

// Replace ${...} template placeholders with safe sentinels before parsing.
// js-yaml rejects bare `${` in unquoted YAML flow-map values (invalid YAML);
// the placeholders are restored in string values after parsing.
//
// A random run-id is derived so sentinels are collision-resistant: if the raw
// input happens to contain the generated prefix the id is regenerated (loop
// exits on first non-colliding id — astronomically fast in practice).
const sentinels = new Map();
let _runId;
do { _runId = randomBytes(4).toString('hex'); } while (raw.includes(`__FLOWVAR_${_runId}_`));
let _sidx = 0;
const escaped = raw.replace(/\$\{([^}]+)\}/g, (match) => {
  const key = `__FLOWVAR_${_runId}_${_sidx++}__`;
  sentinels.set(key, match);
  return key;
});

let doc;
try {
  doc = jsyaml.load(escaped);
} catch (e) {
  die(`YAML parse error in '${flowFile}': ${e.message}`);
}

if (!doc || typeof doc !== 'object') {
  die(`'${flowFile}' is empty or not a YAML mapping`);
}

// Restore sentinel placeholders in any string value recursively.
function restoreVars(val) {
  if (typeof val === 'string') {
    return val.replace(/__FLOWVAR_[0-9a-f]{8}_\d+__/g, (m) => sentinels.get(m) ?? m);
  }
  if (Array.isArray(val)) return val.map(restoreVars);
  if (val !== null && typeof val === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(val)) {
      out[restoreVars(k)] = restoreVars(v);
    }
    return out;
  }
  return val;
}

doc = restoreVars(doc);

// Validate required fields.
if (!doc.name || typeof doc.name !== 'string' || !doc.name.trim()) {
  die(`missing required field 'name' in '${flowFile}'`);
}
if (!Array.isArray(doc.steps)) {
  die(`missing required field 'steps' (must be a list) in '${flowFile}'`);
}

// Build vars object — flat string→string map from vars: block.
const vars = {};
if (doc.vars && typeof doc.vars === 'object' && !Array.isArray(doc.vars)) {
  for (const [k, v] of Object.entries(doc.vars)) {
    // Coerce all var values to strings (YAML may parse numbers/booleans).
    vars[k] = String(v);
  }
}

// Emit _meta line.
const meta = {
  _kind: 'meta',
  name: doc.name,
  site: typeof doc.site === 'string' ? doc.site : '',
  session: typeof doc.session === 'string' ? doc.session : '',
  vars,
};
process.stdout.write(JSON.stringify(meta) + '\n');

// Emit one _kind:step line per step.
for (let i = 0; i < doc.steps.length; i++) {
  const raw_step = doc.steps[i];
  if (!raw_step || typeof raw_step !== 'object' || Array.isArray(raw_step)) {
    die(`step ${i} is not a mapping`);
  }

  const keys = Object.keys(raw_step);
  if (keys.length !== 1) {
    die(`step ${i} must have exactly one key (the verb); got: ${JSON.stringify(keys)}`);
  }

  const verb = keys[0];
  const rawArgs = raw_step[verb];

  // Normalize args: null/undefined/empty → {}; object → pass through.
  let args;
  if (rawArgs === null || rawArgs === undefined) {
    args = {};
  } else if (typeof rawArgs === 'object' && !Array.isArray(rawArgs)) {
    // Preserve types: booleans stay boolean, numbers stay number, strings stay
    // string. flow_dispatch checks val === "true" for boolean flags; numeric
    // args pass through as numbers.
    args = {};
    for (const [k, v] of Object.entries(rawArgs)) {
      args[k] = v === null ? null : v;
    }
  } else if (typeof rawArgs === 'string' && rawArgs.trim() === '') {
    args = {};
  } else {
    die(`step ${i} (verb '${verb}') args must be a mapping or empty; got: ${JSON.stringify(rawArgs)}`);
  }

  const step = {
    _kind: 'step',
    step_index: i,
    verb,
    args,
  };
  process.stdout.write(JSON.stringify(step) + '\n');
}
