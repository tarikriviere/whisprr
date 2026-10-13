#!/usr/bin/env bash
# Moves the testnet venue's prices so the demo market isn't frozen: a mean-reverting random walk
# for mSPY and mXAU every tick, a slow upward accrual for mTBILL, mUSDC pinned at $1.
# Stand-in for a real price feed (Pyth on the roadmap). Signs with PRICE_FEED_KEY, the venue owner,
# so it never races the operator's or the keeper's nonces.
#
# Run:  script/price-feed.sh          (PRICE_INTERVAL seconds between ticks, default 30)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
set -a; . ./.env; set +a
: "${PRICE_FEED_KEY:?set PRICE_FEED_KEY in .env}"
RPC="${MONAD_TESTNET_RPC:-https://testnet-rpc.monad.xyz}"
INTERVAL="${PRICE_INTERVAL:-30}"

dep() { python3 -c "import json;print(json.load(open('deployments/10143.json'))['$1'])"; }
VENUE=$(dep venue)

# symbol  address  base($)  vol per tick  drift per tick  update every N ticks
ASSETS=(
  "mSPY  $(dep mSPY)  500   0.0020 0        1"
  "mXAU  $(dep mXAU)  2500  0.0015 0        1"
  "mTBILL $(dep mTBILL) 100 0.00005 0.00002 10"
)

tick=0
while true; do
  for row in "${ASSETS[@]}"; do
    read -r sym addr base vol drift every <<<"$row"
    (( tick % every == 0 )) || continue
    cur=$(cast call "$VENUE" "priceOf(address)(uint256)" "$addr" --rpc-url "$RPC" | awk '{print $1}')
    # Next price in micro-dollars: Gaussian step plus a 2% pull back toward the base price.
    next=$(awk -v c="$cur" -v b="$base" -v s="$vol" -v d="$drift" -v seed="$RANDOM$tick" 'BEGIN{
      srand(seed); p=c/1e18; z=sqrt(-2*log(1-rand()))*cos(6.283185307*rand());
      p=p*(1+d+s*z) + 0.02*(b-p); printf "%d", p*1e6 }')
    if cast send "$VENUE" "setPrice(address,uint256)" "$addr" "${next}000000000000" \
         --private-key "$PRICE_FEED_KEY" --rpc-url "$RPC" --gas-limit 60000 >/dev/null 2>&1; then
      printf '%s  %-6s $%s\n' "$(date +%T)" "$sym" "$(awk -v m="$next" 'BEGIN{printf "%.2f", m/1e6}')"
    else
      echo "$(date +%T)  $sym: setPrice failed" >&2
    fi
  done
  tick=$((tick + 1))
  sleep "$INTERVAL"
done
