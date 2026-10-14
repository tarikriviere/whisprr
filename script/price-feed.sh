#!/usr/bin/env bash
# Moves the testnet venue's prices so the demo market isn't frozen: a mean-reverting random walk
# for mSPY and mXAU every tick, a slow upward accrual for mTBILL, mUSDC pinned at $1.
# Stand-in for a real price feed (Pyth on the roadmap). Signs with PRICE_FEED_KEY, the venue owner,
# so it never races the operator's or the keeper's nonces.
#
# Run:  script/price-feed.sh          (PRICE_INTERVAL seconds between ticks, default 30; 10 looks live but costs ~4 MON/hour,
#                                       3600 costs ~0.35 MON/day)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/.foundry/bin:$PATH"
set -a; . ./.env; set +a
: "${PRICE_FEED_KEY:?set PRICE_FEED_KEY in .env}"
RPC="${MONAD_TESTNET_RPC:-https://testnet-rpc.monad.xyz}"
INTERVAL="${PRICE_INTERVAL:-30}"

dep() { python3 -c "import json;print(json.load(open('deployments/10143.json'))['$1'])"; }
VENUE=$(dep venue)

# symbol  address  base($)  vol and drift per update at the default 30s ticks  update every N x 30s
ASSETS=(
  "mSPY  $(dep mSPY)  500   0.0020 0        1"
  "mXAU  $(dep mXAU)  2500  0.0015 0        1"
  "mTBILL $(dep mTBILL) 100 0.00005 0.00002 10"
)

ME=$(cast wallet address --private-key "$PRICE_FEED_KEY")
nonce=$(cast nonce "$ME" --rpc-url "$RPC")
tick=0
while true; do
  start=$(date +%s)
  for row in "${ASSETS[@]}"; do
    read -r sym addr base vol drift every <<<"$row"
    n=1; (( every > 1 )) && n=$(( every * 30 / INTERVAL > 1 ? every * 30 / INTERVAL : 1 ))
    (( tick % n == 0 )) || continue
    cur=$(cast call "$VENUE" "priceOf(address)(uint256)" "$addr" --rpc-url "$RPC" | awk '{print $1}')
    # Next price in micro-dollars: Gaussian step plus a pull back toward the base price (2% per 30 s,
    # compounded so long intervals like hourly ticks still converge instead of overshooting).
    next=$(awk -v c="$cur" -v b="$base" -v s="$vol" -v d="$drift" -v k="$(( INTERVAL * n ))" -v e="$every" -v seed="$RANDOM$tick" 'BEGIN{
      # Scale to the tick length so the walk has the same volatility at any PRICE_INTERVAL.
      srand(seed); k=k/(30*e); s=s*sqrt(k); d=d*k; p=c/1e18; z=sqrt(-2*log(1-rand()))*cos(6.283185307*rand());
      p=p*(1+d+s*z) + (1-exp(-0.02*k))*(b-p); printf "%d", p*1e6 }')
    # --async with a locally tracked nonce, so a tick doesn't wait on receipts.
    if cast send "$VENUE" "setPrice(address,uint256)" "$addr" "${next}000000000000" --async --nonce "$nonce" \
         --private-key "$PRICE_FEED_KEY" --rpc-url "$RPC" --gas-limit 48000 >/dev/null 2>&1; then
      nonce=$((nonce + 1))
      printf '%s  %-6s $%s\n' "$(date +%T)" "$sym" "$(awk -v m="$next" 'BEGIN{printf "%.2f", m/1e6}')"
    else
      echo "$(date +%T)  $sym: setPrice failed" >&2
      nonce=$(cast nonce "$ME" --rpc-url "$RPC")
    fi
  done
  tick=$((tick + 1))
  sleep $(( INTERVAL - ($(date +%s) - start) > 0 ? INTERVAL - ($(date +%s) - start) : 0 ))
done
