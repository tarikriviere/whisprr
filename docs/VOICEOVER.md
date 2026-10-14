# Whisprr: technical voice-over

About 2:55 at a calm pace. One block per scene; `/` marks a short pause.

---

**1 · What it is** (0:00–0:15)

Whisprr is an onchain index vault on Monad whose rebalances stay sealed until the second they execute, /
and that second is chosen by no one. /
Here's how it works.

---

**2 · The index on screen** (0:15–0:40)

This is a one-million-dollar allocation to a multi-asset index of tokenized real-world assets, with four constituents: /
cash, short-dated Treasury bills, gold, and the S&P 500, a very common asset mix in traditional finance /
Each is its own ERC-20, held directly by the vault, starting at twenty-five percent each. /
For the demo, they're mock tokens we deployed on Monad testnet, and trades fill against an oracle-priced venue. /
A price feed moves gold and the S&P every ten seconds, with a small mean-reverting random walk, /
so you can see the vault size its trades against a market that moves. In production, Pyth feeds would provide actual pricing.

---

**3 · Public framework** (0:40–0:55)

Everything public is fixed at deployment, as immutables in the vault: /
the constituents, the schedule, the window around each anchor, the tolerances, /
and the hash of the methodology, so the rules can't change silently.

I sign in with Dynamic. The app checks the connected wallet against the vault's operator address, and only then does the index committee panel appear.

---

**4 · Commit** (0:55–1:20)

A rebalancing date is approaching:
As the index committee, I set target weights and seal them. /
The browser draws a random 32-byte salt and computes keccak of the chain ID, vault, epoch, weights and salt. /
Only that hash goes onchain. /
The preimage goes to a Chainlink CRE workflow as a secret. It never touches the chain.

---

**5 · The seed** (1:20–1:45)

The commit also fixes a seed block, five blocks ahead. /
Once that block is mined, the workflow has the vault store its hash. The value comes from the chain, so whoever triggers it gets the same answer. /
Now the execution offset from the anchor time is determined: window start, plus keccak of salt and seed, modulo the window length. /
The salt was locked before the block existed, so nobody could steer the result. /
And without the salt, nobody can compute it. The public only sees the window.

---

**6 · Execution** (1:45–2:20)

The workflow computes the time offset locally, and at that moment delivers an execute report. /
In one transaction, the vault re-hashes the preimage against the commitment, /
recomputes the time offset from the revealed salt, and rejects anything early or past the tolerance. /
Then it sizes the trades itself, from the venue's prices at that moment, /
There are variations in the exact rules index providers use in practice for effective new weights, but these can be incorporated in Whisprr at a later point. 
There's no technical path meanwhile for the operator to influence the outcome. 

---

**7 · Verification** (2:20–2:35)

Every reveal is re-checked off-chain: the browser recomputes the hash and the sealed time offset from the event, 

---

**8 · Stack and next steps** (2:35–2:55)
A word on the full stack and the next steps:

Solidity and Foundry, with thirty-one tests. /
The CRE workflow is TypeScript, running in Chainlink's simulator and writing real Monad testnet transactions. /
Dynamic for sign-in. /
Next: salt generation in an enclave or with MPC, and for scale spread execution across multiple confidential tranches with a compliant privacy protocol.
