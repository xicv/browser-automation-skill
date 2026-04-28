#!/usr/bin/env bash
# tests/run.sh — runs the bats unit suite; nothing more (e2e + lint live elsewhere).
set -euo pipefail
IFS=$'\n\t'

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

if ! command -v bats >/dev/null 2>&1; then
  printf 'bats not installed. Install: brew install bats-core (macOS) or apt install bats (Linux)\n' >&2
  exit 20
fi

bats --tap tests/*.bats
