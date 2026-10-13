# whisprr-indexer (Envio HyperIndex)

Indexes WhisprrVault on Monad testnet via HyperSync and serves it over GraphQL.

| Entity | What it holds |
|---|---|
| `Vault` | Public framework (constituents, jitter window, tolerance) and running totals: epochs, executions, defaults, verified reveals, Chainlink vs fallback draws |
| `Epoch` | One row per sealed rebalance: commitment and tx, window, draw source and seed, **offset of the drawn time from nominal**, reveal (weights, salt), trades, how long it stayed sealed, and `verified` |
| `Trade` | Every trade executed in a rebalance |

`verified` is computed by the indexer itself: it re-hashes the revealed preimage
(`keccak256(abi.encode(chainid, vault, epoch, weights, trades, salt))`) and compares it with the
commitment, independently of the contract's own check.

## Run

Requires Node ≥ 22.15, pnpm and Docker.

```bash
cp .env.example .env     # ENVIO_API_TOKEN from https://envio.dev/app/api-tokens
pnpm install
pnpm sync                # after deploying: sets the vault address + start block from ../deployments
pnpm dev                 # Hasura GraphQL at http://localhost:8080/v1/graphql
pnpm test                # lifecycle + tampered-reveal tests
```

Example query:

```graphql
{
  Vault { epochCount executedCount verifiedCount chainlinkDraws fallbackDraws }
  Epoch(order_by: { epoch: desc }) { epoch status drawSource offsetFromNominal sealedSeconds verified executeTx }
}
```
