#!/usr/bin/env bash
# remote-supervise.sh — run from cron every 30 minutes (by you or your assistant).
# Over SSH it reads ONLY compact summaries (saves tokens), dispatches new tasks
# from the local queue, and restarts a stuck worker loop.
# Report to chat only: task done / loop stuck / urgent outbox message.
set -u

FARM_HOME="${FARM_LOCAL:-$HOME/agent-farm-local}"
# SSH target like "user@1.2.3.4" — set FARM_TARGET in your environment or cron.
TARGET="${FARM_TARGET:-}"
[ -n "$TARGET" ] || { echo "NO TARGET (set FARM_TARGET=user@host)"; exit 0; }
KEY="${FARM_SSH_KEY:-$FARM_HOME/.ssh/farm_key}"
[ -f "$KEY" ] || { echo "NO KEY $KEY"; exit 0; }
SEEN_DIR="${FARM_SEEN_DIR:-$FARM_HOME/.seen}"
mkdir -p "$SEEN_DIR"
SEEN="$SEEN_DIR/seen_supervisor.txt"
touch "$SEEN"

# The farm on the VM runs as user 'farm' (home /home/farm);
# the SSH user has passwordless sudo, so reads go through sudo.
REMOTE_FARM="/home/farm/agent-farm"
sshq() { ssh -i "$KEY" -o ProxyCommand=none -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o BatchMode=yes "$TARGET" "$@"; }
rroot() { sshq "sudo $*"; }
seen() { grep -qxF "$1" "$SEEN" 2>/dev/null; }
mark() { echo "$1" >> "$SEEN"; }

NOW=$(date +%s)
HB=$(rroot "cat $REMOTE_FARM/queue/heartbeat 2>/dev/null || echo 0")
AGE=$(( NOW - HB ))
STATUS=$(rroot "cat $REMOTE_FARM/queue/status 2>/dev/null || echo unknown")
echo "heartbeat: ${AGE}s old | status: $STATUS"

if [ "$AGE" -gt 900 ]; then
  echo "STUCK: loop >15 min without heartbeat — restarting farm-agent"
  sshq 'sudo systemctl restart farm-agent' >/dev/null 2>&1 || true
  echo "NOTIFY: worker loop was stuck and was restarted"
fi

# 1) new tasks from the local queue -> to the VM
#    (scp cannot write farm's files directly, so via /tmp + sudo cp)
for t in "$FARM_HOME"/queue/pending/*.task; do
  [ -e "$t" ] || break
  n="$(basename "$t")"
  if ! sshq "sudo -H -u farm test -e $REMOTE_FARM/queue/pending/$n || sudo -H -u farm test -e $REMOTE_FARM/queue/doing/$n || sudo -H -u farm test -e $REMOTE_FARM/queue/done/${n%.task}.summary" 2>/dev/null; then
    if scp -i "$KEY" -o ProxyCommand=none -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$t" "$TARGET:/tmp/$n" >/dev/null 2>&1 \
       && sshq "sudo cp /tmp/$n $REMOTE_FARM/queue/pending/$n && sudo chown farm:farm $REMOTE_FARM/queue/pending/$n && sudo rm -f /tmp/$n" >/dev/null 2>&1; then
      echo "dispatch: $n"
      d="${t%.task}.dir"
      if [ -f "$d" ]; then
        dn="$(basename "$d")"
        scp -i "$KEY" -o ProxyCommand=none -o StrictHostKeyChecking=accept-new -o BatchMode=yes "$d" "$TARGET:/tmp/$dn" >/dev/null 2>&1 \
        && sshq "sudo cp /tmp/$dn $REMOTE_FARM/queue/pending/$dn && sudo chown farm:farm $REMOTE_FARM/queue/pending/$dn && sudo rm -f /tmp/$dn" >/dev/null 2>&1 || true
      fi
    fi
  fi
done

# 2) new finished summaries — COMPACT, this is all I read
for s in $(rroot "ls $REMOTE_FARM/queue/done/*.summary 2>/dev/null"); do
  n="$(basename "$s")"
  seen "done:$n" && continue
  echo "=== DONE: ${n%.summary} ==="
  rroot "cat $REMOTE_FARM/queue/done/$n"
  mark "done:$n"
  echo "NOTIFY: task ${n%.summary} finished"
done

# 3) outbox: VM -> operator (the worker needs a decision)
for m in $(rroot "ls $REMOTE_FARM/outbox/*.msg 2>/dev/null"); do
  n="$(basename "$m")"
  seen "outbox:$n" && continue
  echo "=== OUTBOX: $n ==="
  rroot "cat $REMOTE_FARM/outbox/$n"
  mark "outbox:$n"
  echo "NOTIFY: message from the VM agent — needs a decision"
done

echo "OK"
