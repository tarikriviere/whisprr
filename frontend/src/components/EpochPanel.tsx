import { useWriteContract } from "wagmi";
import type { Address } from "viem";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import { fmtTime, short } from "../whisper";
import { TxLine } from "./TxLine";

const pct = (t: bigint, a: bigint, b: bigint) => Math.min(100, Math.max(0, (Number(t - a) / Number(b - a || 1n)) * 100));

export function EpochPanel({ s, vault, connected }: { s: VaultState; vault: Address; connected: boolean }) {
  const e = s.epochs[0];
  const { writeContractAsync } = useWriteContract();
  const tx = useTx();

  if (!e) {
    return (
      <section className="card">
        <h2>Current rebalance</h2>
        <p className="muted">No rebalance has been committed yet.</p>
      </section>
    );
  }

  const nominal = e.windowStart + s.jitterBefore;
  const deadline = e.executeAt + s.grace;
  const drawReady = e.status === "Committed" && s.blockNumber > e.drawBlock;
  const defaultable = e.status === "Drawn" && s.now > deadline;
  const send = (fn: "drawExecutionTime" | "markDefaulted") =>
    tx.run(() => writeContractAsync({ address: vault, abi: vaultAbi, functionName: fn }));

  let note = "";
  if (e.status === "Committed") note = drawReady ? "Draw block mined: anyone can draw the execution time." : `Waiting for draw block ${e.drawBlock} (now ${s.blockNumber}).`;
  if (e.status === "Drawn") note = s.now < e.executeAt ? `Executes in ${e.executeAt - s.now}s. Nobody, including the operator, knew this time at commit.` : s.now <= deadline ? `Execution window open, ${deadline - s.now}s left in grace.` : "Operator missed the grace period.";
  if (e.status === "Executed") note = "Revealed and executed atomically. Verify it below.";
  if (e.status === "Defaulted") note = "Publicly flagged: the operator didn't execute in time.";

  return (
    <section className="card">
      <div className="card-head">
        <h2>Rebalance #{e.id.toString()}</h2>
        <span className={`pill pill-${e.status.toLowerCase()}`}>{e.status}</span>
      </div>
      <dl className="kv">
        <dt>Sealed commitment</dt><dd className="mono" title={e.commitment}>{short(e.commitment)}</dd>
        <dt>Window</dt><dd className="mono">{fmtTime(e.windowStart)} → {fmtTime(e.windowEnd)}</dd>
        <dt>Drawn execution time</dt><dd className="mono">{fmtTime(e.executeAt)}</dd>
      </dl>
      <div className="timeline" aria-label="Execution window">
        <div className="tl-track" />
        <div className="tl-mark tl-nominal" style={{ left: `${pct(nominal, e.windowStart, e.windowEnd)}%` }} title="Nominal date"><span>nominal</span></div>
        {e.executeAt > 0n && (
          <div className="tl-mark tl-exec" style={{ left: `${pct(e.executeAt, e.windowStart, e.windowEnd)}%` }} title="Drawn execution time"><span>drawn</span></div>
        )}
        <div className="tl-now" style={{ left: `${pct(s.now, e.windowStart, e.windowEnd)}%` }} title="Now" />
      </div>
      <p className="note">{note}</p>
      {connected && (drawReady || defaultable) && (
        <div className="actions">
          {drawReady && <button onClick={() => send("drawExecutionTime")}>Draw execution time</button>}
          {defaultable && <button className="danger" onClick={() => send("markDefaulted")}>Flag as defaulted</button>}
        </div>
      )}
      <TxLine tx={tx} />
    </section>
  );
}
