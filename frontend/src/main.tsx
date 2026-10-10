import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { DynamicContextProvider } from "@dynamic-labs/sdk-react-core";
import { EthereumWalletConnectors } from "@dynamic-labs/ethereum";
import { DynamicWagmiConnector } from "@dynamic-labs/wagmi-connector";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { createConfig, http, WagmiProvider } from "wagmi";
import { chain, dynamicNetwork } from "./chain";
import { App } from "./App";
import "./styles.css";

const wagmiConfig = createConfig({
  chains: [chain],
  multiInjectedProviderDiscovery: false,
  transports: { [chain.id]: http() },
});
const queryClient = new QueryClient();
const environmentId = import.meta.env.VITE_DYNAMIC_ENV_ID as string | undefined;

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    {environmentId ? (
      <DynamicContextProvider
        settings={{
          environmentId,
          walletConnectors: [EthereumWalletConnectors],
          overrides: { evmNetworks: [dynamicNetwork] },
        }}
      >
        <WagmiProvider config={wagmiConfig}>
          <QueryClientProvider client={queryClient}>
            <DynamicWagmiConnector>
              <App />
            </DynamicWagmiConnector>
          </QueryClientProvider>
        </WagmiProvider>
      </DynamicContextProvider>
    ) : (
      <div className="setup">
        <h1>Whisper</h1>
        <p>
          Set <code>VITE_DYNAMIC_ENV_ID</code> in <code>frontend/.env</code> (Dynamic dashboard → Developers → SDK &amp; API
          Keys), then restart <code>npm run dev</code>.
        </p>
      </div>
    )}
  </StrictMode>,
);
