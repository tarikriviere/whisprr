# whisprr-indexer (Envio HyperIndex)

Indexes WhisprrVault on Monad testnet via HyperSync and serves it over GraphQL.

| Entity | What it holds |
|---|---|
| `Vault` | Public framework (constituents, window, tolerances) and running totals: epochs, executions, defaults, verified reveals, executions at the sealed second |
| `Epoch` | One row per sealed rebalance: commitment and tx, window, Monad seed, **sealed second and its offset from the anchor (scheduled time)**, reveal (weights, salt), the trades the vault sized at execution, how long it stayed sealed, `verified` and `onSchedule` |
| `Trade` | Every trade executed in a rebalance |

Both checks are computed by the indexer itself, independently of the contract: `verified` re-hashes
the revealed preimage (`keccak256(abi.encode(chainid, vault, epoch, weights, salt))`) and
compares it with the commitment; `onSchedule` recomputes the sealed second
(`windowStart + keccak256(salt, seedHash) mod (window + 1)`) and checks execution landed within the
tolerance after it.

## Run

Requires Node ≥ 22.15, pnpm and Docker.

```bash
cp .env.example .env     # ENVIO_API_TOKEN from https://envio.dev/app/api-tokens
pnpm install
pnpm sync                # after deploying: sets the vault address + start block from ../deployments
pnpm dev                 # Hasura GraphQL at http://localhost:8080/v1/graphql
pnpm test                # lifecycle, missed-second and tampered-reveal tests
```

Example query:

```graphql
{
  Vault { epochCount executedCount verifiedCount onScheduleCount defaultedCount }
  Epoch(order_by: { epoch: desc }) { epoch status seedHash executeAt offsetFromNominal sealedSeconds verified onSchedule executeTx }
}
```
