#!/usr/bin/env bash
# install-agy.sh — install the Antigravity CLI (agy) for headless agent work.
# The full Antigravity IDE needs 8 GB RAM; the CLI is a small static binary
# and runs fine on a 1 GB cloud VM. Non-interactive mode:  agy -p "prompt"
set -euo pipefail

INSTALLER="$(mktemp /tmp/agy-install-XXXX.sh)"
curl -fsSL --max-time 120 https://antigravity.google/cli/install.sh -o "$INSTALLER"

# quick sanity check before running a downloaded script
grep -q "antigravity-cli-auto-updater" "$INSTALLER" \
  || { echo "installer looks wrong, aborting"; exit 1; }
bash "$INSTALLER"
rm -f "$INSTALLER"

if ! grep -q '.local/bin' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi
export PATH="$HOME/.local/bin:$PATH"
agy --version

echo
echo "Auth (pick one):"
echo "  1) agy login            # prints a URL, approve in your browser, paste the code"
echo "  2) GEMINI_API_KEY       # set modelProvider: gemini in ~/.gemini/antigravity-cli/settings.json"
