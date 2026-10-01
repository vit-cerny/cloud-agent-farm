#!/bin/bash
# import-openchamber-full.sh - restore an openchamber-full bundle on Linux.
# Usage: bash import-openchamber-full.sh <openchamber-full-*.zip[.enc]>
# Backs up current config to *-backup-<date>, then restores. Restarts services.
# ponytail: stdlib only (unzip + openssl).
set -e
BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE=$(ls -t openchamber-full-*.zip* 2>/dev/null | head -1)
fi
if [ -z "$BUNDLE" ] || [ ! -f "$BUNDLE" ]; then
  echo "usage: bash import-openchamber-full.sh <openchamber-full-*.zip[.enc]>"; exit 1
fi
if [[ "$BUNDLE" == *.enc ]]; then
  echo "Encrypted bundle - enter passphrase:"
  OUT="${BUNDLE%.enc}"
  openssl enc -d -aes-256-cbc -pbkdf2 -in "$BUNDLE" -out "$OUT"
  BUNDLE="$OUT"
  echo "decrypted: $BUNDLE"
fi
TMP=$(mktemp -d)
unzip -q "$BUNDLE" -d "$TMP"
STAMP=$(date +%Y%m%d-%H%M%S)
restore() {
  if [ -d "$TMP/$1" ]; then
    if [ -d "$2" ]; then cp -a "$2" "$2-backup-$STAMP"; echo "[backup] $2"; fi
    mkdir -p "$2"
    cp -a "$TMP/$1/." "$2/"
    echo "[+] $2"
  else
    echo "[ ] $1 (not in bundle)"
  fi
}
echo "== restoring =="
restore "config/opencode" "$HOME/.config/opencode"
restore "config/openchamber" "$HOME/.config/openchamber"
if [ -f "$TMP/auth/opencode-share/auth.json" ]; then
  mkdir -p "$HOME/.local/share/opencode"
  cp -f "$TMP/auth/opencode-share/auth.json" "$HOME/.local/share/opencode/auth.json"
  chmod 600 "$HOME/.local/share/opencode/auth.json"
  echo "[+] auth.json"
fi
if [ -f "$TMP/auth/opencode-share/opencode.db" ]; then
  mkdir -p "$HOME/.local/share/opencode"
  cp -f "$TMP/auth/opencode-share/opencode.db" "$HOME/.local/share/opencode/opencode.db"
  echo "[+] opencode.db"
fi
rm -rf "$TMP"
# Fix Linux paths inside opencode.jsonc (Windows agy path, venv path won't exist)
if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
  echo "NOTE: check provider paths in ~/.config/opencode/opencode.jsonc"
  echo "  antigravity.command and jev python venv point at Windows paths."
  echo "  On this VM run: bash vm/setup-farm-vm.sh + bash vm/bin/install-agy.sh"
fi
systemctl --user restart farm-agent openchamber filebrowser 2>/dev/null || true
echo "DONE. Old config in *-backup-$STAMP folders."
