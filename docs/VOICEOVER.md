# Whisprr: voice-over

About 2:30 at a calm pace. One block per scene; `/` marks a short pause.

---

**1 · The problem** (0:00–0:20)

Index funds rebalance on a published schedule, with predictable trades. /
Traders know what's coming, and they get there first. /
Research puts the cost at around twenty basis points on every dollar traded. /
Onchain, it's worse: every pending trade is visible.

---

**2 · The idea** (0:20–0:40)

Whisprr keeps the rules public, and the specifics sealed. /
The methodology and the schedule are fixed at deployment, and the methodology is fingerprinted onchain. /
What stays secret until execution is the target weights, and the exact second the rebalance runs. /
Nobody chooses that second. Not the market, and not the operator.

---

**3 · Commit** (0:40–1:05)

As the index committee, I set new weights. /
The commit seals the next scheduled rebalance. I can't pick the date. /
Only a hash goes onchain: the weights, plus a random salt. /
The plan itself goes to a Chainlink CRE workflow, as a secret.

---

**4 · The sealed second** (1:05–1:30)

A few blocks later, the workflow records a Monad block hash: a seed nobody could know when I committed. /
The execution second is now fixed: the hash of the salt and the seed, inside the window. /
The public sees only the window. /
I can see the second, but I can't change it. And there's no execute button, for anyone.

---

**5 · Execution** (1:30–2:00)

At that second, the keeper delivers the reveal. /
In one transaction, the vault checks the hash, recomputes the second, and sizes the trades from live prices, so it lands on target however the market moved. /
My browser re-verifies both: the hash matches, and execution landed at the sealed second. /
A missed second can't execute late. It defaults, publicly.

---

**6 · Under the hood** (2:00–2:25)

Monad gives us fast blocks, and the seed. /
Chainlink CRE is the only executor. Today it runs in Chainlink's simulator, and writes real Monad testnet transactions. /
Dynamic handles sign-in, and an Envio indexer re-verifies every rebalance independently.

---

**7 · Close** (2:25–2:35)

Next: generating the salt inside an enclave or with MPC, so even the operator can't see the second, /
and splitting rebalances into confidential tranches with Unlink. /
Whisprr. Public rules, sealed rebalances.
