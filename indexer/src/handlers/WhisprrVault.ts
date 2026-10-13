// Turns WhisprrVault events into one Epoch row per sealed rebalance, from commit to reveal,
// and re-verifies every reveal against its commitment independently of the contract.
import { indexer, type Epoch, type Vault } from "envio";
import { encodeAbiParameters, getAddress, keccak256, type Hex } from "viem";

const DRAW_SOURCE = ["None", "BlockHash", "Chainlink"] as const;

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
    executionGrace: p.executionGrace,
    weightToleranceBps: Number(p.weightToleranceBps),
    epochCount: 0,
    executedCount: 0,
    defaultedCount: 0,
    verifiedCount: 0,
    chainlinkDraws: 0,
    fallbackDraws: 0,
  });
});

indexer.onEvent({ contract: "WhisprrVault", event: "Committed"}, async ({ event, context }) => {
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
    drawBlock: p.drawBlock,
    rearms: 0,
    drawSource: undefined,
    seed: undefined,
    executeAt: undefined,
    offsetFromNominal: undefined,
    drawTx: undefined,
    executedAt: undefined,
    executeTx: undefined,
    weights: undefined,
    salt: undefined,
    tradeCount: 0,
    revealHash: undefined,
    verified: undefined,
    sealedSeconds: undefined,
  });
  await bumpVault(context, vid, (v) => ({ epochCount: v.epochCount + 1 }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "DrawRearmed" }, async ({ event, context }) => {
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, event.params.epoch), (e) => ({
    drawBlock: event.params.newDrawBlock,
    rearms: e.rearms + 1,
  }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "ExecutionTimeDrawn"}, async ({ event, context }) => {
  const p = event.params;
  const source = DRAW_SOURCE[Number(p.source)] ?? "None";
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, p.epoch), (e) => ({
    status: "Drawn",
    drawSource: source,
    seed: p.seed,
    executeAt: p.executeAt,
    offsetFromNominal: p.executeAt - e.nominalTime,
    drawTx: event.transaction.hash,
  }));
  await bumpVault(context, vaultId(event.chainId, event.srcAddress), (v) =>
    source === "Chainlink" ? { chainlinkDraws: v.chainlinkDraws + 1 } : { fallbackDraws: v.fallbackDraws + 1 },
  );
});

indexer.onEvent({ contract: "WhisprrVault", event: "TradeExecuted"}, async ({ event, context }) => {
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

indexer.onEvent({ contract: "WhisprrVault", event: "Executed"}, async ({ event, context }) => {
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
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, p.epoch), (e) => ({
    status: "Executed",
    executedAt,
    executeTx: event.transaction.hash,
    weights,
    salt: p.salt,
    revealHash,
    verified,
    sealedSeconds: executedAt - e.committedAt,
  }));
  await bumpVault(context, vaultId(event.chainId, event.srcAddress), (v) => ({
    executedCount: v.executedCount + 1,
    verifiedCount: v.verifiedCount + (verified ? 1 : 0),
  }));
});

indexer.onEvent({ contract: "WhisprrVault", event: "Defaulted" }, async ({ event, context }) => {
  await updateEpoch(context, epochId(event.chainId, event.srcAddress, event.params.epoch), () => ({ status: "Defaulted" }));
  await bumpVault(context, vaultId(event.chainId, event.srcAddress), (v) => ({ defaultedCount: v.defaultedCount + 1 }));
});
