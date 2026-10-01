#!/usr/bin/env bash
# farm-one-click.sh - THE ONE FILE to upload to your cloud VM.
#
# Upload: file manager (:8080) or web SSH "Upload file" -> puts it in $HOME.
# Then run ONE command in the VM web terminal:
#   bash ~/farm-one-click.sh
# If you also upload your openchamber-full-*.zip[.enc] next to it, your
# skills, agents, commands, MCPs, settings and keys are restored too.
# Otherwise you get a fresh working farm (same code as vm/setup-farm-vm.sh).
#
# Safe to re-run. Needs: Ubuntu 22.04/24.04, ~1 GB RAM, ports 3000 + 8080.
# ponytail: stdlib only (curl/unzip/openssl), everything else inline.
set -euo pipefail

FARM="$HOME/agent-farm"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
BUNDLE="${1:-}"
if [ -z "$BUNDLE" ]; then
  for d in "$SCRIPT_DIR" "$HOME" "$FARM"; do
    CAND="$(ls -t "$d"/openchamber-full-*.zip.enc "$d"/openchamber-full-*.zip 2>/dev/null | head -1 || true)"
    if [ -n "$CAND" ]; then BUNDLE="$CAND"; break; fi
  done
fi

SUDO=""
if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO="sudo"; fi

mkdir -p "$FARM"/bin "$FARM"/queue/{pending,doing,done} "$FARM"/projects "$FARM"/inbox "$FARM"/outbox "$FARM"/logs

echo "== 1/6 system deps =="
if command -v apt-get >/dev/null 2>&1 && [ -n "$SUDO" ]; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq curl unzip git openssl cron python3 > /dev/null
else
  echo "  (no apt/sudo - assuming curl unzip git openssl python3 exist)"
fi

echo "== 2/6 bun + opencode + openchamber =="
export PATH="$HOME/.bun/bin:$HOME/.opencode/bin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
if ! command -v bun >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    x86_64) BUN_ZIP="bun-linux-x64.zip" ;;
    aarch64) BUN_ZIP="bun-linux-aarch64.zip" ;;
    *) echo "unsupported arch: $ARCH"; exit 1 ;;
  esac
  curl -fsSL --max-time 180 "https://github.com/oven-sh/bun/releases/latest/download/$BUN_ZIP" -o /tmp/bun.zip
  unzip -o -q /tmp/bun.zip -d /tmp
  mkdir -p "$HOME/.bun/bin"
  mv "/tmp/bun-linux-$ARCH/bun" "$HOME/.bun/bin/bun"
  rm -rf /tmp/bun.zip "/tmp/bun-linux-$ARCH"
fi
if ! command -v opencode >/dev/null 2>&1; then
  curl -fsSL --max-time 120 https://opencode.ai/install -o /tmp/opencode-install.sh
  bash /tmp/opencode-install.sh
  rm -f /tmp/opencode-install.sh
fi
if [ ! -d "$HOME/.bun/install/global/node_modules/@openchamber/web" ]; then
  bun install -g @openchamber/web
fi
if [ ! -f "$FARM/.openchamber.env" ]; then
  PW="$(openssl rand -base64 18)"
  printf 'OPENCHAMBER_PORT=3000\nOPENCHAMBER_HOST=0.0.0.0\nOPENCHAMBER_UI_PASSWORD=%s\n' "$PW" > "$FARM/.openchamber.env"
  chmod 600 "$FARM/.openchamber.env"
  echo "  OpenChamber UI password (saved in $FARM/.openchamber.env): $PW"
fi

echo "== 3/6 filebrowser =="
if [ ! -x "$HOME/filebrowser/filebrowser" ]; then
  mkdir -p "$HOME/filebrowser"
  ARCH2="$(uname -m)"; case "$ARCH2" in x86_64) FB=linux-amd64 ;; aarch64) FB=linux-arm64 ;; *) FB=linux-amd64 ;; esac
  curl -fsSL --max-time 120 "https://github.com/filebrowser/filebrowser/releases/latest/download/$FB-filebrowser.tar.gz" -o /tmp/filebrowser.tgz
  tar -xz -C "$HOME/filebrowser" -f /tmp/filebrowser.tgz
  rm -f /tmp/filebrowser.tgz
  "$HOME/filebrowser/filebrowser" -d "$HOME/filebrowser/filebrowser.db" config init --root "$FARM" >/dev/null
