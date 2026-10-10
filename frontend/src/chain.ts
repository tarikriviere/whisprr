import { defineChain, type Chain } from "viem";
import { monadTestnet } from "viem/chains";

const local = defineChain({
  id: 31337,
  name: "Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["http://127.0.0.1:8545"] } },
});

export const chain: Chain = import.meta.env.VITE_CHAIN === "local" ? local : monadTestnet;

export const explorerTx = (hash: string) =>
  chain.blockExplorers ? `${chain.blockExplorers.default.url}/tx/${hash}` : undefined;
export const explorerAddress = (addr: string) =>
  chain.blockExplorers ? `${chain.blockExplorers.default.url}/address/${addr}` : undefined;

/** The same chain in the shape Dynamic's evmNetworks override expects. */
export const dynamicNetwork = {
  chainId: chain.id,
  networkId: chain.id,
  name: chain.name,
  vanityName: chain.name,
  iconUrls: ["https://app.dynamic.xyz/assets/networks/eth.svg"],
  nativeCurrency: { ...chain.nativeCurrency, iconUrl: "https://app.dynamic.xyz/assets/networks/eth.svg" },
  rpcUrls: [...chain.rpcUrls.default.http],
  blockExplorerUrls: chain.blockExplorers ? [chain.blockExplorers.default.url] : [],
};
