import { useWriteContract } from "wagmi";
import type { Address } from "viem";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { useTx } from "../useTx";
import { useClock } from "../useClock";
import { fmtDuration, fmtTime, nextSlot, short } from "../whisprr";
import { TxLine } from "./TxLine";

const pct = (t: bigint, a: bigint, b: bigint) => Math.min(100, Math.max(0, (Number(t - a) / Number(b - a || 1n)) * 100));

/** Where a rebalance's public window stands, as a live countdown. */
function phase(now: bigint, start: bigint, end: bigint, last: bigint): string {
  if (now < start) return `Window opens in ${fmtDuration(start - now)}`;
  if (now <= end) return `Window open · closes in ${fmtDuration(end - now)}`;
  if (now <= last) return `Window closed · execution tolerance ends in ${fmtDuration(last - now)}`;
  return "Window and tolerance over";
}

export function EpochPanel({ s, vault, connected }: { s: VaultState; vault: Address; connected: boolean }) {
  const e = s.epochs[0];
  const { writeContractAsync } = useWriteContract();
  const tx = useTx();
  const clock = useClock();
  const open = !!e && (e.status === "Committed" || e.status === "Seeded");
  // The next date the operator could still commit for: after the open rebalance, if there is one.
  const next = nextSlot(s, open && clock < e.lastExecution ? e.lastExecution : clock);

  const schedule = (
    <dl className="kv">
      <dt>Next scheduled rebalance</dt>
      <dd className="mono">{fmtTime(next.nominal)} (window {fmtTime(next.windowStart)} → {fmtTime(next.windowEnd)})</dd>
      <dt>Commit deadline</dt>
      <dd className="mono">{fmtTime(next.commitDeadline)} (in {fmtDuration(next.commitDeadline - clock)})</dd>
    </dl>
  );

  if (!e) {
    return (
      <section className="card">
        <h2>Rebalance schedule</h2>
        <p className="muted">
          A rebalance every {fmtDuration(s.rebalancePeriod)}, on dates fixed at deployment. No rebalance committed yet.
        </p>
        {schedule}
      </section>
    );
  }

  const nominal = e.windowStart + s.jitterBefore;
  const seedReady = e.status === "Committed" && s.blockNumber > e.seedBlock;
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
        <dt>Scheduled date</dt><dd className="mono">{fmtTime(nominal)}</dd>
        <dt>Public window</dt><dd className="mono">{fmtTime(e.windowStart)} → {fmtTime(e.windowEnd)}</dd>
        <dt>Seed (Monad block {e.seedBlock.toString()})</dt>
        <dd className="mono" title={e.seedHash}>{/^0x0+$/.test(e.seedHash) ? "pending" : short(e.seedHash)}</dd>
        <dt>Execution second</dt>
        <dd className="mono">{e.status === "Executed" ? fmtTime(e.executeAt) : "sealed"}</dd>
      </dl>
      {open && <p className="countdown mono">{phase(clock, e.windowStart, e.windowEnd, e.lastExecution)}</p>}
      <div className="timeline" aria-label="Execution window">
        <div className="tl-track" />
        <div className="tl-mark tl-nominal" style={{ left: `${pct(nominal, e.windowStart, e.windowEnd)}%` }} title="Nominal date"><span>nominal</span></div>
        {e.status === "Executed" && (
          <div className="tl-mark tl-exec" style={{ left: `${pct(e.executeAt, e.windowStart, e.windowEnd)}%` }} title="Sealed execution second"><span>executed</span></div>
        )}
        {/* Live only once the window opens: progress fills behind a pulsing "now" dot. */}
        {open && clock >= e.windowStart && (
          <>
            <div className="tl-progress" style={{ width: `${pct(clock, e.windowStart, e.windowEnd)}%` }} />
            <div className="tl-now" style={{ left: `${pct(clock, e.windowStart, e.windowEnd)}%` }} title="Now"><span>live</span></div>
          </>
        )}
      </div>
      <div className="tl-ends mono small muted"><span>{fmtTime(e.windowStart)}</span><span>{fmtTime(e.windowEnd)}</span></div>
      <p className="note">{note}</p>
      {connected && (seedReady || defaultable) && (
        <div className="actions">
          {seedReady && <button onClick={() => send("recordSeed")}>Record seed</button>}
          {defaultable && <button className="danger" onClick={() => send("markDefaulted")}>Flag as defaulted</button>}
        </div>
      )}
      <TxLine tx={tx} />
      <h3>Schedule</h3>
      {schedule}
    </section>
  );
}
