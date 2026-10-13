import { useEffect, useMemo, useState } from "react";
import type { Address } from "viem";
import { useWriteContract } from "wagmi";
import { chain } from "../chain";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import { useClock } from "../useClock";
import {
  downloadSealed, executionTime, fmtAmount, fmtDuration, fmtTime, hashRebalance, loadSealed, nextSlot, parseSealed,
  planTrades, randomSalt, saveSealed, short, type Sealed,
} from "../whisprr";
import { TxLine } from "./TxLine";

export function OperatorConsole({ s, vault }: { s: VaultState; vault: Address }) {
  const e = s.epochs[0];
  // An open rebalance past its last execution time no longer blocks: the next commit flags it defaulted.
  const open = e && (e.status === "Committed" || e.status === "Seeded") && s.now <= e.lastExecution;
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
  const { writeContractAsync } = useWriteContract();
  const tx = useTx();
  const clock = useClock();
  const slot = nextSlot(s, clock);

  const weights = pcts.map((p) => Math.round(Number(p) * 100));
  const sum = weights.reduce((a, b) => a + b, 0);
  const valid = sum === 10_000 && weights.every((w) => Number.isFinite(w) && w >= 0);
  const trades = useMemo(() => (valid ? planTrades(s.constituents, weights) : []), [valid, s.constituents, pcts.join()]);

  async function commit() {
    const sealed: Sealed = {
      chainId: chain.id, vault, epoch: (s.epochs[0]?.id ?? 0n) + 1n, weights, salt: randomSalt(),
    };
    const commitment = hashRebalance(sealed);
    // Keep the preimage before anything is broadcast: without it the epoch can't be executed.
    saveSealed(sealed);
    downloadSealed(sealed);
    await tx.run(() =>
      writeContractAsync({ address: vault, abi: vaultAbi, functionName: "commit", args: [commitment] }),
    );
  }

  return (
    <>
      <p className="muted">
        Set the target weights. Only their hash goes onchain. The preimage stays in this browser and in a downloaded file
        until execution. The date isn't yours to choose: this seals the next scheduled rebalance.
      </p>
      <p className="countdown mono">
        Seals the {fmtTime(slot.nominal)} rebalance · commit within {fmtDuration(slot.commitDeadline - clock)}
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
      </div>
      {!valid && <p className="warn">Weights sum to {(sum / 100).toFixed(2)}%. They must sum to 100%.</p>}
      {valid && (
        <div className="trades">
          <h3>Trades at today's prices ({trades.length})</h3>
          <p className="muted small">
            A preview. Only the weights are sealed: the vault sizes the trades itself at the execution second, from the
            prices then.
          </p>
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
  const clock = useClock();

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
      {at !== undefined ? (
        <p className="countdown mono">
          Your private view: executes at {fmtTime(at)}
          {clock < at ? ` · in ${fmtDuration(at - clock)}` : " · now"}
        </p>
      ) : (
        sealed && matches && <p className="countdown mono">Waiting for the Monad seed: then the second is fixed</p>
      )}
      <p className="muted">
        Rebalance #{e.id.toString()} is sealed. Your part is done: the Chainlink CRE keeper executes it at the second its salt and the
        seed block imply. The market sees only the window and can't compute this second without the salt; you can't
        change it. There's no execute button, for anyone.
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
      <p className="note">
        The sealed plan file saved to Downloads goes to the Chainlink workflow's secrets, never onchain: the keeper
        (<span className="mono">WATCH_DIR=… cre/keeper.sh</span>) picks it up automatically. Manually:{" "}
        <span className="mono">node cre/whisprr-keeper/scripts/hand-over.mjs whisprr-sealed-epoch-{e.id.toString()}.json</span>
      </p>
    </>
  );
}
