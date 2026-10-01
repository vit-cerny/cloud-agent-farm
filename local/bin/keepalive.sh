#!/usr/bin/env bash
# Keep-alive farmy. Beh z cronu (idealne kazde 4 hodiny).
# 1) Heartbeat — drzi (Oracle) instanci "zivou", stoji 0 tokenu.
# 2) Kontrola projektu — kdyz je projekt >24 h bez commitu a ma KEEPALIVE.md,
#    posle agentovi lehky udrzovaci prompt.
# Bez prihlaseni k modelum jen heartbeat, zadny spam.
set -u
FARM="$HOME/agent-farm-local"
export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"
LOG="$FARM/logs/keepalive.log"
mkdir -p "$FARM/logs"

[ -z "${FARM_SSH_TARGET:-}" ] && [ -f "$FARM/external/target" ] && \
  FARM_SSH_TARGET="$(tr -d '\r\n ' < "$FARM/external/target")"
REMOTE="${FARM_SSH_TARGET:-}"

now="$(date -Is)"
echo "--- $now (cil: ${REMOTE:-lokalni}) ---" >> "$LOG"

# 1. Heartbeat
if [ -n "$REMOTE" ]; then
  # SSH prihlaseni je jako agent-farm-external, farma bezi pod farm:
  # heartbeat zapisujeme sudo do jejiho adresare (beze zmeny vlastnika).
  FARM_SSH_TARGET="$REMOTE" "$FARM/external/connect.sh" \
    'sudo -n -u farm bash -c "date -Is > /home/farm/agent-farm/.heartbeat"' 2>/dev/null \
    && echo "$now heartbeat OK (remote)" >> "$LOG" \
    || echo "$now heartbeat FAIL: server nedostupny" >> "$LOG"
else
  date -Is > "$FARM/.heartbeat"
  echo "$now heartbeat OK (lokalne)" >> "$LOG"
fi

# Pomocne: spust prikaz na farme (lokalne nebo pres SSH)
farm_exec() {
  if [ -n "$REMOTE" ]; then
    FARM_SSH_TARGET="$REMOTE" "$FARM/external/connect.sh" "$1" 2>/dev/null
  else
    bash -c "$1" 2>/dev/null
  fi
}

# 2. Bez modelu nema prompt smysl
if farm_exec 'export PATH=$HOME/.opencode/bin:$PATH; opencode auth list' | grep -q "0 credentials"; then
  echo "$now preskakuji prompty: chybi prihlaseni k modelum" >> "$LOG"
  exit 0
fi

# 3. Udrzovaci prompty pro zivoucí projekty
STALE_AFTER=86400  # 24 hodin
now_ts="$(date +%s)"
projects="$(farm_exec 'ls ~/agent-farm/projects 2>/dev/null || ls ~/agent-farm-local/projects 2>/dev/null')"
for p in $projects; do
  [ "$p" = "AGENTS.md" ] && continue
  last_ts="$(farm_exec "git -C ~/agent-farm/projects/$p log -1 --format=%ct 2>/dev/null || git -C ~/agent-farm-local/projects/$p log -1 --format=%ct 2>/dev/null || echo 0")"
  has_marker="$(farm_exec "test -f ~/agent-farm/projects/$p/KEEPALIVE.md -o -f ~/agent-farm-local/projects/$p/KEEPALIVE.md && echo yes || echo no")"
  if [ "$has_marker" = "yes" ] && [ "$((now_ts - last_ts))" -gt "$STALE_AFTER" ]; then
    echo "$now udrzovaci prompt pro projekt: $p" >> "$LOG"
    prompt="Rychla udrzbova kontrola projektu. Over, ze projekt funguje (nainstaluj zavislosti, spust testy ci build). Oprav jen rozbite veci, nic velkeho nemeni. Vse commitni do gitu. Pracuj strucne."
    if [ -n "$REMOTE" ]; then
      FARM_SSH_TARGET="$REMOTE" "$FARM/external/connect.sh" \
        "bash ~/agent-farm/bin/run-agent.sh '$p'" >> "$LOG" 2>&1 <<< "$prompt"
    else
      "$FARM/bin/run-agent.sh" "$p" >> "$LOG" 2>&1 <<< "$prompt"
    fi
  fi
done
echo "$now hotovo" >> "$LOG"
