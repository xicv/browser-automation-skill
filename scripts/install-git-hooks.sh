#!/usr/bin/env bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -d "${REPO_ROOT}/.git" ] && [ ! -f "${REPO_ROOT}/.git" ]; then
  printf 'not a git checkout: %s\n' "${REPO_ROOT}" >&2
  exit 0
fi
if ! command -v git >/dev/null 2>&1; then
  printf 'git not on PATH; cannot install hooks\n' >&2
  exit 0
fi

git -C "${REPO_ROOT}" config core.hooksPath .githooks
chmod +x "${REPO_ROOT}/.githooks/pre-commit"
printf 'pre-commit hook active (.githooks/pre-commit)\n'
