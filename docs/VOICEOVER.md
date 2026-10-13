# Whisprr: technical voice-over

About 2:30 at a calm pace. One block per scene; `/` marks a short pause.

---

**1 · What it is** (0:00–0:15)

Whisprr is an onchain index vault on Monad whose rebalances stay sealed until the second they execute, /
and that second is chosen by no one. /
Here's how it works.

---

**2 · Public framework** (0:15–0:35)

Everything public is fixed at deployment, as immutables in the vault: /
the constituents, the rebalance schedule, the execution window around each anchor, the tolerances, /
and the keccak hash of the methodology document, so the rules can't change silently.

---

**3 · Commit** (0:35–1:00)

As the index committee, I set target weights and seal them. /
The browser draws a random 32-byte salt and computes keccak of the chain ID, vault, epoch, weights and salt. /
Only that hash goes onchain. Commit takes no date: the vault assigns the next scheduled anchor. /
The preimage goes to a Chainlink CRE workflow as a secret. It never touches the chain.

---

**4 · The seed** (1:00–1:25)

The commit also fixes a seed block, five blocks ahead. /
Once it's mined, the workflow records its block hash onchain, through Chainlink's forwarder. /
Now the execution second is determined: window start, plus keccak of salt and seed, modulo the window length. /
The salt was locked before the block existed, so nobody could steer the result. /
And without the salt, nobody can compute it. The public sees only the window.

---

**5 · Execution** (1:25–2:00)

The workflow computes the second locally, and at that moment delivers an execute report. /
In one transaction, the vault re-hashes the preimage against the commitment, /
recomputes the second from the revealed salt, and rejects anything early or past the tolerance. /
Then it sizes the trades itself, from the venue's prices at that second, /
and checks the resulting weights against the targets. /
There's no execute function for the operator. If the second is missed, the rebalance defaults, publicly.

---

**6 · Verification** (2:00–2:15)

Every reveal is re-checked off-chain: the browser recomputes the hash and the sealed second from the event, /
and an Envio indexer does the same independently.

---

**7 · Stack and next steps** (2:15–2:35)

Solidity and Foundry, with thirty-one tests, including fuzzing that the second always lands inside the window. /
The CRE workflow is TypeScript, running in Chainlink's simulator and writing real Monad testnet transactions. /
Dynamic for sign-in. /
Next: salt generation in an enclave or with MPC, and confidential tranches with Unlink.
