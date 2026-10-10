import { explorerTx } from "../chain";
import type { TxState } from "../useTx";
import { short } from "../whisper";

export function TxLine({ tx }: { tx: TxState }) {
  if (tx.status === "idle") return null;
  const url = tx.hash && explorerTx(tx.hash);
  return (
    <div className={`tx tx-${tx.status}`}>
      {tx.status === "pending" && "Confirm in your wallet…"}
      {tx.status === "mining" && "Waiting for confirmation…"}
      {tx.status === "done" && "Confirmed"}
      {tx.status === "error" && tx.error}
      {tx.hash && (
        <>
          {" · "}
          {url ? <a href={url} target="_blank" rel="noreferrer" className="mono">{short(tx.hash)}</a> : <span className="mono">{short(tx.hash)}</span>}
        </>
      )}
    </div>
  );
}
