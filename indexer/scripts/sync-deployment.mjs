// Points config.yaml at the WhisprrVault in ../deployments/<chain>.json and starts indexing from
// its deployment block (read from Foundry's broadcast receipts).
import { readFileSync, writeFileSync, existsSync } from "node:fs";

const chain = process.argv[2] ?? "10143";
const deployment = JSON.parse(readFileSync(`../deployments/${chain}.json`, "utf8"));
const vault = deployment.vault.toLowerCase();

let startBlock = 0;
// A full deploy (run) or a vault-only redeploy (vaultOnly) may have created the current vault.
for (const name of ["run", "vaultOnly"]) {
  const broadcast = `../broadcast/Deploy.s.sol/${chain}/${name}-latest.json`;
  if (!existsSync(broadcast)) continue;
  const run = JSON.parse(readFileSync(broadcast, "utf8"));
  const receipt = run.receipts.find((r) => r.contractAddress?.toLowerCase() === vault);
  if (receipt) startBlock = Number(BigInt(receipt.blockNumber));
}

let config = readFileSync("config.yaml", "utf8");
config = config
  .replace(/start_block: \d+/, `start_block: ${startBlock}`)
  .replace(/(address:\n\s+- )'0x[0-9a-fA-F]{40}'/, `$1'${deployment.vault}'`);
writeFileSync("config.yaml", config);
console.log(`config.yaml → vault ${deployment.vault}, start_block ${startBlock}`);
