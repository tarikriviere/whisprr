import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import type { VaultState } from "../useVault";

const INDEXER_URL = import.meta.env.VITE_INDEXER_URL as string | undefined;

type Row = { epoch: string; offsetFromNominal: string | null; sealedSeconds: string | null; verified: boolean | null; onSchedule: boolean | null; status: string };
type Data = {
  Vault: { epochCount: number; executedCount: number; defaultedCount: number; verifiedCount: number; onScheduleCount: number }[];
  Epoch: Row[];
};

const QUERY = `query ($vault: String!, $vaultId: String!) {
  Vault(where: { address: { _ilike: $vault } }) { epochCount executedCount defaultedCount verifiedCount onScheduleCount }
  Epoch(where: { vault_id: { _like: $vaultId } }, order_by: { epoch: desc }, limit: 100) {
    epoch offsetFromNominal sealedSeconds verified onSchedule status
  }
}`;

/** Rebalance track record from the Envio indexer: totals plus where each drawn time landed vs. nominal. */
export function TrackRecord({ s, vault }: { s: VaultState; vault: Address }) {
  const q = useQuery({
    queryKey: ["indexer", vault],
    enabled: !!INDEXER_URL,
    refetchInterval: 5_000,
    queryFn: async (): Promise<Data> => {
      const res = await fetch(INDEXER_URL!, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ query: QUERY, variables: { vault, vaultId: `%-${vault.toLowerCase()}` } }),
      });
      const json = await res.json();
      if (json.errors) throw new Error(json.errors[0].message);
      return json.data;
    },
  });
  if (!INDEXER_URL) return null;

  const v = q.data?.Vault[0];
  const drawn = (q.data?.Epoch ?? []).filter((e) => e.offsetFromNominal !== null);
  const sealed = (q.data?.Epoch ?? []).filter((e) => e.sealedSeconds !== null).map((e) => Number(e.sealedSeconds));
  const lo = -Number(s.jitterBefore);
  const hi = Number(s.jitterAfter);
  const x = (off: number) => ((off - lo) / (hi - lo || 1)) * 100;
  const meanOffset = drawn.length ? drawn.reduce((a, e) => a + Number(e.offsetFromNominal), 0) / drawn.length : 0;

  return (
    <section className="card">
      <div className="card-head">
        <h2>Track record</h2>
        <span className="muted small">indexed by Envio</span>
      </div>
      {q.isError && <p className="warn small">Indexer unreachable: {(q.error as Error).message}</p>}
      {v && (
        <div className="stats">
          <Stat label="Rebalances executed" value={`${v.executedCount}/${v.epochCount}`} />
          <Stat label="Reveals verified" value={`${v.verifiedCount}/${v.executedCount}`} good={v.verifiedCount === v.executedCount} />
          <Stat label="At the sealed second" value={`${v.onScheduleCount}/${v.executedCount}`} good={v.onScheduleCount === v.executedCount} />
          <Stat label="Avg. time sealed" value={sealed.length ? `${Math.round(sealed.reduce((a, b) => a + b, 0) / sealed.length)}s` : "–"} />
        </div>
      )}
      {drawn.length > 0 && (
        <>
          <h3>Sealed execution second vs. nominal</h3>
          <div className="strip" role="img" aria-label={`Offsets of ${drawn.length} drawn execution times, mean ${meanOffset.toFixed(0)} seconds from nominal`}>
            <div className="strip-track" />
            <div className="strip-zero" style={{ left: `${x(0)}%` }}><span>nominal</span></div>
            {drawn.map((e) => (
              <div key={e.epoch} className="strip-dot" style={{ left: `${x(Number(e.offsetFromNominal))}%` }}
                title={`#${e.epoch}: ${Number(e.offsetFromNominal) >= 0 ? "+" : ""}${e.offsetFromNominal}s${e.verified ? " · verified" : ""}${e.onSchedule ? " · on schedule" : ""}`} />
            ))}
          </div>
          <div className="strip-axis mono small muted"><span>−{s.jitterBefore.toString()}s</span><span>+{s.jitterAfter.toString()}s</span></div>
          <p className="note">
            Each dot is an executed rebalance. Its second came from keccak256(salt, Monad seed), uniform over the window, so
            offsets scatter on both sides of nominal instead of landing on a date the market could trade ahead of. Mean offset so far: {meanOffset >= 0 ? "+" : ""}{meanOffset.toFixed(0)}s.
          </p>
        </>
      )}
    </section>
  );
}

function Stat({ label, value, good }: { label: string; value: string; good?: boolean }) {
  return (
    <div className="stat">
      <div className={`stat-value mono${good ? " ok" : ""}`}>{value}</div>
      <div className="stat-label muted small">{label}</div>
    </div>
  );
}
