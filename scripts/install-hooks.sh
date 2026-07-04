#!/bin/bash
# =============================================================================
# scripts/install-hooks.sh — activa los hooks de .githooks/ en este clone.
# =============================================================================
# Adaptado del framework THYROX (mismo patron que api/scripts/install-hooks.sh).
# Idempotente: ejecuta 'git config core.hooksPath .githooks' relativo a la
# raiz del repo db.
#
# Hooks instalados:
#   - commit-msg: valida convencion Tim Pope del subject.
#   - pre-commit: exige 'set -euo pipefail' en *.sh staged (gate bash).
# =============================================================================
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/.githooks"

if [[ ! -d "$HOOKS_DIR" ]]; then
    echo "ERROR: $HOOKS_DIR no existe" >&2
    exit 1
fi

git config core.hooksPath .githooks
chmod +x "$HOOKS_DIR"/*

echo "OK: hooks activados (core.hooksPath = .githooks)"
echo "    Hooks instalados:"
for h in "$HOOKS_DIR"/*; do
    [[ -f "$h" ]] || continue
    echo "    - $(basename "$h")"
done
