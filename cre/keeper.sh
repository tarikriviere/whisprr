#!/usr/bin/env bash
# Runs the keeper workflow every 20s until the current rebalance executes or defaults.
# Stand-in for the DON's cron schedule while the workflow runs in simulation
# (deploying it to the DON makes Chainlink run it on schedule instead).
set -u
cd "$(dirname "$0")"
CRE=${CRE:-$HOME/.cre/bin/cre}
while true; do
  out=$("$CRE" workflow simulate whisprr-keeper -T staging-settings --broadcast --non-interactive --trigger-index 0 2>&1)
  echo "$out" | grep -E "USER LOG|rror|✗" | sed -E 's/.*\[USER LOG\] //'
  echo "$out" | grep -qE "executed at the sealed time|Executed, nothing|Defaulted|will default" && break
  sleep 20
done
rm -f whisprr-keeper/binary.wasm
