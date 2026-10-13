// Hands a sealed rebalance plan to the keeper workflow as its `sealed_plan` secret.
//
//   node cre/whisprr-keeper/scripts/hand-over.mjs <sealed file>
//
// Accepts the file the frontend downloads at commit (whisprr-sealed-epoch-N.json) or the one
// script/Rebalance.s.sol writes (sealed/<vault>-<epoch>.hex). Writes WHISPRR_SEALED_PLAN into
// cre/.env, which is where `cre workflow simulate` reads secrets from. For a deployed workflow,
// upload the same value with `cre secrets`.
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { encodeAbiParameters } from "viem";

const file = process.argv[2];
if (!file) {
  console.error("usage: node hand-over.mjs <sealed file>");
  process.exit(1);
}
const raw = readFileSync(file, "utf8").trim();

let hex;
if (raw.startsWith("0x")) {
  hex = raw;
} else {
  // Frontend format: bigints serialized as "123n".
  const s = JSON.parse(raw, (_, v) => (typeof v === "string" && /^\d+n$/.test(v) ? BigInt(v.slice(0, -1)) : v));
  hex = encodeAbiParameters(
    [
      { type: "uint256" },
      { type: "uint16[]" },
      { type: "tuple[]", components: [{ type: "uint8" }, { type: "uint8" }, { type: "uint256" }, { type: "uint256" }] },
      { type: "bytes32" },
    ],
    [BigInt(s.epoch), s.weights, s.trades.map((t) => [t.tokenIn, t.tokenOut, BigInt(t.amountIn), BigInt(t.minAmountOut)]), s.salt],
  );
}

const envPath = join(dirname(fileURLToPath(import.meta.url)), "..", "..", ".env");
const lines = existsSync(envPath) ? readFileSync(envPath, "utf8").split("\n").filter((l) => l && !l.startsWith("WHISPRR_SEALED_PLAN=")) : [];
lines.push(`WHISPRR_SEALED_PLAN=${hex}`);
writeFileSync(envPath, lines.join("\n") + "\n", { mode: 0o600 });
console.log(`Sealed plan handed to the keeper workflow (${(hex.length - 2) / 2} bytes in cre/.env). It never goes onchain until execution.`);
