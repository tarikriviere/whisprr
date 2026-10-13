import { DynamicWidget, useDynamicContext } from "@dynamic-labs/sdk-react-core";
import { useAccount } from "wagmi";
import { chain, explorerAddress } from "./chain";
import { deployments } from "./generated/contracts";
import { useVault } from "./useVault";
import { Portfolio } from "./components/Portfolio";
import { EpochPanel } from "./components/EpochPanel";
import { OperatorConsole } from "./components/OperatorConsole";
import { History } from "./components/History";
import { TrackRecord } from "./components/TrackRecord";
import { fmtDuration, fmtTime, short } from "./whisprr";

export function App() {
  const vault = deployments[String(chain.id)]?.vault;
  const { address } = useAccount();
  const { user } = useDynamicContext();
  const { data: s, error, isLoading } = useVault(vault);
  const isOperator = !!address && !!s && address.toLowerCase() === s.operator.toLowerCase();

  return (
    <div className="page">
      <header>
        <div className="brand">
          <h1>Whisprr</h1>
          <span className="tag">sealed-rebalance index · {chain.name}</span>
        </div>
        <DynamicWidget />
      </header>

      <p className="lede">
        The rules and the schedule are public. The weights, and the exact second each rebalance executes, stay sealed until
        it happens. Nobody can trade ahead of a rebalance they can't see, and nobody picks when it runs.
      </p>

      {!vault && <div className="card warn">No deployment for chain {chain.id}. Run the deploy script, then restart the dev server.</div>}
      {error && <div className="card warn">Couldn't read the vault: {(error as Error).message}</div>}
      {isLoading && <div className="card muted">Reading the vault…</div>}

      {s && vault && (
        <div className="grid">
          <div className="col">
            <Portfolio s={s} />
            <TrackRecord s={s} vault={vault} />
            <History s={s} vault={vault} />
          </div>
          <div className="col">
            <EpochPanel s={s} vault={vault} connected={!!address} />
            {isOperator && <OperatorConsole s={s} vault={vault} />}
            {address && !isOperator && (
              <section className="card muted small">
                Signed in{user?.email ? ` as ${user.email}` : ""} with {short(address)}. Only the operator wallet{" "}
                {short(s.operator)} can commit, and only Chainlink can execute. Anyone can record the seed, flag a default, or
                verify a reveal.
              </section>
            )}
            <section className="card">
              <h2>Public framework</h2>
              <dl className="kv">
                <dt>Vault</dt><dd className="mono"><Addr a={vault} /></dd>
                <dt>Operator</dt><dd className="mono"><Addr a={s.operator} /></dd>
                <dt>Framework hash</dt><dd className="mono" title={s.frameworkHash}>{short(s.frameworkHash)}</dd>
                <dt>Schedule</dt><dd className="mono">every {fmtDuration(s.rebalancePeriod)} from {fmtTime(s.scheduleStart)}</dd>
                <dt>Commit deadline</dt><dd className="mono">{s.commitLead.toString()}s before the window</dd>
                <dt>Jitter window</dt><dd className="mono">−{s.jitterBefore.toString()}s / +{s.jitterAfter.toString()}s</dd>
                <dt>Execution tolerance</dt><dd className="mono">{s.grace.toString()}s</dd>
                <dt>Weight tolerance</dt><dd className="mono">{s.tolerance} bps</dd>
                <dt>Execution time</dt><dd>keccak256(salt, Monad seed) in window</dd>
                <dt>Executor</dt><dd>Chainlink CRE via <Addr a={s.chainlinkForwarder} /></dd>
              </dl>
            </section>
          </div>
        </div>
      )}
      <footer className="muted small">
        Commit → random draw → atomic reveal + execute. Everything runs onchain.
      </footer>
    </div>
  );
}

function Addr({ a }: { a: string }) {
  const url = explorerAddress(a);
  return url ? <a href={url} target="_blank" rel="noreferrer">{short(a)}</a> : <>{short(a)}</>;
}
