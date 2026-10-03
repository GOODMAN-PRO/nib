#!/usr/bin/env bash
# Hand one fleet job to Codex (codex exec, full access, non-interactive) and wait for its structured result.
#   nib-codex.sh run  <name> <worktree> <prompt-file> <schema: impl|ci> [effort]   start (if not already running) and wait up to ~9 min
#   nib-codex.sh wait <name>                                                  wait up to ~9 min more
# Prints "RUNNING <name> (<n> min)" while Codex works, "RESULT <json>" when done, or "CODEX_FAILED <reason>".
set -uo pipefail
MODE="$1"; NAME="$2"
LOGS="$HOME/Projects/Nib-ci-logs"; mkdir -p "$LOGS"
BASE="$LOGS/codex-$NAME"
if [ "$MODE" = run ]; then
  WT="$3"; PROMPT="$4"; SCHEMA="$HOME/Projects/Nib-tools/schemas/$5.json"; EFFORT="${6:-high}"
  if [ -f "$BASE.pid" ] && kill -0 "$(cat "$BASE.pid")" 2>/dev/null; then :; else
    rm -f "$BASE.exit" "$BASE.json"
    [ -d "$WT" ] || WT="$(dirname "$WT")"
    # Serialize jobs that edit the same owner's files (integration fixers): key = first Fxxx after "files owned by", else "shared".
    OWNER=""
    if grep -q "files owned by" "$PROMPT"; then
      OWNER=$(grep -o "files owned by [^(]*" "$PROMPT" | head -1 | grep -oE "F[0-9]{3}" | head -1); [ -n "$OWNER" ] || OWNER=shared
    fi
    ( if [ -n "$OWNER" ]; then L="$HOME/Projects/Nib-locks/owner-$OWNER"
        # A lock holds the BASE path of the job that owns it; it is stale once that job exited or its process is gone.
        until mkdir "$L" 2>/dev/null; do
          b=$(cat "$L/base" 2>/dev/null); p=$(cat "$b.pid" 2>/dev/null)
          if [ -z "$b" ] || [ -f "$b.exit" ] || { [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; }; then rm -rf "$L"; continue; fi
          sleep 10
        done
        echo "$BASE" > "$L/base"; trap 'rm -rf "$L"' EXIT; fi
      export NIB_JOB="$NAME"; cd "$WT" && codex exec --ignore-user-config -m "${NIB_CODEX_MODEL:-gpt-6-astra}" -c "model_reasoning_effort=\"$EFFORT\"" \
        --dangerously-bypass-approvals-and-sandbox -C "$WT" --output-schema "$SCHEMA" -o "$BASE.json" - < "$PROMPT" > "$BASE.log" 2>&1
      echo $? > "$BASE.exit" ) &
    echo $! > "$BASE.pid"; date +%s > "$BASE.start"
  fi
fi
start=$(cat "$BASE.start" 2>/dev/null || date +%s)
for i in $(seq 1 54); do
  if [ -f "$BASE.exit" ]; then
    rc=$(cat "$BASE.exit")
    if [ "$rc" = 0 ] && [ -s "$BASE.json" ] && python3 -c "import json,sys;json.load(open('$BASE.json'))" 2>/dev/null; then
      echo "RESULT $(tr -d '\n' < "$BASE.json")"; exit 0
    fi
    echo "CODEX_FAILED rc=$rc: $(grep -iE 'error|limit|quota|unauthor' "$BASE.log" | tail -3 | tr '\n' ' ' | cut -c1-400)"; exit 1
  fi
  # The job died without recording an exit code (e.g. the disk filled up): report it instead of waiting forever.
  if [ -f "$BASE.pid" ] && ! kill -0 "$(cat "$BASE.pid")" 2>/dev/null && [ ! -f "$BASE.exit" ]; then
    sleep 5; [ -f "$BASE.exit" ] || { echo 1 > "$BASE.exit"; echo "CODEX_FAILED job process died without an exit code: $(tail -3 "$BASE.log" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  fi
  sleep 10
done
echo "RUNNING $NAME ($(( ($(date +%s) - start) / 60 )) min)"
