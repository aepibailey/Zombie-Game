#!/usr/bin/env bash
# SessionStart hook: make the Godot CLI from project.godot's config/features
# available at ~/.local/bin/godot so the headless smoke test can run.
#
# Idempotent: a cached container that already has the right version exits
# immediately. A wrong version is replaced. The version is READ from
# project.godot, not hardcoded, so bumping the project bumps the hook.
#
# Only runs once this file is on the branch a session starts from — i.e.
# after this branch merges to the default branch.
set -euo pipefail

cd "$(git rev-parse --show-toplevel 2>/dev/null || echo "${CLAUDE_PROJECT_DIR:-.}")"

# config/features=PackedStringArray("4.3", "Forward Plus")  ->  4.3
MAJOR_MINOR="$(sed -nE 's/^config\/features=PackedStringArray\("([0-9]+\.[0-9]+)".*/\1/p' project.godot)"
if [[ -z "$MAJOR_MINOR" ]]; then
  echo "install-godot: could not read a version from project.godot config/features; skipping" >&2
  exit 0
fi
VERSION="${MAJOR_MINOR}-stable"
BIN_DIR="${HOME}/.local/bin"
BIN="${BIN_DIR}/godot"

# Fast path for a recycled-but-cached container.
if [[ -x "$BIN" ]] && "$BIN" --version 2>/dev/null | grep -q "^${MAJOR_MINOR}\.stable"; then
  echo "install-godot: ${MAJOR_MINOR}.stable already present at ${BIN}"
  exit 0
fi

NAME="Godot_v${VERSION}_linux.x86_64"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "${TMP}/${NAME}.zip" \
  "https://github.com/godotengine/godot/releases/download/${VERSION}/${NAME}.zip"
unzip -q "${TMP}/${NAME}.zip" -d "$TMP"
mkdir -p "$BIN_DIR"
install -m 0755 "${TMP}/${NAME}" "$BIN"
echo "install-godot: installed $("$BIN" --version) at ${BIN}"
