import { useQuery } from "@tanstack/react-query";
import { erc20Abi, type Address, type Hex } from "viem";
import { usePublicClient } from "wagmi";
import { vaultAbi, venueAbi } from "./generated/contracts";
import { STATUS, type Constituent, type Epoch } from "./whisper";

export type VaultState = {
  operator: Address;
  venue: Address;
  frameworkHash: Hex;
  jitterBefore: bigint;
  jitterAfter: bigint;
  grace: bigint;
  tolerance: number;
  drawDelay: bigint;
  constituents: Constituent[];
  total: bigint;
  weights: bigint[];
  epochs: Epoch[]; // newest first
  now: bigint;
  blockNumber: bigint;
};

export function useVault(vault: Address | undefined) {
  const client = usePublicClient();
  return useQuery({
    queryKey: ["vault", vault],
    enabled: !!vault && !!client,
    refetchInterval: 2_000,
    queryFn: async (): Promise<VaultState> => {
      const c = { address: vault!, abi: vaultAbi } as const;
      const [operator, venue, frameworkHash, jitterBefore, jitterAfter, grace, tolerance, drawDelay, addrs, current, weights, block] =
        await Promise.all([
          client!.readContract({ ...c, functionName: "operator" }),
          client!.readContract({ ...c, functionName: "venue" }),
          client!.readContract({ ...c, functionName: "frameworkHash" }),
          client!.readContract({ ...c, functionName: "jitterBefore" }),
          client!.readContract({ ...c, functionName: "jitterAfter" }),
          client!.readContract({ ...c, functionName: "executionGrace" }),
          client!.readContract({ ...c, functionName: "weightToleranceBps" }),
          client!.readContract({ ...c, functionName: "DRAW_DELAY" }),
          client!.readContract({ ...c, functionName: "constituents" }),
          client!.readContract({ ...c, functionName: "currentEpoch" }),
          client!.readContract({ ...c, functionName: "currentWeights" }),
          client!.getBlock(),
        ]);

      const constituents = await Promise.all(
        addrs.map(async (address): Promise<Constituent> => {
          const t = { address, abi: erc20Abi } as const;
          const [symbol, decimals, balance, price] = await Promise.all([
            client!.readContract({ ...t, functionName: "symbol" }),
            client!.readContract({ ...t, functionName: "decimals" }),
            client!.readContract({ ...t, functionName: "balanceOf", args: [vault!] }),
            client!.readContract({ address: venue, abi: venueAbi, functionName: "priceOf", args: [address] }),
          ]);
          return { address, symbol, decimals, balance, price, value: (balance * price) / 10n ** BigInt(decimals) };
        }),
      );

      const ids = Array.from({ length: Number(current) }, (_, i) => current - BigInt(i));
      const epochs = await Promise.all(
        ids.map(async (id): Promise<Epoch> => {
          const [commitment, committedBlock, drawBlock, windowStart, windowEnd, executeAt, executedAt, executedBlock, status] =
            await client!.readContract({ ...c, functionName: "epochs", args: [id] });
          return {
            id, commitment, committedBlock, drawBlock, windowStart, windowEnd, executeAt, executedAt, executedBlock,
            status: STATUS[status],
          };
        }),
      );

      return {
        operator, venue, frameworkHash, jitterBefore, jitterAfter, grace, tolerance, drawDelay,
        constituents, total: constituents.reduce((a, x) => a + x.value, 0n), weights: [...weights],
        epochs, now: block.timestamp, blockNumber: block.number,
      };
    },
  });
}
