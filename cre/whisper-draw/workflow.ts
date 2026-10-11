// Whisper randomness workflow.
//
// Every 30s, read WhisperVault.pendingDraw(). When a sealed rebalance is waiting for its
// execution time, produce a 256-bit random word and deliver it as a DON-signed report
// abi.encode(uint256 epoch, uint256 randomWord) to WhisperVault.onReport via the forwarder.
// The vault mixes the word with the draw block's hash and the commitment, so the exact
// execution time was unknowable to anyone at commit time, operator included.
import { bytesToHex, cre, encodeCallMsg, getNetwork, prepareReportRequest, TxStatus, type Runtime } from "@chainlink/cre-sdk"
import { type Address, decodeFunctionResult, encodeAbiParameters, encodeFunctionData, parseAbi, parseAbiParameters, zeroAddress } from "viem"
import { z } from "zod"

export const configSchema = z.object({
	schedule: z.string(),
	chainSelectorName: z.string(),
	vaultAddress: z.string(),
	gasLimit: z.string(),
})
type Config = z.infer<typeof configSchema>

const vaultAbi = parseAbi(["function pendingDraw() view returns (bool ready, uint256 epoch)"])

/**
 * 256 random bits from CRE's Math.random(). In DON mode the runtime seeds it per execution so
 * every node derives the same value and the report reaches consensus. It isn't a CSPRNG, which
 * is why the vault also mixes in the draw block's hash.
 */
function randomWord(): bigint {
	let word = 0n
	for (let i = 0; i < 8; i++) {
		word = (word << 32n) | BigInt(Math.floor(Math.random() * 2 ** 32))
	}
	return word
}

export const onCronTrigger = (runtime: Runtime<Config>): string => {
	const { chainSelectorName, vaultAddress, gasLimit } = runtime.config
	const network = getNetwork({ chainFamily: "evm", chainSelectorName, isTestnet: true })
	if (!network) throw new Error(`Network not found: ${chainSelectorName}`)
	const evm = new cre.capabilities.EVMClient(network.chainSelector.selector)
	const vault = vaultAddress as Address

	const result = evm
		.callContract(runtime, {
			call: encodeCallMsg({ from: zeroAddress, to: vault, data: encodeFunctionData({ abi: vaultAbi, functionName: "pendingDraw" }) }),
		})
		.result()
	const [ready, epoch] = decodeFunctionResult({ abi: vaultAbi, functionName: "pendingDraw", data: bytesToHex(result.data) })

	if (!ready) {
		runtime.log(`Epoch ${epoch}: no draw pending`)
		return "skipped"
	}

	const word = randomWord()
	runtime.log(`Epoch ${epoch}: delivering random word ${word.toString(16).slice(0, 12)}…`)

	const report = runtime
		.report(prepareReportRequest(encodeAbiParameters(parseAbiParameters("uint256 epoch, uint256 randomWord"), [epoch, word])))
		.result()
	const write = evm.writeReport(runtime, { receiver: vault, report, gasConfig: { gasLimit } }).result()

	if (write.txStatus !== TxStatus.SUCCESS) {
		throw new Error(`Report tx failed: ${write.errorMessage || write.txStatus}`)
	}
	if (write.receiverContractExecutionStatus !== undefined && write.receiverContractExecutionStatus !== 0) {
		throw new Error(`WhisperVault.onReport reverted (status ${write.receiverContractExecutionStatus})`)
	}
	const txHash = bytesToHex(write.txHash || new Uint8Array(32))
	runtime.log(`Epoch ${epoch}: execution time drawn. Tx ${txHash}`)
	return txHash
}

export function initWorkflow(config: Config) {
	const cron = new cre.capabilities.CronCapability()
	return [cre.handler(cron.trigger({ schedule: config.schedule }), onCronTrigger)]
}