fi

echo "== 4/6 worker files =="
[ -f "$FARM/.farm.env" ] || cat > "$FARM/.farm.env" <<'EOF'
# Free/cheap models for the worker (first working one wins; the roster changes).
FARM_MODELS="opencode/muse-spark-1.3-contributor-free opencode/longcat-2.5-preview-free opencode/mimo-v2.6-flash-free opencode/mimo-v2.5-free opencode/nemotron-3.5-lightning-free"
FARM_TASK_TIMEOUT=3600
FARM_IDLE_SLEEP=120
FARM_SUMMARY_LINES=30
EOF

cat > "$FARM/bin/agent-loop.sh" <<'LOOP_EOF'
#!/usr/bin/env bash
# agent-loop.sh - 24/7 worker on the VM. Takes tasks from queue/pending,
# runs them via opencode (free models), writes COMPACT summaries to queue/done.
set -u
export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:/usr/local/bin:/usr/bin:/bin"
FARM="$HOME/agent-farm"
[ -f "$FARM/.farm.env" ] && . "$FARM/.farm.env"
MODELS="${FARM_MODELS:-opencode/muse-spark-1.3-contributor-free opencode/longcat-2.5-preview-free opencode/mimo-v2.6-flash-free opencode/mimo-v2.5-free opencode/nemotron-3.5-lightning-free}"
TASK_TIMEOUT="${FARM_TASK_TIMEOUT:-3600}"
IDLE_SLEEP="${FARM_IDLE_SLEEP:-120}"
SUMMARY_LINES="${FARM_SUMMARY_LINES:-30}"
Q="$FARM/queue"; LOG="$FARM/logs"
mkdir -p "$Q"/{pending,doing,done} "$LOG" "$FARM"/{inbox,outbox} "$FARM"/projects
heartbeat() { date +%s > "$Q/heartbeat"; echo "alive $(date -u +%FT%TZ) model=${MODEL:-none}" > "$Q/status"; }
log() { echo "[agent-loop $(date -u +%FT%TZ)] $*"; }
opencode_authed() { [ -s "$HOME/.local/share/opencode/auth.json" ]; }
default_project() {
  d="$(ls -d "$FARM"/projects/*/ 2>/dev/null | head -1)"
  [ -n "$d" ] && echo "$d" || echo "$FARM"
}
pick_model() {
  for m in $MODELS; do
    if timeout 90 opencode run --model "$m" --dir "$FARM" --title probe "Reply with exactly: PONG42" 2>/dev/null | grep -q "PONG42"; then
      MODEL="$m"; log "model OK: $m"; return 0
    fi
    log "model FAIL: $m"
  done
  MODEL=""; return 1
}
run_task() {
  local name="$1" pf="$2" proj="$3" start end rc pid
  local lf="$LOG/$name.log"
  start=$(date +%s)
  log "start: $name (projekt: $proj, model: $MODEL)"
  ( timeout "$TASK_TIMEOUT" opencode run --model "$MODEL" --dir "$proj" --title "$name" "$(cat "$pf")" >"$lf" 2>&1
    echo $? >"$lf.rc" ) &
  pid=$!
  while kill -0 $pid 2>/dev/null; do heartbeat; sleep 60; done
  wait $pid 2>/dev/null
  rc=$(cat "$lf.rc" 2>/dev/null || echo 99); rm -f "$lf.rc"
  end=$(date +%s)
  { echo "task: $name"; echo "model: $MODEL"; echo "rc: $rc"; echo "took: $((end-start))s";
    echo "--- tail ---"; tail -n "$SUMMARY_LINES" "$lf"; } | head -c 4000 > "$Q/done/$name.summary"
  log "done: $name rc=$rc"
  return "$rc"
}
MODEL=""
while true; do
  heartbeat
  if ! opencode_authed; then
    echo "waiting-auth $(date -u +%FT%TZ)" > "$Q/status"
    log "waiting for 'opencode auth login' (API key)"
    sleep 300; continue
  fi
  if [ -z "$MODEL" ]; then
    pick_model || { log "no working free model - retry in 10 min"; sleep 600; continue; }
  fi
  for msg in "$FARM"/inbox/*.msg; do
    [ -e "$msg" ] || break
    mv "$msg" "$Q/pending/inbox-$(basename "$msg" .msg).task"
    log "inbox -> new task"
  done
  TASK="$(ls "$Q"/pending/*.task 2>/dev/null | head -1 || true)"
  if [ -z "$TASK" ]; then sleep "$IDLE_SLEEP"; continue; fi
  NAME="$(basename "$TASK" .task)"
  DIRF="${TASK%.task}.dir"
  PROJ="$(cat "$DIRF" 2>/dev/null || true)"
  [ -n "$PROJ" ] || PROJ="$(default_project)"
  mkdir -p "$PROJ" 2>/dev/null || log "WARN: cannot create project dir $PROJ"
  mv "$TASK" "$Q/doing/$NAME.task"
  [ -f "$DIRF" ] && mv "$DIRF" "$Q/doing/$NAME.dir"
  cp "$Q/doing/$NAME.task" /tmp/farm-prompt.txt
  if run_task "$NAME" /tmp/farm-prompt.txt "$PROJ"; then RC=0; else RC=$?; fi
  mv "$Q/doing/$NAME.task" "$Q/done/$NAME.task" 2>/dev/null || true
  [ -f "$Q/doing/$NAME.dir" ] && mv "$Q/doing/$NAME.dir" "$Q/done/$NAME.dir"
  if [ "$RC" != "0" ]; then
    { echo "NEEDS DECISION: task $NAME failed (rc=$RC)"; echo "--- summary ---"; cat "$Q/done/$NAME.summary"; } > "$FARM/outbox/$(date +%s)-$NAME.msg"
    MODEL=""
  fi
  rm -f /tmp/farm-prompt.txt
done
LOOP_EOF

cat > "$FARM/bin/openchamber-run.sh" <<'RUN_EOF'
#!/usr/bin/env bash
# Runs the OpenChamber server in the foreground (for systemd).
set -u
PORT="${OPENCHAMBER_PORT:-3000}"
HOST="${OPENCHAMBER_HOST:-0.0.0.0}"
BUN=""
for b in "$HOME/.bun/bin/bun" "$(command -v bun 2>/dev/null || true)"; do
  if [ -n "$b" ] && [ -x "$b" ]; then BUN="$b"; break; fi
done
[ -n "$BUN" ] || { echo "ERR: bun not found"; exit 1; }
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
RUN_EOF
chmod +x "$FARM/bin/agent-loop.sh" "$FARM/bin/openchamber-run.sh"

echo "== 5/6 your config bundle =="
if [ -n "$BUNDLE" ] && [ -f "$BUNDLE" ]; then
  echo "  bundle: $BUNDLE"
  WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
  SRC="$BUNDLE"
  case "$BUNDLE" in
    *.enc)
      read -rsp "Bundle passphrase: " PASSP; echo
      openssl enc -d -aes-256-cbc -pbkdf2 -in "$BUNDLE" -out "$WORK/bundle.dec" -pass pass:"$PASSP"
      unset PASSP
      SRC="$WORK/bundle.dec" ;;
  esac
  unzip -q -o "$SRC" -d "$WORK"
  STAMP="$(date +%Y%m%d-%H%M%S)"
  put_dir() {
    [ -d "$1" ] || return 0
    [ -e "$2" ] && mv "$2" "$2.bak-$STAMP" && echo "  backup: $2"
    mkdir -p "$(dirname "$2")"; cp -r "$1" "$2"; echo "  import: $2"
  }
  put_dir "$WORK/config/opencode" "$HOME/.config/opencode"
  put_dir "$WORK/config/openchamber" "$HOME/.config/openchamber"
  if [ -f "$WORK/auth/opencode-share/auth.json" ]; then
    mkdir -p "$HOME/.local/share/opencode"
    [ -f "$HOME/.local/share/opencode/auth.json" ] && mv "$HOME/.local/share/opencode/auth.json" "$HOME/.local/share/opencode/auth.json.bak-$STAMP"
    cp -f "$WORK/auth/opencode-share/auth.json" "$HOME/.local/share/opencode/auth.json"
    chmod 600 "$HOME/.local/share/opencode/auth.json"
    echo "  import (600): auth.json"
  fi
  if [ -f "$WORK/auth/opencode-share/opencode.db" ]; then
    cp -f "$WORK/auth/opencode-share/opencode.db" "$HOME/.local/share/opencode/opencode.db"
    echo "  import: opencode.db (chat history)"
  fi
  # Windows paths do not exist here - fix them, keep JSON valid.
  if [ -f "$HOME/.config/opencode/opencode.jsonc" ]; then
    AGY="$(command -v agy || echo "$HOME/.local/bin/agy")"
    python3 - "$HOME/.config/opencode/opencode.jsonc" "$AGY" <<'PYEOF' || echo "  WARN: could not patch opencode.jsonc paths (edit by hand)"
import json, sys
p, agy = sys.argv[1], sys.argv[2]
d = json.load(open(p))
try:
  d["provider"]["antigravity"]["command"] = agy
except KeyError:
  pass
try:
  import os
  jev = d["mcp"]["jev"]["command"]
  if not os.path.exists(jev[0]):
    d["mcp"]["jev"]["enabled"] = False
except KeyError:
  pass
json.dump(d, open(p, "w"), indent=2)
print("  patched: antigravity.command ->", agy, "+ jev disabled if venv missing")
PYEOF
  fi
  rm -rf "$WORK"; trap - EXIT
  case "$(basename "$BUNDLE")" in
    openchamber-full-*.zip.enc) rm -f "$BUNDLE" && echo "  removed bundle (keys were inside)" ;;
  esac
else
  echo "  (no openchamber-full-*.zip[.enc] next to the script - fresh farm, add your bundle later and re-run)"
fi

echo "== 6/6 services =="
mkdir -p "$HOME/.config/systemd/user"
U="${USER:-$(whoami)}"; H="$HOME"
mk_unit_file() {
  printf '[Unit]\nDescription=%s\nAfter=network-online.target\nWants=network-online.target\n\n[Service]\n' "$2"
  [ -n "${3:-}" ] && printf 'EnvironmentFile=%s\n' "$3"
  [ -n "${4:-}" ] && printf 'WorkingDirectory=%s\n' "$4"
  printf 'ExecStart=%s\nRestart=always\nRestartSec=%s\n' "$5" "$6"
  printf '\n[Install]\nWantedBy=%s\n' "$7"
}
mk_unit_file "Farm agent worker loop 24/7" "" "" "$H/agent-farm/bin/agent-loop.sh" 10 multi-user.target > "$HOME/.config/systemd/user/farm-agent.service"
mk_unit_file "OpenChamber 24/7 (agent farm UI)" "$H/agent-farm/.openchamber.env" "" "$H/agent-farm/bin/openchamber-run.sh" 5 multi-user.target > "$HOME/.config/systemd/user/openchamber.service"
mk_unit_file "Filebrowser - agent farm file manager" "" "$H/filebrowser" "$H/filebrowser/filebrowser" 5 multi-user.target > "$HOME/.config/systemd/user/filebrowser.service"
if [ -n "$SUDO" ]; then
  for svc in farm-agent openchamber filebrowser; do
    $SUDO cp "$HOME/.config/systemd/user/$svc.service" "/etc/systemd/system/$svc.service"
  done
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now farm-agent openchamber filebrowser
  echo "  system services: enabled + started"
else
  systemctl --user daemon-reload 2>/dev/null || true
  systemctl --user enable --now farm-agent openchamber filebrowser 2>/dev/null || echo "  WARN: could not start user services - run with sudo once"
fi

echo
echo "HOTOVO."
echo "  OpenChamber UI : http://YOUR_VM_IP:3000  (password: cat $FARM/.openchamber.env)"
echo "  File manager   : http://YOUR_VM_IP:8080  (upload <name>.task into queue/pending/)"
echo "  Logs           : $FARM/logs/<task>.log, summaries in queue/done/*.summary"
if [ ! -s "$HOME/.local/share/opencode/auth.json" ]; then
  echo "  Still needed  : 'opencode auth login' so the worker can think (or re-run with your bundle)."
fi
