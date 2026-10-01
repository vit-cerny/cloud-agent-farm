#!/usr/bin/env bash
# Rychlý přehled stavu farmy: cíl, fronta, projekty, heartbeat.
set -u
FARM="$HOME/agent-farm-local"
export PATH="$HOME/.opencode/bin:$PATH"

[ -z "${FARM_SSH_TARGET:-}" ] && [ -f "$FARM/external/target" ] && \
  FARM_SSH_TARGET="$(tr -d '\r\n ' < "$FARM/external/target")"

echo "== farma =="
echo "cíl:      ${FARM_SSH_TARGET:-lokální VM}"
echo "pending:  $(ls "$FARM/queue/pending" 2>/dev/null | wc -l)"
echo "doing:    $(ls "$FARM/queue/doing" 2>/dev/null | wc -l)"
echo "done:     $(ls "$FARM/queue/done" 2>/dev/null | wc -l)"
if [ -f "$FARM/.heartbeat" ]; then
  echo "heartbeat: $(cat "$FARM/.heartbeat")"
fi

echo "== projekty =="
if [ -n "${FARM_SSH_TARGET:-}" ]; then
  FARM_SSH_TARGET="$FARM_SSH_TARGET" "$FARM/external/connect.sh" \
    'for d in ~/agent-farm/projects/*/; do p=$(basename "$d"); last=$(git -C "$d" log -1 --format=%ci 2>/dev/null || echo nikdy); echo "$p | posledni commit: $last"; done' 2>/dev/null
else
  for d in "$FARM"/projects/*/; do
    [ -d "$d" ] || continue
    p="$(basename "$d")"
    last="$(git -C "$d" log -1 --format=%ci 2>/dev/null || echo nikdy)"
    echo "$p | posledni commit: $last"
  done
fi
