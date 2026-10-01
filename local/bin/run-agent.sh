#!/usr/bin/env bash
# Spustí kódovacího agenta na jeden úkol. Prompt čte ze stdin, 1. argument = projekt.
# Funguje stejně na lokální VM i na externím serveru (farm root se detekuje).
set -u

project="${1:-obecne}"
export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"

if [ -d "$HOME/agent-farm-local" ]; then
  FARM="$HOME/agent-farm-local"      # lokální VM (Muse)
else
  FARM="$HOME/agent-farm"                # externí server
fi

MODEL="${FARM_MODEL:-opencode/longcat-2.5-preview-free}"
prompt="$(cat)"
projdir="$FARM/projects/$project"
mkdir -p "$projdir"
[ -d "$projdir/.git" ] || git -C "$projdir" init -q 2>/dev/null

echo "=== projekt: $project ($projdir)"
echo "=== model:   $MODEL"
echo "=== start:   $(date -Is)"
echo
timeout 1500 opencode run --auto --model "$MODEL" --dir "$projdir" "$prompt"
rc=$?
echo
echo "=== exit:    $rc"

# Commitni, co agent vytvořil/změnil
git -C "$projdir" add -A 2>/dev/null
git -C "$projdir" -c user.name="agent-farm" -c user.email="agent-farm@local" \
  commit -qm "agent: $project" 2>/dev/null || true

echo "=== konec:   $(date -Is)"
exit "$rc"
