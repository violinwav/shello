#!/bin/bash
# Installs the graphify CLI in Claude Code cloud sessions so the /graphify skill
# and the graph PreToolUse hooks in .claude/settings.json work there.
# Local machines are left alone: install graphify yourself with
#   uv tool install graphifyy==0.9.88
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

GRAPHIFY_VERSION="0.9.88"
BIN_DIR="$HOME/.local/bin"
export PATH="$BIN_DIR:$PATH"

# Make the tool directory visible to the rest of the session.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi

if command -v graphify >/dev/null 2>&1 && graphify --version 2>/dev/null | grep -q "$GRAPHIFY_VERSION"; then
  exit 0
fi

if command -v uv >/dev/null 2>&1; then
  uv tool install --force "graphifyy==$GRAPHIFY_VERSION" >&2
elif command -v pipx >/dev/null 2>&1; then
  pipx install --force "graphifyy==$GRAPHIFY_VERSION" >&2
else
  python3 -m pip install --user --quiet "graphifyy==$GRAPHIFY_VERSION" >&2
fi

graphify --version >&2
