# scripts/lib/credential.sh
# Credentials substrate: metadata I/O + backend dispatch.
# Source from any verb / lib that needs credential CRUD.
# Requires lib/common.sh sourced first (init_paths must have run).
#
# Two files per credential:
#   ${CREDENTIALS_DIR}/<name>.json     — metadata (mode 0600, NEVER secrets)
#   ${CREDENTIALS_DIR}/<name>.secret   — secret payload (backend-owned shape)
#
# Backend dispatch: metadata.backend ∈ {plaintext, keychain, libsecret}.
# Each backend exposes the same 4-fn API (secret_set/get/delete/exists).
# - plaintext  → scripts/lib/secret/plaintext.sh                  (this PR)
# - keychain   → scripts/lib/secret/keychain.sh    (phase-05 part 2b)
# - libsecret  → scripts/lib/secret/libsecret.sh   (phase-05 part 2c)
#
# AP-7: secret material flows via stdin pipes only — never argv. Helpers
# credential_set_secret / credential_get_secret use stdin/stdout exclusively.
# credential_load returns ONLY metadata; if you see a 'secret' key in its
# output, that's a privacy regression — tests/credential.bats asserts this.

[ -n "${BROWSER_SKILL_CREDENTIAL_LOADED:-}" ] && return 0
readonly BROWSER_SKILL_CREDENTIAL_LOADED=1

# --- Schema version (single source of truth for future migrations) ---
# Bump this is a [schema] change; phase-10 introduces migrate-schema.
readonly BROWSER_SKILL_CREDENTIAL_SCHEMA_VERSION=1

# Bash array (not space-separated string) so iteration is IFS-independent.
# Verb scripts set IFS=$'\n\t' which breaks word-splitting on space-separated
# strings — using "${arr[@]}" sidesteps that.
readonly _CREDENTIAL_REQUIRED_FIELDS=(schema_version name site account backend created_at)

_credential_path() {
  printf '%s/%s.json' "${CREDENTIALS_DIR}" "$1"
}

# --- Metadata CRUD ---

# credential_exists NAME — 0 if metadata file present, 1 if not.
credential_exists() {
  [ -f "$(_credential_path "$1")" ]
}

# credential_save NAME META_JSON
# Validates JSON + required fields. Refuses if NAME already exists (caller
# must credential_delete first). Mode 0600. Atomically (tmp + mv).
credential_save() {
  local name="$1" meta_json="$2"
  assert_safe_name "${name}" "credential-name"

  if ! printf '%s' "${meta_json}" | jq -e . >/dev/null 2>&1; then
    die "${EXIT_USAGE_ERROR}" "credential_save: metadata JSON is not valid"
  fi

  local field
  for field in "${_CREDENTIAL_REQUIRED_FIELDS[@]}"; do
    if ! printf '%s' "${meta_json}" | jq -e --arg f "${field}" 'has($f) and (.[$f] != null)' >/dev/null 2>&1; then
      die "${EXIT_USAGE_ERROR}" "credential_save: metadata missing required field '${field}'"
    fi
  done

  if credential_exists "${name}"; then
    die "${EXIT_USAGE_ERROR}" "credential_save: ${name} already exists; call credential_delete first"
  fi

  mkdir -p "${CREDENTIALS_DIR}"
  chmod 700 "${CREDENTIALS_DIR}"

  local path tmp
  path="$(_credential_path "${name}")"
  tmp="${path}.tmp.$$"

  ( umask 077; printf '%s\n' "${meta_json}" | jq . > "${tmp}" )
  chmod 600 "${tmp}"
  mv "${tmp}" "${path}"
}

# credential_load NAME → echoes metadata JSON (un-jq'd, exactly as on disk).
# NEVER includes the secret payload.
credential_load() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  local path
  path="$(_credential_path "${name}")"
  if [ ! -f "${path}" ]; then
    die "${EXIT_SITE_NOT_FOUND}" "credential not found: ${name}"
  fi
  cat "${path}"
}

# credential_meta_load NAME — alias for credential_load. Provided for caller
# clarity (some callers want to be explicit they're reading metadata).
credential_meta_load() {
  credential_load "$@"
}

# credential_list_names — sorted credential names, one per line. Excludes
# .secret files. Empty (or missing) CREDENTIALS_DIR prints nothing.
credential_list_names() {
  if [ ! -d "${CREDENTIALS_DIR}" ]; then
    return 0
  fi
  find "${CREDENTIALS_DIR}" -maxdepth 1 -type f -name '*.json' \
    -exec basename {} .json \; 2>/dev/null | sort
}

# credential_delete NAME — removes metadata + secret (via backend). Idempotent.
credential_delete() {
  local name="$1"
  assert_safe_name "${name}" "credential-name"
  if credential_exists "${name}"; then
    _credential_dispatch_backend "${name}" delete || true
  else
    # Try to clean up an orphan plaintext .secret with no metadata, just in case.
    rm -f "${CREDENTIALS_DIR}/${name}.secret" 2>/dev/null || true
  fi
  rm -f "$(_credential_path "${name}")"
}

# --- Backend dispatch ---
# credential_set_secret NAME — reads stdin, dispatches to backend's secret_set.
# credential_get_secret NAME — dispatches to backend's secret_get → stdout.

credential_set_secret() {
  _credential_dispatch_backend "$1" set
}

credential_get_secret() {
  _credential_dispatch_backend "$1" get
}

# Internal: dispatch a secret op (set/get/delete/exists) to the backend
# named by the credential's metadata.backend field. Backend lib is sourced
# on-demand to keep the parent shell's namespace clean.
_credential_dispatch_backend() {
  local name="$1" op="$2"
  shift 2

  local meta backend
  meta="$(credential_load "${name}")"
  backend="$(printf '%s' "${meta}" | jq -r '.backend')"

  local lib_dir
  lib_dir="$(dirname "${BASH_SOURCE[0]}")/secret"

  case "${backend}" in
    plaintext)
      # shellcheck source=/dev/null
      source "${lib_dir}/plaintext.sh"
      "secret_${op}" "${name}" "$@"
      ;;
    keychain)
      # shellcheck source=/dev/null
      source "${lib_dir}/keychain.sh"
      "secret_${op}" "${name}" "$@"
      ;;
    libsecret)
      # shellcheck source=/dev/null
      source "${lib_dir}/libsecret.sh"
      "secret_${op}" "${name}" "$@"
      ;;
    *)
      die "${EXIT_USAGE_ERROR}" "credential ${name}: unknown backend '${backend}'"
      ;;
  esac
}
