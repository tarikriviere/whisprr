# whisprr-keeper: Chainlink CRE workflow

The only executor of a committed Whisprr rebalance.

Every 30 seconds the workflow reads the vault's current epoch and does at most one thing:

- **Committed, seed block mined** → delivers a `RECORD_SEED` report: the vault stores the hash of
  the Monad block mined 5 blocks after the commit.
- **Seeded** → reads the sealed plan from its `sealed_plan` secret, checks it against the onchain
  commitment, and computes the sealed second
  `executeAt = windowStart + keccak256(salt, seedHash) mod (window + 1)`. When the chain's clock
  reaches it, delivers an `EXECUTE` report carrying the plan. The vault rechecks the hash and the
  second, and rejects the report a second early or past `executionTolerance`.

The sealed plan reaches the workflow as a secret, never onchain, so nobody without it can compute
the second. The operator has no execute function: once committed, a rebalance runs at its sealed
second or defaults.

## Run it (simulation)

```bash
cre login                                        # once
cd cre/whisprr-keeper && bun install && cd ../..
# cre/.env: CRE_ETH_PRIVATE_KEY=<funded Monad testnet key, no 0x>
# deploying the vault fills vaultAddress in config.*.json automatically

# after committing a rebalance:
node cre/whisprr-keeper/scripts/hand-over.mjs <sealed file>   # → WHISPRR_SEALED_PLAN in cre/.env
cre/keeper.sh                                                  # seed, then execute at the sealed second

# or keep it running and let it pick up plans the browser downloads:
WATCH_DIR="/mnt/c/Users/<you>/Downloads" cre/keeper.sh
```

`keeper.sh` stands in for the DON's cron while the workflow runs in simulation. Reports go through
Monad testnet's simulation forwarder (`0xB9F79d863261869B234c481D1f9A7af84AeAd192`), the vault's
default `chainlinkForwarder`. A deployed workflow runs on Chainlink's schedule and writes through
the KeystoneForwarder (`0xF8344CFd5c43616a4366C34E3EEE75af79a74482`), which verifies DON
signatures; deploy the vault with `CHAINLINK_FORWARDER` set to it, and upload the sealed plan with
`cre secrets`.
