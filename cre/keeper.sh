#!/usr/bin/env bash
# Runs the keeper workflow every 15s (and right at the sealed second), standing in for the DON's cron schedule while the workflow
# runs in simulation (deployed to the DON, Chainlink runs it on schedule instead).
#
#   cre/keeper.sh                 run until the current rebalance executes or defaults
#   WATCH_DIR=<dir> cre/keeper.sh keep running, and hand each new whisprr-sealed-epoch-*.json
#                                 saved in <dir> (e.g. the browser's Downloads) to the workflow
set -u
cd "$(dirname "$0")"
CRE=${CRE:-$HOME/.cre/bin/cre}
WATCH_DIR=${WATCH_DIR:-}
POLL=${POLL:-15}            # seconds between runs when nothing is imminent
RUN_TIMEOUT=${RUN_TIMEOUT:-15}
LEAD=${LEAD:-5}
last=""
while true; do
  if [ -n "$WATCH_DIR" ]; then
    newest=$(ls -t "$WATCH_DIR"/whisprr-sealed-epoch-*.json 2>/dev/null | head -1)
    if [ -n "$newest" ] && [ "$newest|$(stat -c %Y "$newest")" != "$last" ]; then
      [ -n "$last" ] && node whisprr-keeper/scripts/hand-over.mjs "$newest"
      last="$newest|$(stat -c %Y "$newest")"
    fi
  fi
  # A normal run takes 7-9s. Cap it, so a stalled call (e.g. the CLI's login check against Chainlink's
  # API) can't eat the execution tolerance: kill it and retry at once.
  out=$(timeout "$RUN_TIMEOUT" "$CRE" workflow simulate whisprr-keeper -T staging-settings --broadcast --non-interactive --trigger-index 0 2>&1)
  code=$?
  if [ $code -ne 0 ] && ! echo "$out" | grep -q "USER LOG"; then
    echo "$(date +%T) ✗ run failed or stalled (exit $code); retrying"
    sleep 1
    continue
  fi
  echo "$(date +%T) $(echo "$out" | grep -E "USER LOG|rror|✗" | sed -E 's/.*\[USER LOG\] //' | tr '\n' ' ')"
  if [ -z "$WATCH_DIR" ] && echo "$out" | grep -qE "executed at the sealed time|Executed, nothing|Defaulted|will default"; then
    break
  fi
  # Aim the next run at the sealed second instead of a fixed cycle: a run reads the chain's clock
  # a few seconds after it starts, so wake LEAD seconds early; if that's still early, it retries at once.
  togo=$(echo "$out" | grep -oE "sealed time not reached, [0-9]+s to go" | grep -oE "[0-9]+" | head -1)
  if [ -n "$togo" ] && [ "$togo" -le $((POLL + LEAD)) ]; then
    sleep $(( togo > LEAD ? togo - LEAD : 0 ))
  else
    sleep "$POLL"
  fi
done
