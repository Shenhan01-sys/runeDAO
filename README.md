# runeDAO — autonomous agents with a treasury they cannot overspend

Indonesia Web3 Hackathon 2026 · track **AI Agents** · live on **BNB Smart Chain testnet (chainId 97)**.

One sentence: **AI agents each run their own on-chain treasury and act without a human, and the
contract — not our promise — is what limits how badly they may be wrong.**

Status, measured rather than asserted: 3 contracts deployed and read back from the chain, **81
tests passing**, and an unattended agent loop that has been signing and broadcasting its own
transactions since 23 Sep 2026. [`vault/03`](vault/03-evidence-and-limits.md) lists which claim
came from which command.

## Provenance — read this first, it is an eligibility question

The game structure comes from **RuneDAO**, my own entry for the *0G Bridge Buildathon by AKINDO*.
Those contracts were written 23 Aug 2026 and **are deployed and live on 0G's Galileo testnet**
(chainId 16602) — verified by `eth_getCode` on 22 Sep, not from old logs. That repo was never
published, so it has no public commit history.

**Nothing was copied from it.** What carried over is the idea; every line here was written during
the hackathon period, and the code below is what a review of that earlier code produced:

| | 0G version | here |
|---|---|---|
| Faction treasury | checked `msg.sender == agent`, then released **any** amount — no cap, no target list, no interval | five gates, each revertable in front of an audience |
| "AI proof" | `aiProofHash` accepted any `bytes32` and verified nothing | removed; we prove only what is actually checked |
| Dice | commit-reveal, but the revealing party also chose the secret → outcome searchable offline before reveal | commit to a block that **does not exist yet** (below) |
| Spend limit | static, set by the owner | scales with the agent's **reputation**, which the game moves both ways |
| Runtime | `bot/` and `shared/` empty; the only UI was a mock with randomised hashes | a real loop that broadcasts its own transactions |

Contract names differ on purpose (`RuneRegistry`/`RuneTreasury`, not the 0G names), and this
section is on page one rather than waiting to be asked. We do not claim the game concept is new;
we claim the **spending-constraint mechanism** is.

## The problem every "agent holds a wallet" demo dies on

> *What happens when the agent is wrong, confused, or compromised?*

"We turn it off" is not auditable. So the answer here is bytecode. `RuneTreasury.spend()` —
callable only by the game contract — evaluates:

| # | gate | error |
|---|---|---|
| 1 | caller must be the world | `OnlyWorld` |
| 2 | every spend references a logged action | `EmptyProof` |
| 3 | the agent's guardian **is** the faction's guardian | `GuardianMismatch` |
| 4 | faction not frozen by its owner | `FactionFrozenError` |
| 5 | target on a per-faction allowlist, **empty by default** | `TargetNotAllowed` |
| 6 | `amount ≤ perActionCap × reputation bonus` | `AbovePerActionCap` |
| 7 | `spentToday + amount ≤ dailyCap × bonus` — the **sum**, not the count | `AboveDailyCap` |
| 8 | `minInterval` between spends | `TooSoon` |
| 9 | the **faction's own** balance, not the contract total | `NotEnoughFunds` |

And the feedback loop that makes it more than a settings screen: only `RuneWorld` may move
reputation (`OnlyWorld` refuses guardian and platform alike). Failure lowers it; the ceiling is
computed from it. **An agent that keeps losing shrinks its own budget on chain, with no one at a
keyboard.** The ceiling gain is capped (`MAX_TIER_BONUS = 3`) so a senior agent cannot earn
unlimited funds either.

Two brakes, two owners: `suspend()` belongs to the agent's guardian; `delist()` belongs to the
venue and cannot be undone by the guardian — and neither erases what already happened on chain.

## Dice: why the old scheme was not ported

A reveal whose party also picks the secret is a search problem, not a commitment. Here the
commitment binds to a block that had not been mined at commit time:

```solidity
commit  : hash = keccak256(abi.encodePacked(secret, targetBlock, agent, nonce))  // targetBlock > now
resolve : roll = keccak256(abi.encodePacked(secret, blockhash(targetBlock))) % 20 + 1
```

The input the agent cannot yet know is the one that decides the outcome, so no offline search over
secrets can target a result. Stated limit, not hidden: whoever mines `targetBlock` retains a small
influence over its own block hash. Enough for a game; not enough for real stakes. Chainlink VRF v2
is confirmed present on chain 97 (`0x6A2AAd07…c82f`) as the upgrade behind the same interface.

`abandon()` exists because a stuck commitment would otherwise brick an agent forever — and it is
**charged as a failure**, so "reroll until I like it" costs reputation, which costs budget.

## Run it

```bash
npm install                 # @openzeppelin/contracts 5.1.0 + viem 2.56.5, this repo's own
forge build --deny warnings
forge test                  # 81 passed (26 registry · 25 treasury · 30 world)

node tools/make-env.mjs     # fresh burner testnet keys (never prints a value)
node tools/record-addresses.mjs   # writes deployed addresses, verified against the chain

npm run page                # regenerate web/index.html (self-contained snapshot of the chain)
npm run world               # read-only: regions, reputations, and each agent's next decision
npm run readback            # asserts the authority chain from live state on chain 97
npm run agent:once          # one unattended turn: 3 agents, 6 transactions
npm run agent               # keep the world moving (TICK_SECONDS, default 420)
```

Layout: `contracts/` (3) · `test/` (3 files, 81 tests) · `script/` (Deploy, Seed, Fund,
ReplaceWorld, Readback) · `agent/` (pure decision policy + runner + terminal world view) ·
`tools/` (env, address bookkeeping, page builder) · `web/` (the generated world page) ·
`vault/` (reasoning, evidence, limits).

`web/index.html` is committed on purpose: it is a **snapshot generated from chain data**, not a
live feed, so opening it over `file://` shows exactly what was on chain at the block printed at
the top of the page. That also means the page cannot quietly disagree with a demo that was
recorded earlier.

## What this project does **not** prove

Printed up front, because that is what makes the rest of the claims worth reading.

- **Not** that an agent's decision was wise. Proven: who may act, within what limit, at what cost.
- **Not** that any language model produced anything. **No LLM is in the decision path**; narration
  is cosmetic and unbuilt.
- **Not** unmanipulable randomness — see the validator caveat above.
- **Not** that an address corresponds to a person or organisation.
- **Not** verified contract source on the block explorer: BscScan's V1 verification is deprecated
  and V2 is paid for BSC, so verification here is by RPC and `cast call`, and we say so.
- **Not** a market, users, or revenue. It is a mechanism, demonstrated on testnet.

## Context notes

[`vault/`](vault/README.md) — why the product is shaped this way, what has been **run** versus
merely claimed, measured chain parameters, the toolchain traps already paid for, and the order of
remaining work. Nothing there is needed to build; it is needed to judge what is true.
