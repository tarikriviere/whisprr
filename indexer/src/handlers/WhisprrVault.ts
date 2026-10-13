// Turns WhisprrVault events into one Epoch row per sealed rebalance, from commit to reveal,
// and independently re-verifies every reveal: its hash against the commitment, and its execution
// second against the one keccak256(salt, seed) implies.
import { indexer, type Epoch, type Vault } from "envio";
import { encodeAbiParameters, getAddress, keccak256, type Hex } from "viem";

const vaultId = (chainId: number, address: string) => `${chainId}-${address.toLowerCase()}`;
const epochId = (chainId: number, address: string, epoch: bigint) => `${vaultId(chainId, address)}-${epoch}`;

async function bumpVault(context: any, id: string, patch: (v: Vault) => Partial<Vault>) {
  const v: Vault | undefined = await context.Vault.get(id);
  if (v) context.Vault.set({ ...v, ...patch(v) });
}

async function updateEpoch(context: any, id: string, patch: (e: Epoch) => Partial<Epoch>) {
  const e: Epoch | undefined = await context.Epoch.get(id);
  if (!e) {
    context.log.warn(`Epoch ${id} not indexed yet; is start_block before the vault's deployment?`);
    return undefined;
  }
  const next = { ...e, ...patch(e) };
  context.Epoch.set(next);
  return next;
}

indexer.onEvent({ contract: "WhisprrVault", event: "FrameworkPublished" }, async ({ event, context }) => {
  const p = event.params;
  context.Vault.set({
    id: vaultId(event.chainId, event.srcAddress),
    address: event.srcAddress,
    frameworkHash: p.frameworkHash,
    constituents: [...p.constituents],
    jitterBefore: p.jitterBefore,
    jitterAfter: p.jitterAfter,
    executionTolerance: p.executionTolerance,
    weightToleranceBps: Number(p.weightToleranceBps),
    epochCount: 0,
    executedCount: 0,
    defaultedCount: 0,
    verifiedCount: 0,
    onScheduleCount: 0,
  });
});

indexer.onEvent({ contract: "WhisprrVault", event: "Committed" }, async ({ event, context }) => {
  const p = event.params;
  const vid = vaultId(event.chainId, event.srcAddress);
  const vault: Vault | undefined = await context.Vault.get(vid);
  context.Epoch.set({
    id: epochId(event.chainId, event.srcAddress, p.epoch),
    vault_id: vid,
    epoch: p.epoch,
    status: "Committed",
    commitment: p.commitment,
    committedAt: BigInt(event.block.timestamp),
    commitTx: event.transaction.hash,
    windowStart: p.windowStart,
    windowEnd: p.windowEnd,
    nominalTime: p.windowStart + (vault?.jitterBefore ?? 0n),
    seedBlock: p.seedBlock,
    rearms: 0,
    seedHash: undefined,
    seedTx: undefined,
    executeAt: undefined,
    offsetFromNominal: undefined,
    executedAt: undefined,
    executeTx: undefined,
    weights: undefined,
    salt: undefined,
    tradeCount: 0,
    revealHash: undefined,
    verified: undefined,
    onSchedule: undefined,
    sealedSeconds: undefined,
  });
  await bumpVault(context, vid, (v) => ({ epochCount: v.epochCount + 1 }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "SeedRearmed" }, async ({ event, context }) => {
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, event.params.epoch), (e) => ({
    seedBlock: event.params.newSeedBlock,
    rearms: e.rearms + 1,
  }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "SeedRecorded" }, async ({ event, context }) => {
  const p = event.params;
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, p.epoch), () => ({
    status: "Seeded",
    seedBlock: p.seedBlock,
    seedHash: p.seedHash,
    seedTx: event.transaction.hash,
  }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "TradeExecuted" }, async ({ event, context }) => {
  const p = event.params;
  const eid = epochId(event.chainId, event.srcAddress, p.epoch);
  const e = await updateEpoch(context, eid, (e) => ({ tradeCount: e.tradeCount + 1 }));
  context.Trade.set({
    id: `${eid}-${event.logIndex}`,
    epochRef_id: eid,
    index: (e?.tradeCount ?? 1) - 1,
    tokenIn: p.tokenIn,
    tokenOut: p.tokenOut,
    amountIn: p.amountIn,
    amountOut: p.amountOut,
    tx: event.transaction.hash,
    timestamp: BigInt(event.block.timestamp),
  });
});

const tradeTuple = {
  type: "tuple[]",
  components: [
    { name: "tokenIn", type: "uint8" },
    { name: "tokenOut", type: "uint8" },
    { name: "amountIn", type: "uint256" },
    { name: "minAmountOut", type: "uint256" },
  ],
} as const;

indexer.onEvent({ contract: "WhisprrVault", event: "Executed" }, async ({ event, context }) => {
  const p = event.params;
  const weights = p.weights.map((w) => Number(w));
  const trades = p.trades.map((t) => ({ tokenIn: Number(t[0]), tokenOut: Number(t[1]), amountIn: t[2], minAmountOut: t[3] }));
  // Same encoding as WhisprrVault.hashRebalance: verify the reveal without trusting the contract.
  const revealHash = keccak256(
    encodeAbiParameters(
      [{ type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint16[]" }, tradeTuple, { type: "bytes32" }],
      [BigInt(event.chainId), getAddress(event.srcAddress), p.epoch, weights, trades, p.salt as Hex],
    ),
  );
  const verified = revealHash.toLowerCase() === p.commitment.toLowerCase();
  const executedAt = BigInt(event.block.timestamp);
  const vid = vaultId(event.chainId, event.srcAddress);
  const vault: Vault | undefined = await context.Vault.get(vid);

  const e = await updateEpoch(context, epochId(event.chainId, event.srcAddress, p.epoch), (e) => {
    // Same formula as WhisprrVault.executionTime: the second the salt and the seed imply.
    let onSchedule: boolean | undefined;
    if (e.seedHash) {
      const span = e.windowEnd - e.windowStart + 1n;
      const sealedAt =
        e.windowStart +
        (BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [p.salt as Hex, e.seedHash as Hex]))) % span);
      onSchedule = sealedAt === p.executeAt && executedAt >= sealedAt && executedAt <= sealedAt + (vault?.executionTolerance ?? 0n);
    }
    return {
      status: "Executed",
      executeAt: p.executeAt,
      offsetFromNominal: p.executeAt - e.nominalTime,
      executedAt,
      executeTx: event.transaction.hash,
      weights,
      salt: p.salt,
      revealHash,
      verified,
      onSchedule,
      sealedSeconds: executedAt - e.committedAt,
    };
  });
  await bumpVault(context, vid, (v) => ({
    executedCount: v.executedCount + 1,
    verifiedCount: v.verifiedCount + (verified ? 1 : 0),
    onScheduleCount: v.onScheduleCount + (e?.onSchedule ? 1 : 0),
  }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "Defaulted" }, async ({ event, context }) => {
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, event.params.epoch), () => ({ status: "Defaulted" }));
  await bumpVault(context, vaultId(event.chainId, event.srcAddress), (v) => ({ defaultedCount: v.defaultedCount + 1 }));
});
