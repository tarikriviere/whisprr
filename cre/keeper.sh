#!/usr/bin/env bash
# Runs the keeper workflow every 15s, standing in for the DON's cron schedule while the workflow
# runs in simulation (deployed to the DON, Chainlink runs it on schedule instead).
#
#   cre/keeper.sh                 run until the current rebalance executes or defaults
#   WATCH_DIR=<dir> cre/keeper.sh keep running, and hand each new whisprr-sealed-epoch-*.json
#                                 saved in <dir> (e.g. the browser's Downloads) to the workflow
set -u
cd "$(dirname "$0")"
CRE=${CRE:-$HOME/.cre/bin/cre}
WATCH_DIR=${WATCH_DIR:-}
last=""
while true; do
  if [ -n "$WATCH_DIR" ]; then
    newest=$(ls -t "$WATCH_DIR"/whisprr-sealed-epoch-*.json 2>/dev/null | head -1)
    if [ -n "$newest" ] && [ "$newest|$(stat -c %Y "$newest")" != "$last" ]; then
      [ -n "$last" ] && node whisprr-keeper/scripts/hand-over.mjs "$newest"
      last="$newest|$(stat -c %Y "$newest")"
    fi
  fi
  out=$("$CRE" workflow simulate whisprr-keeper -T staging-settings --broadcast --non-interactive --trigger-index 0 2>&1)
  echo "$(date +%T) $(echo "$out" | grep -E "USER LOG|rror|✗" | sed -E 's/.*\[USER LOG\] //' | tr '\n' ' ')"
  if [ -z "$WATCH_DIR" ] && echo "$out" | grep -qE "executed at the sealed time|Executed, nothing|Defaulted|will default"; then
    break
  fi
  sleep 15
done
