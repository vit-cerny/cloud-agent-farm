#!/usr/bin/env bash
# setup-farm-vm.sh — turn a fresh Ubuntu 22.04/24.04 cloud VM into a 24/7 agent farm.
# Run as the farm user (e.g. 'farm'). Idempotent where it matters.
#
# What you get:
#   ~/agent-farm/bin/agent-loop.sh      24/7 worker: queue/pending/*.task -> opencode -> queue/done/*.summary
#   OpenChamber web UI on :3000         manage agents from any browser (desktop/phone)
#   Filebrowser on :8080                file manager = how you feed the worker .task files
#   agy (Antigravity CLI)               headless agent for background tasks
#
# Prerequisites: Ubuntu 22.04+, ~1 GB RAM is enough, ports 3000 and 8080 reachable.
set -euo pipefail

FARM="$HOME/agent-farm"
mkdir -p "$FARM"/{bin,queue/{pending,doing,done},projects,inbox,outbox,logs}

echo "== system deps =="
sudo apt-get update -qq
sudo apt-get install -y -qq curl unzip git openssl cron > /dev/null

echo "== bun (needed by OpenChamber) =="
if ! command -v bun >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64)  BUN_ZIP="bun-linux-x64.zip" ;;
    aarch64) BUN_ZIP="bun-linux-aarch64.zip" ;;
    *) echo "unsupported arch: $ARCH"; exit 1 ;;
  esac
  curl -fsSL --max-time 180 "https://github.com/oven-sh/bun/releases/latest/download/$BUN_ZIP" -o /tmp/bun.zip
  unzip -o -q /tmp/bun.zip -d /tmp
  mkdir -p "$HOME/.bun/bin"
  mv "/tmp/bun-linux-$ARCH/bun" "$HOME/.bun/bin/bun"
  rm -rf /tmp/bun.zip "/tmp/bun-linux-$ARCH"
fi
export PATH="$HOME/.bun/bin:$PATH"

echo "== opencode =="
if ! command -v opencode >/dev/null 2>&1; then
  curl -fsSL --max-time 120 https://opencode.ai/install -o /tmp/opencode-install.sh
  bash /tmp/opencode-install.sh
  rm -f /tmp/opencode-install.sh
fi

echo "== OpenChamber web UI =="
if [ ! -d "$HOME/.bun/install/global/node_modules/@openchamber/web" ]; then
  bun install -g @openchamber/web
fi
if [ ! -f "$FARM/.openchamber.env" ]; then
  # generate a random UI password — shown once, stored only here (chmod 600)
  PW="$(openssl rand -base64 18)"
  printf 'OPENCHAMBER_PORT=3000\nOPENCHAMBER_HOST=0.0.0.0\nOPENCHAMBER_UI_PASSWORD=%s\n' "$PW" > "$FARM/.openchamber.env"
  chmod 600 "$FARM/.openchamber.env"
  echo "OpenChamber UI password (save it, shown only once): $PW"
fi

echo "== Filebrowser =="
if [ ! -x "$HOME/filebrowser/filebrowser" ]; then
  mkdir -p "$HOME/filebrowser"
  curl -fsSL --max-time 120 https://github.com/filebrowser/filebrowser/releases/latest/download/linux-amd64-filebrowser.tar.gz \
    -o /tmp/filebrowser.tgz
  tar -xz -C "$HOME/filebrowser" -f /tmp/filebrowser.tgz
  rm -f /tmp/filebrowser.tgz
  "$HOME/filebrowser/filebrowser" -d "$HOME/filebrowser/filebrowser.db" config init --root "$FARM" >/dev/null
fi

echo "== Antigravity CLI (agy) =="
if ! command -v agy >/dev/null 2>&1 && [ ! -x "$HOME/.local/bin/agy" ]; then
  bash "$(dirname "$0")/install-agy.sh"
fi

echo "== farm config =="
[ -f "$FARM/.farm.env" ] || cp "$(dirname "$0")/../.farm.env.example" "$FARM/.farm.env"

echo "== systemd services =="
for svc in farm-agent openchamber filebrowser; do
  sudo cp "$(dirname "$0")/../systemd/$svc.service" /etc/systemd/system/$svc.service
done
sudo systemctl daemon-reload
sudo systemctl enable --now farm-agent openchamber filebrowser

echo
echo "DONE."
echo "  OpenChamber UI : http://YOUR_VM_IP:3000  (password in $FARM/.openchamber.env)"
echo "  File manager   : http://YOUR_VM_IP:8080"
echo "  Next: run 'opencode auth login' (or place auth.json in ~/.local/share/opencode/)"
echo "        and 'agy login' (or set GEMINI_API_KEY) so the workers can think."
