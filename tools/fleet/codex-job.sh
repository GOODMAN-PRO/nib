#!/usr/bin/env bash
# Hand one job to Codex (codex exec, non-interactive, the user's own ~/.codex/config.toml sandbox) and wait for its
# structured result. Works on macOS, Linux and Windows Git Bash.
#   codex-job.sh run  <name> <worktree> <prompt-file> <schema> [effort]   start (if not already running), wait up to ~90 s
#   codex-job.sh wait <name>                                               wait up to ~90 s more
# <schema> names tools/fleet/schemas/<schema>.json. Prints "RUNNING <name> (<n> min)" while Codex works,
# "RESULT <json>" when done, or "CODEX_FAILED <reason>". Log: $NIB_LOGS/codex-<name>.log (default ../Nib-ci-logs).
# Env: NIB_CODEX_MODEL (default gpt-6-astra), NIB_LOGS.
set -uo pipefail
MODE="$1"; NAME="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
MAINROOT="$(dirname "$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || echo "$ROOT/.git")")"   # the main clone, also from a worktree
LOGS="${NIB_LOGS:-$(dirname "$MAINROOT")/Nib-ci-logs}"; mkdir -p "$LOGS"
BASE="$LOGS/codex-$NAME"
PY="$(command -v python3 || command -v python)"
if [ "$MODE" = run ]; then
  WT="$3"; PROMPT="$4"; SCHEMA="$HERE/schemas/$5.json"; EFFORT="${6:-high}"
  [ -f "$SCHEMA" ] || { echo "CODEX_FAILED no schema $SCHEMA"; exit 1; }
  if [ -f "$BASE.pid" ] && kill -0 "$(cat "$BASE.pid")" 2>/dev/null; then :; else
    rm -f "$BASE.exit" "$BASE.json"
    ( cd "$WT" && codex exec -m "${NIB_CODEX_MODEL:-gpt-6-astra}" -c "model_reasoning_effort=\"$EFFORT\"" \
        -c 'mcp_servers.jarvis.enabled=false' -C "$WT" --output-schema "$SCHEMA" -o "$BASE.json" - < "$PROMPT" > "$BASE.log" 2>&1
      echo $? > "$BASE.exit" ) &
    echo $! > "$BASE.pid"; date +%s > "$BASE.start"
  fi
fi
start=$(cat "$BASE.start" 2>/dev/null || date +%s)
for i in $(seq 1 9); do   # ~90 s per call, under the default Bash tool timeout; callers loop while RUNNING
  if [ -f "$BASE.exit" ]; then
    rc=$(cat "$BASE.exit")
    if [ "$rc" = 0 ] && [ -s "$BASE.json" ] && "$PY" -X utf8 -I -c "import json,sys;json.load(open(sys.argv[1],encoding='utf-8'))" "$BASE.json" 2>/dev/null; then
      echo "RESULT $(tr -d '\r\n' < "$BASE.json")"; exit 0
    fi
    echo "CODEX_FAILED rc=$rc: $(grep -iE 'error|limit|quota|unauthor' "$BASE.log" | grep -v rmcp | tail -3 | tr '\n' ' ' | cut -c1-400)"; exit 1
  fi
  if [ -f "$BASE.pid" ] && ! kill -0 "$(cat "$BASE.pid")" 2>/dev/null && [ ! -f "$BASE.exit" ]; then
    sleep 5; [ -f "$BASE.exit" ] || { echo 1 > "$BASE.exit"; echo "CODEX_FAILED job process died without an exit code: $(tail -3 "$BASE.log" | tr '\n' ' ' | cut -c1-300)"; exit 1; }
  fi
  sleep 10
done
echo "RUNNING $NAME ($(( ($(date +%s) - start) / 60 )) min)"
