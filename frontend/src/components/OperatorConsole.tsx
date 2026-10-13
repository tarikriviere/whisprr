import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { useWriteContract } from "wagmi";
import { chain } from "../chain";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import {
  downloadSealed, executionTime, fmtAmount, fmtTime, hashRebalance, loadSealed, parseSealed, planTrades, randomSalt,
  saveSealed, short, type Sealed,
} from "../whisprr";
import { TxLine } from "./TxLine";

export function OperatorConsole({ s, vault }: { s: VaultState; vault: Address }) {
  const e = s.epochs[0];
  const open = e && (e.status === "Committed" || e.status === "Seeded");
  return (
    <section className="card operator">
      <div className="card-head">
        <h2>Operator console</h2>
        <span className="pill pill-operator">operator wallet</span>
      </div>
      {open ? <SealedPanel s={s} vault={vault} /> : <CommitPanel s={s} vault={vault} />}
    </section>
  );
}

function CommitPanel({ s, vault }: { s: VaultState; vault: Address }) {
  const [pcts, setPcts] = useState(() => ["10", "40", "20", "30"].slice(0, s.constituents.length));
  const [delay, setDelay] = useState(() => (s.jitterBefore + 60n).toString());
  const { writeContractAsync } = useWriteContract();
  const tx = useTx();

  const weights = pcts.map((p) => Math.round(Number(p) * 100));
  const sum = weights.reduce((a, b) => a + b, 0);
  const valid = sum === 10_000 && weights.every((w) => Number.isFinite(w) && w >= 0);
  const trades = useMemo(() => (valid ? planTrades(s.constituents, weights) : []), [valid, s.constituents, pcts.join()]);

  async function commit() {
    const sealed: Sealed = {
      chainId: chain.id, vault, epoch: (s.epochs[0]?.id ?? 0n) + 1n, weights, trades, salt: randomSalt(),
    };
    const commitment = hashRebalance(sealed);
    // Keep the preimage before anything is broadcast: without it the epoch can't be executed.
    saveSealed(sealed);
    downloadSealed(sealed);
    await tx.run(() =>
      writeContractAsync({ address: vault, abi: vaultAbi, functionName: "commit", args: [commitment, s.now + BigInt(delay)] }),
    );
  }

  return (
    <>
      <p className="muted">
        Set the target weights. Only their hash goes onchain. The preimage stays in this browser and in a downloaded file
        until execution.
      </p>
      <div className="weights-grid">
        {s.constituents.map((c, i) => (
          <label key={c.address}>
            <span><span className={`dot dot-${i}`} />{c.symbol}</span>
            <input type="number" min={0} max={100} step={0.5} value={pcts[i]}
              onChange={(ev) => setPcts((p) => p.map((x, j) => (j === i ? ev.target.value : x)))} />
            <span className="unit">%</span>
          </label>
        ))}
        <label>
          <span>Nominal in</span>
          <input type="number" min={Number(s.jitterBefore) + 1} value={delay} onChange={(ev) => setDelay(ev.target.value)} />
          <span className="unit">s</span>
        </label>
      </div>
      {!valid && <p className="warn">Weights sum to {(sum / 100).toFixed(2)}%. They must sum to 100%.</p>}
      {valid && (
        <div className="trades">
          <h3>Sealed trade list ({trades.length})</h3>
          {trades.length === 0 && <p className="muted">Already at target.</p>}
          <ul>
            {trades.map((t, i) => {
              const a = s.constituents[t.tokenIn];
              return (
                <li key={i} className="mono">
                  sell {fmtAmount(t.amountIn, a.decimals)} {a.symbol} → {s.constituents[t.tokenOut].symbol}
                </li>
              );
            })}
          </ul>
        </div>
      )}
      <div className="actions">
        <button disabled={!valid || tx.status === "pending" || tx.status === "mining"} onClick={commit}>
          Seal &amp; commit
        </button>
      </div>
      <TxLine tx={tx} />
    </>
  );
}

function SealedPanel({ s, vault }: { s: VaultState; vault: Address }) {
  const e = s.epochs[0];
  const [sealed, setSealed] = useState<Sealed | null>(null);
  const [fileErr, setFileErr] = useState("");

  useEffect(() => setSealed(loadSealed(chain.id, vault, e.id)), [vault, e.id]);

  const matches = sealed ? hashRebalance(sealed) === e.commitment : false;
  const seeded = e.status === "Seeded";
  const at = sealed && matches && seeded ? executionTime(sealed.salt, e.seedHash, e.windowStart, e.windowEnd) : undefined;

  async function onFile(f: File | undefined) {
    if (!f) return;
    try {
      const parsed = parseSealed(await f.text());
      setSealed(parsed);
      saveSealed(parsed);
      setFileErr("");
    } catch {
      setFileErr("Not a Whisprr sealed-plan file.");
    }
  }

  return (
    <>
      <p className="muted">
        Rebalance #{e.id.toString()} is sealed. Your part is done: Chainlink executes it at the second its salt and the
        seed block imply. There's no execute button, for anyone.
      </p>
      {!sealed && (
        <label className="file">
          No sealed plan for this epoch in this browser. Load the file saved at commit to see your private view:
          <input type="file" accept="application/json" onChange={(ev) => onFile(ev.target.files?.[0])} />
        </label>
      )}
      {fileErr && <p className="warn">{fileErr}</p>}
      {sealed && (
        <p className={matches ? "ok" : "warn"}>
          {matches ? "✓ Your sealed plan matches the onchain commitment" : `✗ Plan hashes to ${short(hashRebalance(sealed))}, not the commitment`}
        </p>
      )}
      <h3>Hand the sealed plan to Chainlink</h3>
      <pre className="cmd mono small">node cre/whisprr-keeper/scripts/hand-over.mjs whisprr-sealed-epoch-{e.id.toString()}.json{"\n"}cre/keeper.sh</pre>
      <p className="note">
        The plan goes to the workflow's secrets, never onchain. The keeper records the seed, then executes at the sealed
        second.
      </p>
      {at !== undefined && (
        <p className="note">
          Your private view: executes at <span className="mono">{fmtTime(at)}</span>
          {s.now < at ? ` (in ${at - s.now}s)` : ""}. The market can't compute this without the salt, and you can't
          change it.
        </p>
      )}
    </>
  );
}
