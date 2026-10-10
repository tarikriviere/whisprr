# Whisper

**A sealed-rebalance onchain index for Monad.** Monad Metropolis Hackathon, Track 01: Onchain Finance & Trading.

Index funds publish their reconstitution rules and rebalance at a time everyone knows in advance, so the market trades ahead of them. Whisper keeps the *framework* public but seals the *specifics*:

1. **Commit.** The operator posts `keccak256(epoch, vault, weights, trades, salt)` onchain before the rebalance.
2. **Execute + reveal.** Within a randomized execution window, the operator submits the preimage. The vault checks it against the commitment, executes every committed trade as a real onchain transaction against tokenized RWA constituents, and verifies the resulting portfolio matches the committed target weights. All of this happens atomically in one transaction, so there's no window in which the instructions are public but not yet executed.
3. **Verify.** Anyone can recompute the hash from the revealed preimage and check the `Executed` event and the vault's balances.

There's no ZK here. A hash commitment is the right primitive: the methodology only needs to stay secret until it's executed, not forever.

The public framework (universe, methodology class, timing rules) lives in [`docs/FRAMEWORK.md`](docs/FRAMEWORK.md). Its hash is stored in the vault at deployment.

## Contracts

| Contract | Role |
|---|---|
| `WhisperVault` | Holds the constituents; commit → draw → execute+reveal lifecycle |
| `OracleVenue` | Inventory-backed venue filling swaps at quoted USD prices (testnet stand-in for an RWA market) |
| `MockRWA` | ERC-20 stand-ins: mUSDC (cash), mTBILL, mXAU, mSPY |

## Frontend

`frontend/` is a Vite + React app using **Dynamic** for wallets (email/social embedded wallets or any EVM wallet) and wagmi/viem for chain access. It does more than log users in:

- **Public view**: holdings and live weights, the current epoch's sealed commitment, and the execution window as a timeline showing the nominal date, the randomly drawn time and now.
- **Anyone signed in** can draw the execution time once the draw block is mined, and can flag an operator that misses the grace period as defaulted.
- **Operator console**, shown only when the connected Dynamic wallet is the vault's `operator`: set target weights, preview the trade list, then seal and commit. The salt is generated and the commitment hashed in the browser. The preimage is kept locally and downloaded as a backup, and it's used to reveal and execute when the drawn time arrives.
- **Verify**: every executed epoch's `Executed` event is fetched and re-hashed in the browser, then compared with the commitment that was posted before anyone knew the weights.

```bash
cd frontend
cp .env.example .env   # set VITE_DYNAMIC_ENV_ID
npm install
npm run dev            # needs `forge build` and a deployments/<chainid>.json first
```

Set `VITE_CHAIN=local` to point the app at anvil on `:8545`.

## Known limitations (in progress)

- **Randomness.** The execution time is drawn from a future block hash. If nobody draws within 256 blocks, the draw re-arms to a fresh block, which gives a withholding operator a reroll. Chainlink CRE is planned to replace this.
- **Prices** are set by the venue owner. Pyth feeds are planned.

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

# one rebalance epoch
forge script script/Rebalance.s.sol --sig "commit()"  --rpc-url $MONAD_TESTNET_RPC --broadcast  # seals target weights
forge script script/Rebalance.s.sol --sig "draw()"    --rpc-url $MONAD_TESTNET_RPC --broadcast  # after ~5 blocks
forge script script/Rebalance.s.sol --sig "execute()" --rpc-url $MONAD_TESTNET_RPC --broadcast  # once executeAt passes
```

`commit()` keeps the preimage in `sealed/` (gitignored) and broadcasts only the hash. Target weights default to `1000,4000,2000,3000` bps; override them with `WEIGHTS=...`.

## AI tools disclosure

This project was built with AI coding assistance, as required by the hackathon rules:

- **Claude Code** (Anthropic CLI agent, model: Claude Opus 5.5): scaffolding, Solidity contracts, tests, deploy scripts, the React/Dynamic frontend and documentation, under the author's direction and review.
- **Claude** (claude.ai): design discussion and the build plan.

All code was written during the hackathon window.
