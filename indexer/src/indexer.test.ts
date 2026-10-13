import { describe, it } from "vitest";
import { createTestIndexer } from "envio";
import { readFileSync } from "node:fs";
import { encodeAbiParameters, keccak256, type Hex } from "viem";

// Simulated events must match the indexed contract and start block in config.yaml.
const config = readFileSync(new URL("../config.yaml", import.meta.url), "utf8");
const VAULT = config.match(/'(0x[0-9a-fA-F]{40})'/)![1] as `0x${string}`;
const B = Number(config.match(/start_block: (\d+)/)![1]);
const CHAIN = 10143;
const SALT = `0x${"ab".repeat(32)}` as Hex;
const weights = [1000n, 4000n, 2000n, 3000n];
// Trades the vault sized at execution (not part of the commitment).
const trades: [bigint, bigint, bigint, bigint][] = [
  [2n, 0n, 20n * 10n ** 18n, 0n],
  [0n, 1n, 150_000n * 10n ** 6n, 0n],
];

function commitmentFor(epoch: bigint, salt: Hex) {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint16[]" }, { type: "bytes32" },
      ],
      [BigInt(CHAIN), VAULT, epoch, weights.map(Number), salt],
    ),
  );
}

const SEED = `0x${"5e".repeat(32)}` as Hex;
// windowStart 1_100, windowEnd 1_280 → the second keccak256(salt, seed) implies.
const sealedAt = (salt: Hex) =>
  1_100n + (BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [salt, SEED]))) % 181n);

function lifecycle(revealSalt: Hex, executedOffset = 0) {
  const commitment = commitmentFor(1n, SALT);
  const at = sealedAt(revealSalt);
  const ts = Number(at) + executedOffset;
  return [
    {
      contract: "WhisprrVault" as const, event: "FrameworkPublished" as const, block: { number: B + 100 },
      params: {
        frameworkHash: `0x${"11".repeat(32)}`, constituents: [VAULT, VAULT, VAULT, VAULT],
        jitterBefore: 60n, jitterAfter: 120n, executionTolerance: 60n, weightToleranceBps: 50n,
      },
    },
    {
      contract: "WhisprrVault" as const, event: "SchedulePublished" as const, block: { number: B + 100 },
      params: { scheduleStart: 1_160n, rebalancePeriod: 300n, commitLead: 60n },
    },
    {
      contract: "WhisprrVault" as const, event: "Committed" as const,
      block: { number: B + 110, timestamp: 1_000 }, transaction: { hash: "0xc0" },
      params: { epoch: 1n, commitment, windowStart: 1_100n, windowEnd: 1_280n, seedBlock: 115n },
    },
    {
      contract: "WhisprrVault" as const, event: "SeedRecorded" as const,
      block: { number: B + 116, timestamp: 1_002 }, transaction: { hash: "0xd0" },
      params: { epoch: 1n, seedBlock: 115n, seedHash: SEED },
    },
    ...trades.map((t) => ({
      contract: "WhisprrVault" as const, event: "TradeExecuted" as const,
      block: { number: B + 200, timestamp: ts }, transaction: { hash: "0xe0" },
      params: { epoch: 1n, tokenIn: VAULT, tokenOut: VAULT, amountIn: t[2], amountOut: 1n },
    })),
    {
      contract: "WhisprrVault" as const, event: "Executed" as const,
      block: { number: B + 200, timestamp: ts }, transaction: { hash: "0xe0" },
      params: { epoch: 1n, commitment, weights, salt: revealSalt, executeAt: at },
    },
  ];
}

describe("WhisprrVault indexing", () => {
  it("follows an epoch from commit to a verified reveal", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { [CHAIN]: { simulate: lifecycle(SALT) } } });

    const e = await indexer.Epoch.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}-1`);
    const at = sealedAt(SALT);
    t.expect(e.status).toBe("Executed");
    const vault = await indexer.Vault.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}`);
    t.expect(vault.rebalancePeriod).toBe(300n);
    t.expect(e.nominalTime).toBe(1_160n); // windowStart + jitterBefore
    t.expect(e.seedHash).toBe(SEED);
    t.expect(e.executeAt).toBe(at);
    t.expect(e.offsetFromNominal).toBe(at - 1_160n);
    t.expect(e.tradeCount).toBe(2);
    t.expect(e.weights).toEqual([1000, 4000, 2000, 3000]);
    t.expect(e.sealedSeconds).toBe(at - 1_000n);
    t.expect(e.verified).toBe(true);
    t.expect(e.onSchedule).toBe(true);
    t.expect(e.commitTx).toBe("0xc0");

    const v = await indexer.Vault.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}`);
    t.expect([v.epochCount, v.executedCount, v.verifiedCount, v.onScheduleCount]).toEqual([1, 1, 1, 1]);
  });

  it("flags an execution that missed its sealed second", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { [CHAIN]: { simulate: lifecycle(SALT, 61) } } });
    const e = await indexer.Epoch.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}-1`);
    t.expect(e.verified).toBe(true);
    t.expect(e.onSchedule).toBe(false);
  });

  it("flags a reveal that doesn't hash to the commitment", async (t) => {
    const indexer = createTestIndexer();
    await indexer.process({ chains: { [CHAIN]: { simulate: lifecycle(`0x${"cd".repeat(32)}`) } } });
    const e = await indexer.Epoch.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}-1`);
    t.expect(e.verified).toBe(false);
    const v = await indexer.Vault.getOrThrow(`${CHAIN}-${VAULT.toLowerCase()}`);
    t.expect(v.verifiedCount).toBe(0);
  });
});
