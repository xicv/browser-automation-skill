#!/usr/bin/env bash
# scripts/browser-migrate.sh
# Phase 10 part 1-ii — schema migration verb. Sub-mode dispatch over
# lib/migrate.sh's pure read/write API (10-1-i).
#
# Sub-modes:
#   check                                    read-only; reports schemas needing migration
#   run [--yes] [--schema NAME]              run all (or one schema); --yes bypasses typed-phrase
#   rollback --schema NAME [--yes]           single-step rollback for SCHEMA
#   status                                   echoes versions.json
#   clean-backups [--keep N] [--yes]         discard backups beyond newest N (default 5)
#
# Destructive sub-modes (run/rollback/clean-backups) require either --yes
# OR a TTY-interactive typed-phrase confirmation. They also acquire a
# PID-tracked lock at ${BROWSER_SKILL_HOME}/.migrate.lock to prevent
# concurrent migrations.

set -euo pipefail
IFS=$'\n\t'
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}"
export SCRIPTS_DIR

# shellcheck source=lib/common.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/output.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/output.sh"
# shellcheck source=lib/migrate.sh
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/migrate.sh"

init_paths

SUMMARY_T0="$(now_ms)"

usage() {
  cat <<'USAGE'
Usage:
  browser-migrate check                                  read-only; reports schemas needing migration
  browser-migrate status                                 echoes versions.json
  browser-migrate run [--yes] [--schema NAME]            run all (or one schema)
  browser-migrate rollback --schema NAME [--yes]         single-step rollback for SCHEMA
  browser-migrate clean-backups [--keep N] [--yes]       discard backups beyond newest N

Destructive sub-modes (run, rollback, clean-backups) require --yes OR
TTY-interactive typed-phrase confirmation.
USAGE
}

# --- Lock helpers ---

_acquire_migrate_lock() {
  local lock_path="${BROWSER_SKILL_HOME}/.migrate.lock"
  if [ -f "${lock_path}" ]; then
    local owner_pid
    owner_pid="$(jq -r '.pid // empty' "${lock_path}" 2>/dev/null || true)"
    if [ -n "${owner_pid}" ] && [ "${owner_pid}" != "null" ] && kill -0 "${owner_pid}" 2>/dev/null; then
      die "${EXIT_USAGE_ERROR}" "browser-migrate: another migration in progress (pid ${owner_pid}); wait or kill it"
    fi
    warn "browser-migrate: stale lock from pid ${owner_pid:-?} cleared"
    rm -f "${lock_path}"
  fi
  printf '%s' "$(jq -nc --arg pid "$$" --arg now "$(now_iso)" \
    '{pid:($pid|tonumber), acquired_at:$now}')" > "${lock_path}"
  chmod 600 "${lock_path}"
  trap '_release_migrate_lock' EXIT
}

_release_migrate_lock() {
  rm -f "${BROWSER_SKILL_HOME}/.migrate.lock"
}

# --- Confirmation ---

# _confirm_phrase EXPECTED
# When --yes flag set (ARG_YES=1), skip. Otherwise require interactive TTY +
# read one line from stdin matching EXPECTED. Refuse on mismatch.
_confirm_phrase() {
  local expected="$1"
  if [ "${arg_yes:-0}" = "1" ]; then return 0; fi
  if [ ! -t 0 ]; then
    die "${EXIT_TTY_REQUIRED}" "browser-migrate: --yes flag required when no TTY (interactive confirmation needs TTY)"
  fi
  printf "type '%s' to confirm:\n" "${expected}" >&2
  local line
  IFS= read -r line
  [ "${line}" = "${expected}" ] || die "${EXIT_USAGE_ERROR}" "browser-migrate: confirmation mismatch; aborted"
}

# --- Sub-mode dispatch ---

sub_mode="${1:-}"
[ -n "${sub_mode}" ] || { usage >&2; die "${EXIT_USAGE_ERROR}" "browser-migrate: missing sub-mode (check / run / rollback / status / clean-backups)"; }
shift

case "${sub_mode}" in
  -h|--help) usage; exit 0 ;;
  check|status|run|rollback|clean-backups) ;;
  *) die "${EXIT_USAGE_ERROR}" "browser-migrate: unknown sub-mode '${sub_mode}' (expected: check / run / rollback / status / clean-backups)" ;;
esac

# --- check ---

if [ "${sub_mode}" = "check" ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-migrate check: unknown flag '$1'" ;;
    esac
  done
  migrate_check
  exit 0
fi

# --- status ---

if [ "${sub_mode}" = "status" ]; then
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-migrate status: unknown flag '$1'" ;;
    esac
  done
  migrate_status
  exit 0
fi

# --- run ---

if [ "${sub_mode}" = "run" ]; then
  arg_yes=0 arg_schema=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)    arg_yes=1; shift ;;
      --schema) arg_schema="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-migrate run: unknown flag '$1'" ;;
    esac
  done
  _confirm_phrase "migrate now"
  _acquire_migrate_lock
  if [ -n "${arg_schema}" ]; then
    migrate_run "${arg_schema}"
  else
    migrate_run
  fi
  exit 0
fi

# --- rollback ---

if [ "${sub_mode}" = "rollback" ]; then
  arg_yes=0 arg_schema=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)    arg_yes=1; shift ;;
      --schema) arg_schema="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-migrate rollback: unknown flag '$1'" ;;
    esac
  done
  [ -n "${arg_schema}" ] || die "${EXIT_USAGE_ERROR}" "browser-migrate rollback: --schema NAME required"
  _confirm_phrase "migrate rollback ${arg_schema}"
  _acquire_migrate_lock
  migrate_rollback "${arg_schema}"
  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  summary_json verb=migrate mode=rollback schema="${arg_schema}" \
    duration_ms="${duration_ms}" status=ok
  exit 0
fi

# --- clean-backups ---

if [ "${sub_mode}" = "clean-backups" ]; then
  arg_yes=0 arg_keep="5"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)  arg_yes=1; shift ;;
      --keep) arg_keep="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "${EXIT_USAGE_ERROR}" "browser-migrate clean-backups: unknown flag '$1'" ;;
    esac
  done
  _confirm_phrase "clean backups"
  _acquire_migrate_lock
  migrate_clean_backups "${arg_keep}"
  duration_ms=$(( $(now_ms) - SUMMARY_T0 ))
  summary_json verb=migrate mode=clean-backups keep="${arg_keep}" \
    duration_ms="${duration_ms}" status=ok
  exit 0
fi
