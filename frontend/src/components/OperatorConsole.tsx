import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { useWriteContract } from "wagmi";
import { chain } from "../chain";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import {
  downloadSealed, fmtAmount, hashRebalance, loadSealed, parseSealed, planTrades, randomSalt, saveSealed, short,
  type Sealed,
} from "../whisper";
import { TxLine } from "./TxLine";

export function OperatorConsole({ s, vault }: { s: VaultState; vault: Address }) {
  const e = s.epochs[0];
  const open = e && (e.status === "Committed" || e.status === "Drawn");
  return (
    <section className="card operator">
      <div className="card-head">
        <h2>Operator console</h2>
        <span className="pill pill-operator">operator wallet</span>
      </div>
      {open ? <ExecutePanel s={s} vault={vault} /> : <CommitPanel s={s} vault={vault} />}
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

function ExecutePanel({ s, vault }: { s: VaultState; vault: Address }) {
  const e = s.epochs[0];
  const [sealed, setSealed] = useState<Sealed | null>(null);
  const [fileErr, setFileErr] = useState("");
  const { writeContractAsync } = useWriteContract();
  const tx = useTx();

  useEffect(() => setSealed(loadSealed(chain.id, vault, e.id)), [vault, e.id]);

  const matches = sealed ? hashRebalance(sealed) === e.commitment : false;
  const canExecute = e.status === "Drawn" && s.now >= e.executeAt && matches;

  async function onFile(f: File | undefined) {
    if (!f) return;
    try {
      const parsed = parseSealed(await f.text());
      setSealed(parsed);
      saveSealed(parsed);
      setFileErr("");
    } catch {
      setFileErr("Not a Whisper sealed-preimage file.");
    }
  }

  return (
    <>
      <p className="muted">Rebalance #{e.id.toString()} is sealed. Executing it reveals the preimage and trades in one transaction.</p>
      {!sealed && (
        <label className="file">
          No preimage for this epoch in this browser. Load the file saved at commit:
          <input type="file" accept="application/json" onChange={(ev) => onFile(ev.target.files?.[0])} />
        </label>
      )}
      {fileErr && <p className="warn">{fileErr}</p>}
      {sealed && (
        <p className={matches ? "ok" : "warn"}>
          {matches ? "✓ Local preimage matches the onchain commitment" : `✗ Preimage hashes to ${short(hashRebalance(sealed))}, not the commitment`}
        </p>
      )}
      <div className="actions">
        <button disabled={!canExecute || tx.status === "pending" || tx.status === "mining"}
          onClick={() => sealed && tx.run(() => writeContractAsync({
            address: vault, abi: vaultAbi, functionName: "execute",
            args: [sealed.weights, sealed.trades, sealed.salt],
          }))}>
          Reveal &amp; execute
        </button>
        {e.status === "Committed" && <span className="muted">Waiting for the execution time to be drawn.</span>}
        {e.status === "Drawn" && s.now < e.executeAt && <span className="muted">Unlocks in {(e.executeAt - s.now).toString()}s</span>}
      </div>
      <TxLine tx={tx} />
    </>
  );
}
