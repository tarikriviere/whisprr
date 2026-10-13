# Whisprr

**An onchain index whose rebalances can't be front-run.** Monad Metropolis Hackathon, Track 01: Onchain Finance & Trading.

The rules are public. The weights, and the exact second the rebalance executes, stay sealed until it happens, and that second is fixed by data nobody controls. Nobody can trade ahead of a rebalance they can't see, and nobody, operator included, gets to pick when it runs.

## The problem: index funds pay to be predictable

An index publishes its reconstitution rules and rebalances on a known date. Everyone knows what it must buy and sell, and when, so the market positions ahead of it:

- **Dimensional** finds that index additions rise ~9 bps between the reconstitution announcement and the close as the index is forced to buy, then reverse ~13 bps afterwards. That round trip is paid by the index.
- **Arnott et al. (via Alpha Architect)** estimate that trading ahead of index funds, or delaying reconstitution by 3–12 months, can add up to **23 bps a year**. Discretionary deletions beat additions by 22% on average in the year after changes.
- **Greenwood, "The Disappearing Index Effect" (Harvard)** shows the effect has shrunk as markets adapted. Whisprr doesn't depend on it staying large: it removes the predictability that creates it.

## The fix: seal the specifics, randomize the timing, take execution out of the operator's hands

Whisprr keeps **the framework public** and **the actionable detail sealed**:

| Public from day one ([`docs/FRAMEWORK.md`](docs/FRAMEWORK.md), hash stored onchain) | Sealed until the moment of execution |
|---|---|
| The universe of constituents, the methodology class, **the rebalance schedule** (every nominal date), the execution window around each one, the timing formula, the executor (Chainlink), the tolerances, the operator | The target weights (and with them every trade), the salt, and with it the exact execution second |

Each rebalance goes through four steps:

