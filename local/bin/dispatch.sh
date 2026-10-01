#!/usr/bin/env bash
# Agent Farm dispatcher — zpracuje nejstarší čekající úkol z fronty.
# Volá se z cronu (ideálně každých 30 min) nebo ručně. Najednou běží max 1 úkol.
set -u

FARM="$HOME/agent-farm-local"
PENDING="$FARM/queue/pending"
DOING="$FARM/queue/doing"
DONE="$FARM/queue/done"
LOGS="$FARM/logs"
LOCKDIR="$FARM/.dispatch.lock"
export PATH="$HOME/.opencode/bin:$HOME/.bun/bin:$PATH"

# Externí server: pokud existuje soubor external/target (např. "ubuntu@1.2.3.4"),
# běží agenti přes SSH tam místo na lokální VM.
if [ -z "${FARM_SSH_TARGET:-}" ] && [ -f "$FARM/external/target" ]; then
  FARM_SSH_TARGET="$(tr -d '\r\n ' < "$FARM/external/target")"
fi

mkdir -p "$PENDING" "$DOING" "$DONE" "$LOGS"

# Zámek — druhá instance se tiše ukončí
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  echo "Další dispatch právě běží. Končím."
  exit 0
fi
trap 'rmdir "$LOCKDIR" 2>/dev/null' EXIT

# Zotavení: co zůstalo v doing/ po zabitém běhu, vrať do fronty
for stale in "$DOING"/*; do
  [ -e "$stale" ] || continue
  echo "Vracím nedokončený úkol $(basename "$stale") zpět do fronty."
  mv "$stale" "$PENDING/"
done

# Preflight: bez přihlášení k modelům nemá běh smysl — selži rychle
oc_auth_list() {
  if [ -n "${FARM_SSH_TARGET:-}" ]; then
    "$FARM/external/connect.sh" 'export PATH=$HOME/.opencode/bin:$PATH; opencode auth list' 2>/dev/null
  else
    export PATH="$HOME/.opencode/bin:$PATH"
    opencode auth list 2>/dev/null
  fi
}
auth_missing=1
if oc_auth_list | grep -q "0 credentials"; then
  # Lokálně ještě zkus env proměnné; vzdáleně klíč musí být přihlášený na serveru
  if [ -z "${FARM_SSH_TARGET:-}" ]; then
    for v in ANTHROPIC_API_KEY OPENAI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY GEMINI_API_KEY OPENROUTER_API_KEY; do
      if [ -n "${!v:-}" ]; then auth_missing=0; break; fi
    done
  fi
else
  auth_missing=0
fi
if [ "$auth_missing" = "1" ]; then
  echo "MODEL_AUTH_MISSING: OpenCode nemá přihlášení k žádnému modelu."
  echo "Uživatel musí vytvořit API klíč na https://opencode.ai/auth a předat ho Musemu."
  exit 3
fi

task="$(ls -1 "$PENDING" 2>/dev/null | head -n 1)"
if [ -z "$task" ]; then
  echo "Fronta je prázdná. Není co dělat."
  exit 0
fi

ts="$(date +%Y%m%d-%H%M%S)"
mv "$PENDING/$task" "$DOING/$task"

# Formát souboru úkolu: 1. řádek = jméno projektu, zbytek = prompt pro agenta
project="$(head -n 1 "$DOING/$task" | tr -d '\r')"
if [ -z "$project" ]; then project="obecne"; fi

log="$LOGS/${ts}-${task%.md}.log"
promptfile="$(mktemp)"
tail -n +2 "$DOING/$task" > "$promptfile"
{
  echo "=== úkol:    $task"
  echo "=== cíl:     ${FARM_SSH_TARGET:-lokální VM}"
  if [ -n "${FARM_SSH_TARGET:-}" ]; then
    # Externí server přes SSH (prompt jde přes stdin)
    FARM_SSH_TARGET="$FARM_SSH_TARGET" "$FARM/external/connect.sh" \
      "bash ~/agent-farm/bin/run-agent.sh '$project'" < "$promptfile"
  else
    "$FARM/bin/run-agent.sh" "$project" < "$promptfile"
  fi
  echo "=== exit:    $?"
} > "$log" 2>&1
rm -f "$promptfile"

mv "$DOING/$task" "$DONE/${ts}-${task}"
echo "Hotovo: $task"
echo "Log: $log"
echo "Cíl: ${FARM_SSH_TARGET:-lokální VM}"
