// Client-side mirror of the vault's commitment scheme and its trade sizing.
import { encodeAbiParameters, keccak256, toHex, type Address, type Hex } from "viem";

export const BPS = 10_000n;
export const CASH = 0;
export const STATUS = ["None", "Committed", "Seeded", "Executed", "Defaulted"] as const;
export type Status = (typeof STATUS)[number];

export type Trade = { tokenIn: number; tokenOut: number; amountIn: bigint; minAmountOut: bigint };

export type Constituent = {
  address: Address;
  symbol: string;
  decimals: number;
  price: bigint; // USD per whole token, 1e18
  balance: bigint;
  value: bigint; // USD, 1e18
};

export type Epoch = {
  id: bigint;
  commitment: Hex;
  seedHash: Hex; // 0x0… until recorded
  committedBlock: bigint;
  seedBlock: bigint;
  windowStart: bigint;
  windowEnd: bigint;
  executeAt: bigint; // 0 until revealed at execution
  executedAt: bigint;
  executedBlock: bigint;
  status: Status;
  lastExecution: bigint; // windowEnd + tolerance: after this anyone can flag a default
};

export type Sealed = { chainId: number; vault: Address; epoch: bigint; weights: number[]; salt: Hex };

/** keccak256(abi.encode(chainid, vault, epoch, weights, salt)), as WhisprrVault.hashRebalance. */
export function hashRebalance(s: Omit<Sealed, "chainId"> & { chainId: number }): Hex {
  return keccak256(
    encodeAbiParameters(
      [
        { type: "uint256" },
        { type: "address" },
        { type: "uint256" },
        { type: "uint16[]" },
        { type: "bytes32" },
      ],
      [BigInt(s.chainId), s.vault, s.epoch, s.weights, s.salt],
    ),
  );
}

/** executeAt = windowStart + keccak256(salt, seedHash) mod (window + 1), as WhisprrVault.executionTime. */
export function executionTime(salt: Hex, seedHash: Hex, windowStart: bigint, windowEnd: bigint): bigint {
  const seed = BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [salt, seedHash])));
  return windowStart + (seed % (windowEnd - windowStart + 1n));
}

export type Slot = { slot: bigint; nominal: bigint; windowStart: bigint; windowEnd: bigint; commitDeadline: bigint };

/** The next scheduled rebalance a commit made at `now` would seal, as WhisprrVault.nextSlot. */
export function nextSlot(
  v: { scheduleStart: bigint; rebalancePeriod: bigint; commitLead: bigint; jitterBefore: bigint; jitterAfter: bigint },
  now: bigint,
): Slot {
  const earliest = now + v.commitLead + v.jitterBefore;
  const slot = earliest > v.scheduleStart ? (earliest - v.scheduleStart + v.rebalancePeriod - 1n) / v.rebalancePeriod : 0n;
  const nominal = v.scheduleStart + slot * v.rebalancePeriod;
  const windowStart = nominal - v.jitterBefore;
  return { slot, nominal, windowStart, windowEnd: nominal + v.jitterAfter, commitDeadline: windowStart - v.commitLead };
}

/** "2:05" for a number of seconds. */
export const fmtDuration = (s: bigint) => {
  const n = Number(s < 0n ? 0n : s);
  return `${Math.floor(n / 60)}:${String(n % 60).padStart(2, "0")}`;
};

export const ZERO_HASH = `0x${"0".repeat(64)}` as Hex;

export function randomSalt(): Hex {
  return toHex(crypto.getRandomValues(new Uint8Array(32)));
}

/** The trades the vault would size at today's prices (mirrors WhisprrVault._rebalanceTo). A preview only:
 * the vault sizes the real ones at the execution second, from the prices then. */
export function planTrades(cs: Constituent[], weights: number[]): Trade[] {
  const total = cs.reduce((a, c) => a + c.value, 0n);
  const sells: Trade[] = [];
  const buys: Trade[] = [];
  const cash = cs[CASH];
  for (let i = 1; i < cs.length; i++) {
    const target = (total * BigInt(weights[i])) / BPS;
    const c = cs[i];
    if (c.value > target) {
      sells.push({ tokenIn: i, tokenOut: CASH, amountIn: ((c.value - target) * 10n ** BigInt(c.decimals)) / c.price, minAmountOut: 0n });
    } else if (c.value < target) {
      buys.push({ tokenIn: CASH, tokenOut: i, amountIn: ((target - c.value) * 10n ** BigInt(cash.decimals)) / cash.price, minAmountOut: 0n });
    }
  }
  return [...sells, ...buys];
}

// ---- sealed preimage storage (this browser only) ----

const key = (chainId: number, vault: Address, epoch: bigint) => `whisprr:sealed:${chainId}:${vault.toLowerCase()}:${epoch}`;

export function serializeSealed(s: Sealed): string {
  return JSON.stringify(s, (_, v) => (typeof v === "bigint" ? `${v}n` : v), 2);
}

export function parseSealed(json: string): Sealed {
  return JSON.parse(json, (_, v) => (typeof v === "string" && /^\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v));
}

export function saveSealed(s: Sealed) {
  try {
    localStorage.setItem(key(s.chainId, s.vault, s.epoch), serializeSealed(s));
  } catch {
    /* storage unavailable: the downloaded file is the backup */
  }
}

export function loadSealed(chainId: number, vault: Address, epoch: bigint): Sealed | null {
  try {
    const raw = localStorage.getItem(key(chainId, vault, epoch));
    return raw ? parseSealed(raw) : null;
  } catch {
    return null;
  }
}

export function downloadSealed(s: Sealed) {
  const url = URL.createObjectURL(new Blob([serializeSealed(s)], { type: "application/json" }));
  const a = Object.assign(document.createElement("a"), { href: url, download: `whisprr-sealed-epoch-${s.epoch}.json` });
  a.click();
  URL.revokeObjectURL(url);
}

// ---- formatting ----

export const fmtUsd = (v: bigint) =>
  "$" + Number(v / 10n ** 16n / 100n).toLocaleString("en-US", { maximumFractionDigits: 0 });
export const fmtPrice = (v: bigint) =>
  "$" + (Number(v / 10n ** 14n) / 1e4).toLocaleString("en-US", { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const fmtBps = (bps: bigint | number) => (Number(bps) / 100).toFixed(2) + "%";
export const fmtAmount = (v: bigint, decimals: number) =>
  (Number(v) / 10 ** decimals).toLocaleString("en-US", { maximumFractionDigits: 4 });
export const short = (h: string) => `${h.slice(0, 6)}…${h.slice(-4)}`;
export const fmtTime = (t: bigint) => (t === 0n ? "–" : new Date(Number(t) * 1000).toLocaleTimeString());
