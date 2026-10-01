#!/usr/bin/env bash
# talk.sh "zpráva" — přímá zpráva ode mě (Muse) VM agentovi.
# Zpráva padne do inboxu na VM, worker si ji při příštím kole vezme jako úkol.
# Použití: ./talk.sh "oprav překlep v README v projektu web"
set -u

FARM_HOME="$HOME/agent-farm-local"
TARGET="${FARM_TARGET:-}"
[ -n "$TARGET" ] || { echo "NO TARGET (set FARM_TARGET=user@host)"; exit 1; }
[ $# -gt 0 ] || { echo "Usage: $0 \"message for the VM agent\""; exit 1; }

TS="$(date +%s)"
ssh -i "$FARM_HOME/.ssh/farm_external" \
  -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -o BatchMode=yes \
  "$TARGET" "cat > ~/agent-farm/inbox/$TS.msg" <<< "$*"
echo "odesláno do inboxu VM agenta (inbox/$TS.msg)"
