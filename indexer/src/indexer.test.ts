import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { encodeAbiParameters, keccak256, type Hex } from "viem";

const VAULT = "0x0000000000000000000000000000000000000001" as const;
const CHAIN = 10143;
const SALT = `0x${"ab".repeat(32)}` as Hex;
const weights = [1000n, 4000n, 2000n, 3000n];
const trades: [bigint, bigint, bigint, bigint][] = [
  [2n, 0n, 20n * 10n ** 18n, 0n],
  [0n, 1n, 150_000n * 10n ** 6n, 0n],
];

function commitmentFor(epoch: bigint, salt: Hex) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint16[]" },
        { type: "tuple[]", components: [{ type: "uint8" }, { type: "uint8" }, { type: "uint256" }, { type: "uint256" }] },
        { type: "bytes32" },
      ],
      [BigInt(CHAIN), VAULT, epoch, weights.map(Number), trades.map((t) => [Number(t[0]), Number(t[1]), t[2], t[3]] as const), salt],
    ),
  );
}

function lifecycle(revealSalt: Hex) {
  const commitment = commitmentFor(1n, SALT);
  return [
    {
      contract: "WhisprrVault" as const, event: "FrameworkPublished" as const, block: { number: 100 },
      params: {
        frameworkHash: `0x${"11".repeat(32)}`, constituents: [VAULT, VAULT, VAULT, VAULT],
        jitterBefore: 60n, jitterAfter: 120n, executionGrace: 600n, weightToleranceBps: 50n,
      },
    },
    {
      contract: "WhisprrVault" as const, event: "Committed" as const,
      block: { number: 110, timestamp: 1_000 }, transaction: { hash: "0xc0" },
      params: { epoch: 1n, commitment, windowStart: 1_100n, windowEnd: 1_280n, drawBlock: 115n },
    },
    {
      contract: "WhisprrVault" as const, event: "ExecutionTimeDrawn" as const,
      block: { number: 116, timestamp: 1_010 }, transaction: { hash: "0xd0" },
      params: { epoch: 1n, executeAt: 1_150n, seed: `0x${"22".repeat(32)}`, source: 2n },
    },
    ...trades.map((t) => ({
      contract: "WhisprrVault" as const, event: "TradeExecuted" as const,
      block: { number: 200, timestamp: 1_150 }, transaction: { hash: "0xe0" },
      params: { epoch: 1n, tokenIn: VAULT, tokenOut: VAULT, amountIn: t[2], amountOut: 1n },
    })),
    {
      contract: "WhisprrVault" as const, event: "Executed" as const,
      block: { number: 200, timestamp: 1_150 }, transaction: { hash: "0xe0" },
      params: { epoch: 1n, commitment, weights, trades, salt: revealSalt },
    },
  ];
}

describe("WhisprrVault indexing", () => {
  it("follows an epoch from commit to a verified reveal", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { [CHAIN]: { simulate: lifecycle(SALT) } } });

    const e = await indexer.Epoch.getOrThrow(`${CHAIN}-${VAULT}-1`);
    t.expect(e.status).toBe("Executed");
    t.expect(e.nominalTime).toBe(1_160n); // windowStart + jitterBefore
    t.expect(e.offsetFromNominal).toBe(-10n);
    t.expect(e.drawSource).toBe("Chainlink");
    t.expect(e.tradeCount).toBe(2);
    t.expect(e.weights).toEqual([1000, 4000, 2000, 3000]);
    t.expect(e.sealedSeconds).toBe(150n);
    t.expect(e.verified).toBe(true);
    t.expect(e.commitTx).toBe("0xc0");

    const v = await indexer.Vault.getOrThrow(`${CHAIN}-${VAULT}`);
    t.expect([v.epochCount, v.executedCount, v.verifiedCount, v.chainlinkDraws]).toEqual([1, 1, 1, 1]);
  });

  it("flags a reveal that doesn't hash to the commitment", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { [CHAIN]: { simulate: lifecycle(`0x${"cd".repeat(32)}`) } } });
    const e = await indexer.Epoch.getOrThrow(`${CHAIN}-${VAULT}-1`);
    t.expect(e.verified).toBe(false);
    const v = await indexer.Vault.getOrThrow(`${CHAIN}-${VAULT}`);
    t.expect(v.verifiedCount).toBe(0);
  });
});
