import type { VaultState } from "../useVault";
import { fmtAmount, fmtBps, fmtUsd } from "../whisper";

export function Portfolio({ s }: { s: VaultState }) {
  return (
    <section className="card">
      <div className="card-head">
        <h2>Vault holdings</h2>
        <span className="big mono">{fmtUsd(s.total)}</span>
      </div>
      <table className="holdings">
        <thead>
          <tr><th>Asset</th><th className="num">Balance</th><th className="num">Price</th><th className="num">Value</th><th>Weight</th></tr>
        </thead>
        <tbody>
          {s.constituents.map((c, i) => (
            <tr key={c.address}>
              <td><span className={`dot dot-${i}`} />{c.symbol}</td>
              <td className="num mono">{fmtAmount(c.balance, c.decimals)}</td>
              <td className="num mono">{fmtUsd(c.price)}</td>
              <td className="num mono">{fmtUsd(c.value)}</td>
              <td className="weight">
                <div className="bar"><div className={`fill fill-${i}`} style={{ width: `${Number(s.weights[i]) / 100}%` }} /></div>
                <span className="mono">{fmtBps(s.weights[i])}</span>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  );
}
