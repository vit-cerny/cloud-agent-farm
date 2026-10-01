#!/usr/bin/env bash
# Runs the OpenChamber server in the foreground (for systemd).
# Web UI password comes from OPENCHAMBER_UI_PASSWORD (systemd EnvironmentFile).
set -u

PORT="${OPENCHAMBER_PORT:-3000}"
HOST="${OPENCHAMBER_HOST:-0.0.0.0}"

# --- najdi bun ---
BUN=""
for b in "$HOME/.bun/bin/bun" "$(command -v bun 2>/dev/null || true)"; do
  if [ -n "$b" ] && [ -x "$b" ]; then BUN="$b"; break; fi
done
[ -n "$BUN" ] || { echo "ERR: bun not found (install: npm i -g bun)"; exit 1; }

# --- najdi openchamber server ---
SERVER=""
for s in \
  "$HOME/.bun/install/global/node_modules/@openchamber/web/server/index.js" \
  "$HOME/.npm-global/lib/node_modules/@openchamber/web/server/index.js" \
  /usr/local/lib/node_modules/@openchamber/web/server/index.js \
  /usr/lib/node_modules/@openchamber/web/server/index.js ; do
  if [ -f "$s" ]; then SERVER="$s"; break; fi
done
[ -n "$SERVER" ] || { echo "ERR: openchamber server/index.js not found"; exit 1; }

export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
export OPENCODE_BINARY="${OPENCODE_BINARY:-$HOME/.opencode/bin/opencode}"

echo "Starting OpenChamber: ${HOST}:${PORT} (server: $SERVER)"
exec "$BUN" "$SERVER" --port "$PORT" --host "$HOST"
