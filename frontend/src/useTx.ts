import { useState } from "react";
import { BaseError, type Hash } from "viem";
import { usePublicClient } from "wagmi";

export type TxState = { status: "idle" | "pending" | "mining" | "done" | "error"; hash?: Hash; error?: string };

/** Wraps a write so the UI can show its hash, wait for the receipt and surface revert reasons. */
export function useTx() {
  const client = usePublicClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  async function run(send: () => Promise<Hash>) {
    setState({ status: "pending" });
    try {
      const hash = await send();
      setState({ status: "mining", hash });
      const receipt = await client!.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted");
      setState({ status: "done", hash });
      return hash;
    } catch (e) {
      const msg = e instanceof BaseError ? e.shortMessage : e instanceof Error ? e.message : String(e);
      setState((s) => ({ status: "error", hash: s.hash, error: msg }));
    }
  }

  return { ...state, run, reset: () => setState({ status: "idle" }) };
}
