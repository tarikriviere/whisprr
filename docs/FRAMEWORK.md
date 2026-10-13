# Whisprr Index: Public Framework v1

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
- **Timing.** Each rebalance executes at one second inside the public window
  `[nominal - jitterBefore, nominal + jitterAfter]`:
  `executeAt = windowStart + keccak256(salt, seedHash) mod (window length + 1)`, where `salt` is
  sealed in the commitment and `seedHash` is the hash of a Monad block mined after the commit.
  Neither input can be chosen once the other is known, so nobody picks the second, and nobody
  without the salt can compute it before execution.
- **Execution.** Only the Chainlink CRE workflow executes, through the Chainlink forwarder. The
  operator has no way to execute, delay or skip a committed rebalance. Execution is valid only
  from `executeAt` to `executeAt + executionTolerance`.
- **Honesty check.** At execution, the vault checks the revealed preimage against the commitment,
  recomputes `executeAt` from the revealed salt, and checks that post-trade weights are within
  `weightToleranceBps` of the committed targets. A rebalance not executed by the end of its window
  plus the tolerance can be publicly flagged as defaulted.

## What's sealed until execution

- The target weights.
- The trade list (sizes and direction).
- The salt, and with it the exact execution second.

The commitment is `keccak256(abi.encode(chainid, vault, epoch, weights, trades, salt))`.
