# Whisper Index: Public Framework v1

This document is disclosed in the clear. Its keccak256 hash is stored in the vault at deployment
as `frameworkHash`, so the rules of the game can't change silently.

## What's public

- **Universe.** Four tokenized real-world assets: mUSDC (cash), mTBILL (short-duration
  Treasuries), mXAU (gold), mSPY (US large-cap equity). Constituents are fixed per vault.
- **Methodology class.** Long-only, fully invested, weights in basis points summing to 10,000.
  Each rebalance moves the vault from its current weights to new target weights by trading
  through the cash leg.
- **Rebalance trigger.** At most one open rebalance at a time. Each one is announced as a sealed
  commitment with a nominal date.
- **Timing.** The exact execution time is drawn at random inside
  `[nominal - jitterBefore, nominal + jitterAfter]` from a block hash that doesn't exist at
  commit time.
- **Honesty check.** At execution, the vault checks the revealed preimage against the commitment
  and checks that post-trade weights are within `weightToleranceBps` of the committed targets.
  An operator that misses the grace period after the drawn time can be publicly flagged as
  defaulted.

## What's sealed until execution

- The target weights.
- The trade list (sizes and direction).
- The salt.

The commitment is `keccak256(abi.encode(chainid, vault, epoch, weights, trades, salt))`.