1. **Commit (operator).** Nominal dates are fixed at deployment (`scheduleStart + k × rebalancePeriod`; on testnet, every 5 minutes on the clock's 5-minute marks). The operator posts `keccak256(abi.encode(chainid, vault, epoch, weights, salt))`, which seals the **next scheduled** rebalance; it must land at least `commitLead` before that date's public window `[nominal − jitterBefore, nominal + jitterAfter]` opens. A date without a commitment passes, publicly. The plan includes a random **salt**. The operator hands the sealed plan to the Chainlink CRE keeper workflow as a secret; it never touches the chain. **The operator's role ends here.**
2. **Seed (Monad).** Five blocks later, that block's hash is recorded onchain (by the keeper, or by anyone). From that moment the execution second is fixed:

   `executeAt = windowStart + keccak256(salt, seedHash) mod (window length + 1)`

   The salt was locked inside the commitment before the block existed, and nobody knew the block hash at commit time, so nobody chose the second. Without the salt, nobody can compute it: the market sees only the window.
3. **Execute (Chainlink only).** When the second arrives, the keeper delivers an `EXECUTE` report through the Chainlink forwarder. In **one transaction** the vault checks the plan against the commitment, recomputes `executeAt` from the revealed salt and requires `executeAt ≤ now ≤ executeAt + tolerance`, then **sizes the trades itself from the prices at that second** (sell overweight constituents into cash, buy underweight ones), executes them against tokenized RWA constituents, and checks the resulting weights. Only the weights are committed, so the vault lands on target however far prices moved inside the window. The market learns the time, the weights and the trades in the same transaction. The operator has **no function to execute with**.
4. **Verify, or default.** Anyone can recompute both the hash and the execution second from the `Executed` event; the frontend and the Envio indexer both do so independently. If nothing executes by the end of the window plus the tolerance, anyone can flag the rebalance as defaulted onchain.

| Who | Can | Can't |
|---|---|---|
| Operator | Choose the target weights, and whether to rebalance on a scheduled date | Choose the date or the execution second, execute, delay, or execute late |
| Chainlink keeper | Execute the committed plan at the sealed second | Execute a different plan (hash check) or at a different second (vault recomputes it) |
| Market | See the window and the commitment | Learn the second, the weights or the trades before they happen |

There's no ZK here. A hash commitment is the right primitive: the plan only needs to stay secret until it executes, not forever. One primitive covers every use: the public framework is committed by hash at deployment, each rebalance by hash before it executes, and the execution second is derived from what that hash locks in.

### The jitter isn't a cost

Randomizing the date means filling at a slightly different price than the nominal date would have given. That difference is **zero-mean noise**: as likely to help as to hurt. Front-running drag is **one-directional**: research on index rebalances (Dimensional; Arnott et al.) puts it at roughly 20 bps per traded dollar, around 23 bps a year for a cap-weighted index, lost on every rebalance. Whisprr trades a predictable leak for noise that averages out.

## Live on Monad testnet

| Contract | Address |
|---|---|
| `WhisprrVault` | [`0xb7630C8991389877a3AC42bd24D8637D4F59d62E`](https://testnet.monadexplorer.com/address/0xb7630C8991389877a3AC42bd24D8637D4F59d62E) (rebalances every 5 min) |
| `OracleVenue` | [`0xb8E8C1C7B0431b6D69Dd20444E763ab1B1D1F051`](https://testnet.monadexplorer.com/address/0xb8E8C1C7B0431b6D69Dd20444E763ab1B1D1F051) |
| mUSDC · mTBILL · mXAU · mSPY | [`0x5028…0dc5`](https://testnet.monadexplorer.com/address/0x502822f4238e792330Da841c192E194629B80dc5) · [`0x1B71…e608`](https://testnet.monadexplorer.com/address/0x1B71434Ae7e942568461D84eC6Ab065CE75ee608) · [`0x1A10…0F24`](https://testnet.monadexplorer.com/address/0x1A1093E67796c63745b447b8B138cBfB46BC0F24) · [`0xdF20…1989`](https://testnet.monadexplorer.com/address/0xdF2010a3c071236D50904AbD0c9a8DEA7b181989) |
| Chainlink forwarder (Monad testnet, simulation) | [`0xB9F79d863261869B234c481D1f9A7af84AeAd192`](https://testnet.monadexplorer.com/address/0xB9F79d863261869B234c481D1f9A7af84AeAd192) |

On the previous vault ([`0x5a4F…fa57`](https://testnet.monadexplorer.com/address/0x5a4F4A97fDB6Aeb5f86ffEA11C1502EAD736fa57)), identical except that the operator picked each nominal date, **rebalance #1** was executed by the Chainlink keeper (25/25/25/25 → 10/40/20/30) while the price feed moved the market: mSPY $502.09 → $506.08 and mXAU $2,481.28 → $2,467.86 between commit and execution. The vault sized the trades at the execution second and landed on **10.00 / 39.99 / 20.00 / 29.99%**.

| Step | Who | Transaction |
|---|---|---|
| 1. Commit: only the hash of the weights and salt goes onchain | Operator | [`0x9df4b9b2…475c7d05`](https://testnet.monadexplorer.com/tx/0x9df4b9b26e2aa016c3c4a0e9ce8381b199b68097da12c2cc4dcfea76475c7d05) |
| 2. Seed: Monad block hash recorded; the second is now fixed but sealed | Chainlink keeper | [`0x9a84be34…07c70590`](https://testnet.monadexplorer.com/tx/0x9a84be340105b347623373862f675150743266963c2715f07c8c1e0407c70590) |
| 3. Reveal, size the trades at current prices and execute at the sealed second (+6 s) | Chainlink keeper | [`0x99b9041a…50e2a1e1`](https://testnet.monadexplorer.com/tx/0x99b9041a3621ebf2371b2d26b5eec33b8a09c805ec4e0b61710bd19850e2a1e1) |

The first vault ([`0x1CD0…d08C`](https://testnet.monadexplorer.com/address/0x1CD04ce821C851Af7f28284E1f5FDBac9645d08C)) committed the trade list itself; it ran three rebalances, including one the keeper refused to execute late, publicly flagged **Defaulted**. It was replaced because fixed trades miss their targets once prices move.

The deployment transactions are recorded in [`broadcast/Deploy.s.sol/10143/`](broadcast/Deploy.s.sol/10143). An earlier deployment ([`0x4Ad9…ab2A`](https://testnet.monadexplorer.com/address/0x4Ad9eE918aAAff5c00267af74A0590F5ED40ab2A)) used a previous design in which a Chainlink-drawn time was public after the draw and the operator submitted the execution; it was replaced so that neither the time nor the execution is in anyone's hands.

## Why it has to be fully onchain

A commit-reveal works even for an offchain index, but then it only proves *honesty of intent*. The buying and selling still happens where no one can see it. Whisprr's moat is that the whole mechanism runs onchain:

- the vault **holds** the constituents;
- the rebalance **executes** as chain-enforced transactions against them;
- the reveal is checked **in the same transaction** against the commitment and the resulting weights.

So the chain doesn't just record what the operator said it would do. It proves that exactly the committed rebalance happened, at a second fixed before anyone could know it, executed by someone other than the operator.

## Why Monad

Commit, seed, and execute are separate transactions, each racing the market. Monad's ~400 ms blocks and fast finality keep the window between commitment and execution tight and cheap, which makes the mechanism practical rather than theoretical. A jitter window measured in seconds or minutes on testnet maps to hours or days for a real reconstitution, without the chain becoming the bottleneck.

## Architecture

```mermaid
flowchart LR
    subgraph Operator
      UI[Frontend<br/>Dynamic wallet]
    end
    subgraph Chainlink CRE
      K[whisprr-keeper workflow<br/>holds the sealed plan as a secret]
    end
    subgraph Monad testnet
      V[WhisprrVault<br/>holds mUSDC · mTBILL · mXAU · mSPY]
      X[OracleVenue<br/>RWA market stand-in]
      F[Chainlink forwarder]
    end
    ENV[Envio HyperIndex<br/>Vault · Epoch · Trade]

    UI -- "1 commit(hash)" --> V
    UI -. "sealed plan (secret, offchain)" .-> K
    K -- "reads state over RPC" --> V
    K -- "2 report: record seed" --> F
    K -- "3 report: execute(plan) at the sealed second" --> F
    F --> V
    V -- "swaps" --> X
    V -- "events" --> ENV
    ENV -- "4 re-hash & re-time" --> ENV
```

| Component | Path | Role |
|---|---|---|
| `WhisprrVault` | [`src/WhisprrVault.sol`](src/WhisprrVault.sol) | Holds constituents; commit → seed → reveal + execute at the sealed second, only via Chainlink; default flagging |
| `OracleVenue`, `MockRWA` | [`src/mocks/`](src/mocks) | Testnet RWA market and tokens (mUSDC cash, mTBILL, mXAU, mSPY) |
| Keeper workflow | [`cre/`](cre) | Every 30 s: record the seed when due; compute the sealed second from the secret plan; execute at it |
| Indexer | [`indexer/`](indexer) | Envio HyperIndex: one `Epoch` per rebalance with seed, sealed second, offset from nominal, reveal, trades, and independent `verified` (hash) and `onSchedule` (timing) checks |
| Frontend | [`frontend/`](frontend) | Vite + React + Dynamic: live vault, window timeline, operator console (commit only), in-browser verification of hash and timing |

### Sponsor integrations

- **Chainlink CRE.** The `whisprr-keeper` TypeScript workflow is the **only executor** of a committed rebalance. It holds the sealed plan as a workflow secret, records the Monad seed, computes the sealed second, and delivers the execution through the forwarder at that second. The vault accepts reports only from the forwarder, for the current epoch, and only inside `[executeAt, executeAt + tolerance]`.
- **Envio.** HyperIndex turns raw events into the rebalance history the product is about: how long each rebalance stayed sealed, where its second landed relative to nominal, and two checks it computes itself rather than trusting the contract: the reveal re-hashes to the commitment, and execution landed at the second `keccak256(salt, seed)` implies.
- **Dynamic.** Sign-in with embedded or external wallets, used for more than login. The connected wallet's role decides what you can do: the operator gets the sealing console (commit only, no execute button), anyone signed in can record the seed or flag a default, and everyone can verify.

## Run it

```bash
# contracts
forge build && forge test            # 31 tests

# deploy to Monad testnet (vault, venue, four RWAs, $1m seeded 25/25/25/25)
cp .env.example .env                  # PRIVATE_KEY with testnet MON
source .env
forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast
# or a new vault against the existing tokens and venue
forge script script/Deploy.s.sol --sig "vaultOnly()" --rpc-url $MONAD_TESTNET_RPC --broadcast
```

Deploying writes `deployments/10143.json` and points the keeper workflow's config at the new vault. Then:

| What | Where |
|---|---|
| Keeper workflow | [`cre/README.md`](cre/README.md): `cre login`, then `WATCH_DIR=<browser downloads> cre/keeper.sh` |
| Indexer | [`indexer/README.md`](indexer/README.md): `pnpm sync && pnpm dev` |
| Price feed | Move the venue to `PRICE_FEED_KEY` in `.env` (`cast send <venue> "transferOwnership(address)" <its address>`), then `script/price-feed.sh` |
| Frontend | `cd frontend && cp .env.example .env` (set `VITE_DYNAMIC_ENV_ID`) `&& npm install && npm run dev`, open `http://localhost:5173`. In the Dynamic dashboard, enable **Monad Testnet** under Chains & Networks → EVM, or sign-in fails |

A rebalance can also be committed from the command line:

```bash
forge script script/Rebalance.s.sol --sig "commit()" --rpc-url $MONAD_TESTNET_RPC --broadcast   # seal target weights
node cre/whisprr-keeper/scripts/hand-over.mjs sealed/<vault>-<epoch>.hex                         # plan → keeper secret
cre/keeper.sh                                                                                    # seed, then execute at the sealed second
```

`commit()` keeps the sealed plan in `sealed/` (gitignored) and broadcasts only the hash. Target weights default to `1000,4000,2000,3000` bps; override them with `WEIGHTS=...`.

## Limitations

- **The keeper runs in simulation on testnet.** Deploying a workflow to Chainlink's network needs deploy access we don't have yet, so `cre/keeper.sh` triggers the workflow every 15 s from a local machine instead of Chainlink's own schedule, and reports go through Monad testnet's *simulation* forwarder, which doesn't verify DON signatures. Even so, a forged report would still need the sealed plan, and would still only execute at the sealed second. Production: a deployed workflow, the **KeystoneForwarder** (`CHAINLINK_FORWARDER=0xF8344CFd5c43616a4366C34E3EEE75af79a74482`), and a check of the report's workflow ID in `onReport`.
- **The operator knows the salt**, so once the seed is recorded it could compute the second. It still can't change it, execute, or delay it. Removing that knowledge is on the roadmap.
- **Seed re-arm.** If nobody records the seed within 256 blocks (~100 s), it re-arms to a fresh block. With the keeper running, the seed is recorded within one polling interval.
- **Prices** come from an owner-set venue standing in for an RWA market. On testnet, `script/price-feed.sh` moves them with a mean-reverting random walk (mSPY and mXAU every 30 s, a slow accrual for mTBILL, mUSDC at $1), signed by a dedicated price-feed key that owns the venue. Pyth feeds would mark constituents to market.
- **Trades are sized from spot prices at the execution second.** Real indices freeze share multipliers at a fixing before the rebalance; sizing at execution is the onchain approximation. The weight tolerance now only guards against venue slippage; with a real venue, per-trade `minAmountOut` from an oracle would tighten it.

## Roadmap

- **Keep the second from the operator too.** Generate the salt inside a secure enclave (e.g. a Chainlink CRE confidential workflow), with an attestation of the code it runs, or as an MPC combination of shares from several parties. Then nobody can compute the second before execution, operator included.
- **Tranches.** Split each rebalance into several pieces executed at several sealed seconds across the window, using confidential transactions (e.g. Unlink) so an executed piece doesn't reveal the ones still to come.
- **Production Chainlink path.** Deployed workflow on the DON's schedule, KeystoneForwarder, workflow-ID check.
- **Pyth prices** for the venue.

## AI tools disclosure

This project was built with AI coding assistance, as required by the hackathon rules:

- **Claude Code** (Anthropic CLI agent, model: Claude Opus 5.5): scaffolding, Solidity contracts, tests, deploy scripts, the Chainlink CRE workflow, the Envio indexer, the React/Dynamic frontend and documentation, under the author's direction and review.
- **Claude** (claude.ai): design discussion and the build plan.

All code was written during the hackathon window.
