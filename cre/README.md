# whisprr-keeper: Chainlink CRE workflow

Draws each sealed rebalance's execution time from DON-agreed randomness.

Every 30 seconds the workflow calls `WhisprrVault.pendingDraw()`. When an epoch's draw block has
been mined and no time has been drawn yet, it produces a 256-bit random word and writes the
DON-signed report `abi.encode(uint256 epoch, uint256 randomWord)` to `WhisprrVault.onReport`
through the Chainlink forwarder.

The vault:
- accepts the report only from its configured forwarder, only for the current epoch, and only once;
- mixes the word with the draw block's hash and the commitment, so neither the DON's word nor the
  block producer alone decides the time;
- opens the anyone-callable block-hash fallback (`drawExecutionTime`) only `CRE_TIMEOUT_BLOCKS`
  after the draw block, so the operator can't pick whichever source it prefers.

## Run it

```bash
cre login                                   # once
cd cre/whisprr-keeper && bun install && cd ..
cp .env.example .env                        # CRE_ETH_PRIVATE_KEY: funded Monad testnet key, no 0x
# deploying the vault on Monad testnet fills vaultAddress in config.*.json automatically
cre workflow simulate whisprr-keeper -T staging-settings --broadcast
```

`simulate --broadcast` delivers the report through Monad testnet's simulation forwarder
(`0xB9F79d863261869B234c481D1f9A7af84AeAd192`), which is the vault's default `drawForwarder`.
A deployed workflow goes through the production KeystoneForwarder
(`0xF8344CFd5c43616a4366C34E3EEE75af79a74482`), which verifies DON signatures. Deploy the vault
with `DRAW_FORWARDER` set to that address.

> The simulation forwarder doesn't check DON signatures, so on that configuration anyone could
> deliver a word. The block-hash mix limits the damage, but production should use the
> KeystoneForwarder.
