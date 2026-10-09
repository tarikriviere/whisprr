# Whisper

**A sealed-rebalance onchain index for Monad.** Monad Metropolis Hackathon, Track 01: Onchain Finance & Trading.

Index funds publish their reconstitution rules and rebalance at a time everyone knows in advance, so the market trades ahead of them. Whisper keeps the *framework* public but seals the *specifics*:

1. **Commit.** The operator posts `keccak256(epoch, vault, weights, trades, salt)` onchain before the rebalance.
2. **Execute + reveal.** Within a randomized execution window, the operator submits the preimage. The vault checks it against the commitment, executes every committed trade as a real onchain transaction against tokenized RWA constituents, and verifies the resulting portfolio matches the committed target weights. All of this happens atomically in one transaction, so there's no window in which the instructions are public but not yet executed.
3. **Verify.** Anyone can recompute the hash from the revealed preimage and check the `Executed` event and the vault's balances.

There's no ZK here. A hash commitment is the right primitive: the methodology only needs to stay secret until it's executed, not forever.

> Work in progress: see `docs/` and the commit history for build progress.

## Build

```bash
forge build
forge test -vv
```

## Deploy (Monad testnet)

```bash
cp .env.example .env   # fill PRIVATE_KEY
source .env
forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast
```

## AI tools disclosure

This project was built with AI coding assistance, as required by the hackathon rules:

- **Claude Code** (Anthropic CLI agent, model: Claude Opus 5.5): scaffolding, Solidity contracts, tests, deploy scripts and documentation, under the author's direction and review.
- **Claude** (claude.ai): design discussion and the build plan.

All code was written during the hackathon window.
