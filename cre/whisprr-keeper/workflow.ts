// Whisprr keeper workflow: the only path by which a committed rebalance executes.
//
// Every 30s it reads the vault's current epoch and does at most one thing:
//   - Committed, seed block mined  → deliver a RECORD_SEED report (stores the seed block's hash).
//   - Seeded                       → read the sealed plan from the workflow's secrets, check it
//                                    against the onchain commitment, and compute
//                                      executeAt = windowStart + keccak256(salt, seedHash) mod (window + 1).
//                                    Once the chain's clock reaches executeAt, deliver an EXECUTE
//                                    report carrying the plan. The vault rechecks everything and
//                                    rejects the report a second early or past its tolerance.
// The sealed plan never touches the chain before execution, so nobody without it can compute
// the time. The operator has no way to execute; this workflow is the only executor.
import { bytesToHex, cre, encodeCallMsg, getNetwork, prepareReportRequest, TxStatus, type Runtime } from "@chainlink/cre-sdk"
import {
	type Address,
	type Hex,
	decodeAbiParameters,
	decodeFunctionResult,
	encodeAbiParameters,
	encodeFunctionData,
	keccak256,
	parseAbi,
	zeroAddress,
} from "viem"
import { z } from "zod"

export const configSchema = z.object({
	schedule: z.string(),
	chainSelectorName: z.string(),
	chainId: z.number(),
	vaultAddress: z.string(),
	seedGasLimit: z.string(),
	executeGasLimit: z.string(),
})
type Config = z.infer<typeof configSchema>

const STATUS = ["None", "Committed", "Seeded", "Executed", "Defaulted"] as const
const REPORT_RECORD_SEED = 1
const REPORT_EXECUTE = 2

const vaultAbi = parseAbi([
	"function currentEpoch() view returns (uint256)",
	"function epochs(uint256) view returns (bytes32 commitment, bytes32 seedHash, uint64 committedBlock, uint64 seedBlock, uint64 windowStart, uint64 windowEnd, uint64 executeAt, uint64 executedAt, uint64 executedBlock, uint8 status)",
	"function pendingSeed() view returns (bool ready, uint256 epoch)",
	"function chainTime() view returns (uint64)",
	"function executionTolerance() view returns (uint64)",
])

const tradeTuple = {
	type: "tuple[]",
	components: [
		{ name: "tokenIn", type: "uint8" },
		{ name: "tokenOut", type: "uint8" },
		{ name: "amountIn", type: "uint256" },
		{ name: "minAmountOut", type: "uint256" },
	],
} as const
const sealedParams = [{ type: "uint256" }, { type: "uint16[]" }, tradeTuple, { type: "bytes32" }] as const

export const onCronTrigger = (runtime: Runtime<Config>): string => {
	const cfg = runtime.config
	const network = getNetwork({ chainFamily: "evm", chainSelectorName: cfg.chainSelectorName, isTestnet: true })
	if (!network) throw new Error(`Network not found: ${cfg.chainSelectorName}`)
	const evm = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const vault = cfg.vaultAddress as Address

	// Reads the vault at the latest block.
	const read = <const F extends (typeof vaultAbi)[number]["name"]>(functionName: F, args: readonly unknown[] = []) => {
		const data = encodeFunctionData({ abi: vaultAbi, functionName, args } as never)
		const res = evm.callContract(runtime, { call: encodeCallMsg({ from: zeroAddress, to: vault, data }) }).result()
		return decodeFunctionResult({ abi: vaultAbi, functionName, data: bytesToHex(res.data) } as never) as any
	}

	const send = (kind: number, body: Hex, gasLimit: string, what: string): string => {
		const report = runtime
			.report(prepareReportRequest(encodeAbiParameters([{ type: "uint8" }, { type: "bytes" }], [kind, body])))
			.result()
		const write = evm.writeReport(runtime, { receiver: vault, report, gasConfig: { gasLimit } }).result()
		if (write.txStatus !== TxStatus.SUCCESS) throw new Error(`${what}: tx failed: ${write.errorMessage || write.txStatus}`)
		if (write.receiverContractExecutionStatus !== undefined && write.receiverContractExecutionStatus !== 0) {
			throw new Error(`${what}: vault rejected the report (status ${write.receiverContractExecutionStatus})`)
		}
		const txHash = bytesToHex(write.txHash || new Uint8Array(32))
		runtime.log(`${what}. Tx ${txHash}`)
		return txHash
	}

	const epoch: bigint = read("currentEpoch")
	if (epoch === 0n) {
		runtime.log("No rebalance committed yet")
		return "idle"
	}
	const e = read("epochs", [epoch])
	const status = STATUS[Number(e[9])]

	if (status === "Committed") {
		const [ready] = read("pendingSeed")
		if (!ready) {
			runtime.log(`Epoch ${epoch}: waiting for seed block ${e[3]}`)
			return "waiting-seed"
		}
		// recordSeed re-arms instead of recording if the seed block fell out of the 256-block hash horizon.
		return send(REPORT_RECORD_SEED, encodeAbiParameters([{ type: "uint256" }], [epoch]), cfg.seedGasLimit, `Epoch ${epoch}: seed report delivered`)
	}

	if (status !== "Seeded") {
		runtime.log(`Epoch ${epoch}: ${status}, nothing to do`)
		return "idle"
	}

	// The sealed plan, handed over by the operator at commit. It lives only in the workflow's secrets.
	let sealedHex: Hex
	try {
		sealedHex = runtime.getSecret({ id: "sealed_plan" }).result().value.trim() as Hex
	} catch {
		runtime.log(`Epoch ${epoch}: no sealed plan in the workflow's secrets`)
		return "no-plan"
	}
	const [planEpoch, weights, trades, salt] = decodeAbiParameters(sealedParams, sealedHex)
	if (planEpoch !== epoch) {
		runtime.log(`Epoch ${epoch}: the sealed plan in secrets is for epoch ${planEpoch}`)
		return "wrong-plan"
	}
	const commitment = keccak256(
		encodeAbiParameters(
			[{ type: "uint256" }, { type: "address" }, { type: "uint256" }, { type: "uint16[]" }, tradeTuple, { type: "bytes32" }],
			[BigInt(cfg.chainId), vault, epoch, weights, trades, salt],
		),
	)
	if (commitment !== e[0]) {
		runtime.log(`Epoch ${epoch}: sealed plan doesn't match the onchain commitment`)
		return "mismatch"
	}

	// Same formula as WhisprrVault.executionTime, computed locally so the salt stays private.
	const windowStart: bigint = e[4]
	const span: bigint = e[5] - windowStart + 1n
	const executeAt = windowStart + (BigInt(keccak256(encodeAbiParameters([{ type: "bytes32" }, { type: "bytes32" }], [salt, e[1]]))) % span)
	const now: bigint = read("chainTime")
	const tolerance: bigint = read("executionTolerance")

	if (now < executeAt) {
		runtime.log(`Epoch ${epoch}: sealed time not reached, ${executeAt - now}s to go`)
		return "waiting-time"
	}
	if (now > executeAt + tolerance) {
		runtime.log(`Epoch ${epoch}: missed the sealed time by ${now - executeAt}s; it will default`)
		return "missed"
	}

	const body = encodeAbiParameters(sealedParams, [epoch, weights, trades, salt])
	return send(REPORT_EXECUTE, body, cfg.executeGasLimit, `Epoch ${epoch}: executed at the sealed time (+${now - executeAt}s)`)
}

export function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability()
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)]
}
