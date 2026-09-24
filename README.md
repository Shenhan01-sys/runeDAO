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

**Two numbers in the rules were chosen from measurement, not taste.** The winner takes **60%** of
a region's bounty and 40% stays as a standing prize — with a 100% payout, the region you just took
has a prize of zero, every later attack is −EV, and the world freezes (it did, on 24 Sep, the
moment our agents started doing the arithmetic honestly). And capture lowers strength but never
below 10 — with no floor, a region that keeps changing hands slides to an 85%-success shooting
gallery (Vhal'Mor: 20 → 0).

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

**Build hygiene, stated accurately rather than aspirationally.** `forge build` compiles clean but
reports **38 `unsafe-typecast` lint warnings**, almost all `uint64(block.timestamp)` — truncating a
256-bit timestamp to 64 bits, which is safe until the year 2554 and is exactly the sort of cast the
lint exists to make someone think about. `forge build --deny warnings` therefore **fails today**;
the contracts that matter carry explicit `forge-lint: disable-next-line` markers where the bound is
proved in code. If you see a README promising `--deny warnings` here, it was written before the
test suite grew — that is a documentation bug, not a passing build.

`abandon()` exists because a stuck commitment would otherwise brick an agent forever — and it is
**charged as a failure**, so "reroll until I like it" costs reputation, which costs budget.

## How to play, in plain language

[`HOW-TO-PLAY.md`](HOW-TO-PLAY.md) is written for someone who has never seen this project: what the
game is, what you do in your first ten minutes, the rules on one screen, and an explicit answer to
"so what is the winning condition?" — which is: there isn't one, on purpose. The section below is
the same flow written for an engineer, with function signatures.

## How a player joins, in order

A player is a **guardian**. They never move a piece; they equip an agent and bound it. Real
functions, real numbers from the live deployment:

| # | what the player does | call | why it is this way |
|---|---|---|---|
| 1 | make two wallets | `node tools/make-env.mjs` | a **guardian** (owner) and an **agent** (actor). One key can never be both — otherwise "the agent holds its own wallet" is decoration |
| 2 | fund both with testnet BNB | faucet | the agent must pay for its own transactions. If the platform paid, the agent would not be autonomous, just remote-controlled |
| 3 | claim a faction | `createFaction(4)` | open to anyone. No permission from the venue, no whitelist |
| 4 | set its own spending limits | `setPolicy(4, 0.0005e18, 0.002e18, 60)` | per-action, per-day (UTC), and a minimum gap between spends. Hard ceilings: 0.01 and 0.05 BNB |
| 5 | name who may receive its money | `setTarget(4, world, true)` | the allowlist starts **empty**: an agent cannot pay an address it invented |
| 6 | register the agent | `registerAgent(4, agentAddr, "my-runner")` | `msg.sender` becomes the guardian; the venue cannot register on anyone's behalf |
| 7 | grant what it may do | `setCapability(agent, keccak256("RAID"), true)` | capabilities default to false. Nothing is allowed implicitly |
| 8 | **deposit** | `deposit{value: 0.003e18}(4)` | the war chest. Raid costs 0.0003, entrench 0.0001 |
| 9 | step back | `npm run agent` | the agent now commits to a future block, waits, reveals, and lives with the result |
| 10 | **withdraw** | `withdraw(4, amount)` | the exit door. Guardian-only; **works even while the faction is frozen**, because a brake that also locks the owner's money is a hostage, not a brake |

Money in and money out is the whole point of step 10: without it the flow is a corridor with no
door, and nobody should deposit into something like that.

**What the player cannot do:** spend the faction's money themselves (only the world contract can,
and only through all nine gates), raise anything above the hard ceilings, or inflate their agent's
reputation — `recordOutcome` accepts exactly one caller, the game.

## Run it

```bash
npm install                 # @openzeppelin/contracts 5.1.0 + viem 2.56.5, this repo's own
forge build                 # compiles; see the lint note below
forge test                  # 89 passed, 0 failed (26 registry · 33 treasury · 30 world)
npm run test:policy         # 9 passed — the decision function is not covered by the Solidity tests

node tools/make-env.mjs     # fresh burner testnet keys (never prints a value)
node tools/record-addresses.mjs   # writes deployed addresses, verified against the chain

npm run page                # regenerate web/index.html (self-contained snapshot of the chain)
npm run world               # read-only: regions, reputations, and each agent's next decision
npm run readback            # asserts the authority chain from live state on chain 97
npm run agent:once          # one unattended turn: 3 agents, 6 transactions
npm run agent               # keep the world moving (TICK_SECONDS, default 420)
npm run health              # is it actually still working? exit 1 if the loop died or went silent
npm run lint:docs           # fences, dead links, stale numbers, banned claims
```

`npm run test:policy` exists because the Solidity suite can prove the contract enforces its
rules and still say nothing about whether the thing reading those rules is sensible. Two real
bugs lived in that gap: ENTRENCH was never reachable for the first 20 actions, and the agent
attacked targets whose expected value was negative because the number I called a "score" was
not an expected value. Both suites are mutation-checked: break `raidEV` on purpose and the
policy tests fail — a test that passes on broken code is the thing we are trying to remove.

`npm run health` exists because the loop stopped three times in two days and **nothing reported
it**: a dead process leaves the repo green and the tests passing while the one thing we cannot buy
back — unattended history — silently stops accumulating. It checks two things (live lock PID, and
ledger freshness within 4 ticks) and exits non-zero, so it can be wired to anything that runs
periodically. It does not run itself: an alarm nobody schedules is a rumour.

`npm run lint:docs` checks the things a compiler cannot see: unbalanced code fences (one of mine
swallowed a whole paragraph into a code block on GitHub while looking fine in a terminal), dead
relative links, `npm run` names that do not exist in `package.json`, numbers that drifted out of
date, and claims we decided not to make. It was written after the third doc-number correction of
the week, on the theory that a rule that runs is worth more than an intention.

Layout: `contracts/` (3) · `test/` (89 tests — see **Run it** for the authoritative count,
which is why none is repeated here) · `script/` (Deploy, Seed, Fund, ReplaceWorld, Readback) ·
`agent/` (pure decision policy + runner + terminal world view) · `tools/` (env, address
bookkeeping, page builder, loop health) · `web/` (the generated world page) ·
`HOW-TO-PLAY.md` (plain-language guide) · `vault/` (reasoning, evidence, limits).

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
