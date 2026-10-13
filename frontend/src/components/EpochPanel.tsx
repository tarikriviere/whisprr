import { useWriteContract } from "wagmi";
import type { Address } from "viem";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import { fmtTime, short } from "../whisprr";
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
  const seedReady = e.status === "Committed" && s.blockNumber > e.seedBlock;
  const open = e.status === "Committed" || e.status === "Seeded";
  const defaultable = open && s.now > e.lastExecution;
  const send = (fn: "recordSeed" | "markDefaulted") =>
    tx.run(() => writeContractAsync({ address: vault, abi: vaultAbi, functionName: fn }));

  let note = "";
  if (e.status === "Committed") {
    note = seedReady
      ? "Seed block mined. Chainlink records its hash next (anyone can)."
      : `Waiting for seed block ${e.seedBlock} (now ${s.blockNumber}).`;
  }
  if (e.status === "Seeded") {
    note = defaultable
      ? "The window and tolerance have passed without execution: anyone can flag a default."
      : "The execution second is now fixed: keccak256(salt, seed) inside the window. Only the sealed plan's holders can compute it. Chainlink executes at that second; the operator can't.";
  }
  if (e.status === "Executed") {
    note = `Chainlink executed at the sealed second (+${e.executedAt - e.executeAt}s). The time and the trades became public in the same transaction.`;
  }
  if (e.status === "Defaulted") note = "Publicly flagged: not executed by the end of its window.";

  return (
    <section className="card">
      <div className="card-head">
        <h2>Rebalance #{e.id.toString()}</h2>
        <span className={`pill pill-${e.status.toLowerCase()}`}>{e.status}</span>
      </div>
      <dl className="kv">
        <dt>Sealed commitment</dt><dd className="mono" title={e.commitment}>{short(e.commitment)}</dd>
        <dt>Public window</dt><dd className="mono">{fmtTime(e.windowStart)} → {fmtTime(e.windowEnd)}</dd>
        <dt>Seed (Monad block {e.seedBlock.toString()})</dt>
        <dd className="mono" title={e.seedHash}>{/^0x0+$/.test(e.seedHash) ? "pending" : short(e.seedHash)}</dd>
        <dt>Execution second</dt>
        <dd className="mono">{e.status === "Executed" ? fmtTime(e.executeAt) : "sealed"}</dd>
      </dl>
      <div className="timeline" aria-label="Execution window">
        <div className="tl-track" />
        <div className="tl-mark tl-nominal" style={{ left: `${pct(nominal, e.windowStart, e.windowEnd)}%` }} title="Nominal date"><span>nominal</span></div>
        {e.status === "Executed" && (
          <div className="tl-mark tl-exec" style={{ left: `${pct(e.executeAt, e.windowStart, e.windowEnd)}%` }} title="Sealed execution second"><span>executed</span></div>
        )}
        {open && <div className="tl-now" style={{ left: `${pct(s.now, e.windowStart, e.windowEnd)}%` }} title="Now" />}
      </div>
      <p className="note">{note}</p>
      {connected && (seedReady || defaultable) && (
        <div className="actions">
          {seedReady && <button onClick={() => send("recordSeed")}>Record seed</button>}
          {defaultable && <button className="danger" onClick={() => send("markDefaulted")}>Flag as defaulted</button>}
        </div>
      )}
      <TxLine tx={tx} />
    </section>
  );
}
