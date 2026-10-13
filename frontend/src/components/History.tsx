import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { usePublicClient } from "wagmi";
import { chain, explorerTx } from "../chain";
import { vaultAbi } from "../generated/contracts";
import type { VaultState } from "../useVault";
import { executionTime, fmtBps, fmtTime, hashRebalance, short, type Epoch } from "../whisprr";

export function History({ s, vault }: { s: VaultState; vault: Address }) {
  if (s.epochs.length === 0) return null;
  return (
    <section className="card">
      <h2>Rebalance history</h2>
      <p className="muted">
        Each reveal is checked in your browser twice: its hash against the commitment posted before anyone knew the
        weights, and its execution second against the one its salt and the Monad seed imply.
      </p>
      <div className="history">
        {s.epochs.map((e) => <EpochRow key={e.id.toString()} e={e} s={s} vault={vault} />)}
      </div>
    </section>
  );
}

function EpochRow({ e, s, vault }: { e: Epoch; s: VaultState; vault: Address }) {
  const client = usePublicClient();
  const reveal = useQuery({
    queryKey: ["reveal", vault, e.id.toString()],
    enabled: e.status === "Executed" && !!client,
    staleTime: Infinity,
    queryFn: async () => {
      const [log] = await client!.getContractEvents({
        address: vault, abi: vaultAbi, eventName: "Executed", args: { epoch: e.id },
        fromBlock: e.executedBlock, toBlock: e.executedBlock,
      });
      const trades = await client!.getContractEvents({
        address: vault, abi: vaultAbi, eventName: "TradeExecuted", args: { epoch: e.id },
        fromBlock: e.executedBlock, toBlock: e.executedBlock,
      });
      const { weights, salt } = log.args;
      const recomputed = hashRebalance({ chainId: chain.id, vault, epoch: e.id, weights: [...weights!], salt: salt! });
      const sealedAt = executionTime(salt!, e.seedHash, e.windowStart, e.windowEnd);
      const onTime = sealedAt === log.args.executeAt && e.executedAt >= sealedAt && e.executedAt <= sealedAt + s.grace;
      return { weights: weights!, trades, salt: salt!, recomputed, tx: log.transactionHash, sealedAt, onTime };
    },
  });

  const r = reveal.data;
  const verified = r && r.recomputed === e.commitment;
  const url = r && explorerTx(r.tx);
  return (
    <div className="epoch-row">
      <div className="epoch-meta">
        <strong>#{e.id.toString()}</strong>
        <span className={`pill pill-${e.status.toLowerCase()}`}>{e.status}</span>
        <span className="mono muted" title={e.commitment}>{short(e.commitment)}</span>
        {e.executedAt > 0n && <span className="muted">executed {fmtTime(e.executedAt)}</span>}
        {e.status === "Executed" && <span className="muted">· by Chainlink</span>}
      </div>
      {r && (
        <div className="reveal">
          <div className="reveal-weights">
            {r.weights.map((w, i) => (
              <span key={i} className="mono"><span className={`dot dot-${i}`} />{s.constituents[i]?.symbol} {fmtBps(w)}</span>
            ))}
          </div>
          <div className="mono muted">salt {short(r.salt)} · {r.trades.length} trades sized at execution{url && <> · <a href={url} target="_blank" rel="noreferrer">tx</a></>}</div>
          <div className={verified ? "ok" : "warn"}>
            {verified ? "✓ keccak256(preimage) = commitment: executed exactly as sealed" : `✗ preimage hashes to ${short(r.recomputed)}`}
          </div>
          <div className={r.onTime ? "ok" : "warn"}>
            {r.onTime
              ? `✓ executed at the sealed second ${fmtTime(r.sealedAt)} (+${e.executedAt - r.sealedAt}s), fixed by salt + Monad seed`
              : `✗ executed at ${fmtTime(e.executedAt)}, sealed second was ${fmtTime(r.sealedAt)}`}
          </div>
        </div>
      )}
      {reveal.isError && <div className="warn">Couldn't load the reveal event.</div>}
    </div>
  );
}
