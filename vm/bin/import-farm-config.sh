#!/usr/bin/env bash
# import-farm-config.sh — import a farm-config bundle (made by Export-FarmConfig.ps1)
# into this machine (the 24/7 farm VM). Run as the farm user (farm).
#
# Usage:  sudo -u farm bash /home/farm/agent-farm/bin/import-farm-config.sh [bundle]
#         (without an argument it takes the newest farm-config-*.zip.enc in ~/agent-farm/)
set -euo pipefail

FARM_HOME="${FARM_HOME:-/home/farm/agent-farm}"
BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  BUNDLE="$(ls -t "$FARM_HOME"/farm-config-*.zip.enc 2>/dev/null | head -1 || true)"
fi
[ -n "$BUNDLE" ] || { echo "usage: bash import-farm-config.sh [farm-config-*.zip.enc]"; echo "no bundle found in $FARM_HOME"; exit 1; }
[ -f "$BUNDLE" ] || { echo "file not found: $BUNDLE"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SRC="$BUNDLE"

case "$BUNDLE" in
  *.enc)
    read -rsp "Bundle passphrase: " PASS; echo
    PASS="$(printf '%s' "$PASS" | tr -d '\r\n')"
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$BUNDLE" -out "$WORK/bundle.dec" -pass pass:"$PASS" \
      || { echo "decryption failed — wrong passphrase?"; exit 1; }
    unset PASS
    SRC="$WORK/bundle.dec"
    ;;
esac

# unpack: tar.gz (bash export) or zip (PowerShell export)
if tar -tzf "$SRC" >/dev/null 2>&1; then
  tar -xzf "$SRC" -C "$WORK"
elif unzip -l "$SRC" >/dev/null 2>&1; then
  unzip -q -o "$SRC" -d "$WORK"
else
  echo "cannot unpack $BUNDLE (need tar.gz or zip)"; exit 1
fi
STAMP="$(date +%Y%m%d-%H%M%S)"
echo "== importing (existing configs are backed up with .bak-$STAMP) =="

put_dir() { # put_dir <src> <dest>
  [ -d "$1" ] || return 0
  [ -e "$2" ] && mv "$2" "$2.bak-$STAMP" && echo "  backup: $2"
  mkdir -p "$(dirname "$2")"
  cp -r "$1" "$2"
  echo "  import: $2"
}

put_dir "$WORK/config/opencode"    "$HOME/.config/opencode"
put_dir "$WORK/config/openchamber" "$HOME/.config/openchamber"
put_dir "$WORK/config/antigravity" "$HOME/.config/antigravity"
put_dir "$WORK/config/antigravity-cli" "$HOME/.gemini/antigravity-cli"

# auth.json holds API keys -> ~/.local/share/opencode with 600 perms
if [ -d "$WORK/auth/opencode" ]; then
  mkdir -p "$HOME/.local/share/opencode"
  for f in "$WORK"/auth/opencode/*; do
    [ -e "$f" ] || continue
    dest="$HOME/.local/share/opencode/$(basename "$f")"
    [ -e "$dest" ] && mv "$dest" "$dest.bak-$STAMP" && echo "  backup: $dest"
    cp "$f" "$dest"; chmod 600 "$dest"
    echo "  import (600): $dest"
  done
fi

# anything packed manually (extra folders) -> ~/farm-import/ for review
if [ -d "$WORK/custom" ]; then
  mkdir -p "$HOME/farm-import"
  cp -r "$WORK"/custom/* "$HOME/farm-import/" 2>/dev/null || true
  echo "  custom folders -> $HOME/farm-import/ (place them by hand or ask Muse)"
fi

# projects -> ~/agent-farm/projects
if [ -d "$WORK/projects" ]; then
  for p in "$WORK"/projects/*; do
    [ -d "$p" ] || continue
    dest="$HOME/agent-farm/projects/$(basename "$p")"
    [ -e "$dest" ] && mv "$dest" "$dest.bak-$STAMP" && echo "  backup: $dest"
    cp -r "$p" "$dest"
    echo "  project: $dest"
  done
fi

# restart farm services so the new config takes effect
for svc in openchamber farm-agent; do
  if systemctl list-unit-files 2>/dev/null | grep -q "^$svc\.service"; then
    if sudo -n systemctl restart "$svc" 2>/dev/null; then
      echo "  restarted: $svc"
    else
      echo "  (could not restart $svc — check: journalctl -u $svc)"
    fi
  fi
done

echo
echo "HOTOVO — your settings, MCPs, skills and keys are live on this machine."
echo "NOTE: MCP servers that are local programs (npx/uvx/node) need their"
echo "runtimes on this VM — tell Muse which ones you use and she will install them."

# transport artifact — don't leave API keys sitting in a zip on disk
case "$(basename "$BUNDLE")" in
  farm-config-*.zip.enc|farm-config-*.tar.gz.enc)
    rm -f "$BUNDLE" && echo "  removed bundle: $BUNDLE" ;;
esac
