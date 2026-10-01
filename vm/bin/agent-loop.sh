#!/usr/bin/env bash
# agent-loop.sh — 24/7 worker on the VM. Takes tasks from queue/pending,
# runs them via opencode (free models), writes COMPACT summaries to queue/done.
# Supervise over SSH by reading only the summaries (saves tokens).
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
  # the free roster changes — probe and take the first working one
  for m in $MODELS; do
    if timeout 90 opencode run --model "$m" --dir "$FARM" --title probe "Reply with exactly: PONG42" 2>/dev/null | grep -q "PONG42"; then
      MODEL="$m"; log "model OK: $m"; return 0
    fi
    log "model FAIL: $m"
  done
  MODEL=""; return 1
}

run_task() { # $1=jmeno $2=soubor s promptem $3=projekt
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
    pick_model || { log "žádný funkční free model — retry za 10 min"; sleep 600; continue; }
  fi
  # inbox: direct messages -> new tasks
  for msg in "$FARM"/inbox/*.msg; do
    [ -e "$msg" ] || break
    mv "$msg" "$Q/pending/inbox-$(basename "$msg" .msg).task"
    log "inbox -> nový úkol"
  done
  TASK="$(ls "$Q"/pending/*.task 2>/dev/null | head -1 || true)"
  if [ -z "$TASK" ]; then sleep "$IDLE_SLEEP"; continue; fi
  NAME="$(basename "$TASK" .task)"
  DIRF="${TASK%.task}.dir"
  PROJ="$(cat "$DIRF" 2>/dev/null || true)"
  [ -n "$PROJ" ] || PROJ="$(default_project)"
  mkdir -p "$PROJ" 2>/dev/null || log "WARN: nelze vytvorit projektovy adresar $PROJ"
  mv "$TASK" "$Q/doing/$NAME.task"
  [ -f "$DIRF" ] && mv "$DIRF" "$Q/doing/$NAME.dir"
  cp "$Q/doing/$NAME.task" /tmp/farm-prompt.txt
  if run_task "$NAME" /tmp/farm-prompt.txt "$PROJ"; then RC=0; else RC=$?; fi
  mv "$Q/doing/$NAME.task" "$Q/done/$NAME.task" 2>/dev/null || true
  [ -f "$Q/doing/$NAME.dir" ] && mv "$Q/doing/$NAME.dir" "$Q/done/$NAME.dir"
  if [ "$RC" != "0" ]; then
    # worker is stuck -> message for the operator (the supervisor reads it)
    { echo "NEEDS DECISION: úkol $NAME selhal (rc=$RC)"; echo "--- souhrn ---"; cat "$Q/done/$name.summary" 2>/dev/null || cat "$Q/done/$NAME.summary"; } > "$FARM/outbox/$(date +%s)-$NAME.msg"
    MODEL=""  # next time try another model (rate-limit?)
  fi
  rm -f /tmp/farm-prompt.txt
done
