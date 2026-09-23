# 05 — Status and order of work

**Last updated:** 23 September 2026, 03:20 UTC.
**Submission closes:** 30 September 2026, 23:59 WIB (= 30 Sep 16:59 UTC) → **7 days**.
Finalists 14 Oct · Demo Day 31 Oct.

## Where things stand

| layer | state | evidence |
|---|---|---|
| Contracts | ✅ three live on chain 97 | `npm run readback` |
| Rules under test | ✅ **81 passed / 0 failed** | `forge test` |
| Autonomous runtime | ✅ running; 9 completed actions unattended as of this snapshot | `agent/history/actions.jsonl`, `npm run world` |
| World seeded, factions funded, agents gas-red | ✅ | `script/Deploy.s.sol`, `Seed.s.sol`, `Fund.s.sol` |
| Public repo | this repository | — |
| Frontend (world viewer) | ❌ not started | the terminal view is the spec for it |
| Demo video ≤5 min | ❌ not started | — |
| Submission text (problem/solution/detail) | ❌ not started | — |
| Registration on the event portal | ❌ **not done — submission is invalid without it** | — |
| Contract address resolvable in the block explorer | ⚠️ unconfirmed from this machine (explorer returns 403 to our tooling; needs a browser) | hard requirement |

## Order, and why this order

1. **Register on the event portal.** It gates everything else and takes ten minutes. Until it is
   done, every other day of work is at risk of being unable to be handed in.
2. **Confirm the address resolves on the testnet explorer.** One browser check. If it fails for a
   reason we cannot see from here, we need to know this week, not on 29 September.
3. **Keep the agents running.** This is the only task where elapsed calendar time is the product:
   a world with nine actions looks like a demo, a world with a few hundred actions spread over
   five days looks like a system. Nothing else we can build substitutes for it.
   Watch two failure modes: the platform top-up wallet (0.000757 BNB at last check) and faction
   treasuries draining to the point where agents honestly abstain.
4. **World viewer, built from `eth_getLogs`.** Read-only, no wallet, no framework. It must render
   the same numbers `show-world` prints, from the same contracts — and it must print the limits in
   [03](03-evidence-and-limits.md) on the page, not in a footnote. This is the artefact that makes
   beat 1 of the demo watchable by anyone.
5. **One scripted live revert for the demo.** Show an agent refused at a ceiling it lowered itself,
   and `suspend()` / `delist()` reverting in front of the audience.
6. **Video ≤5 minutes + submission fields.** Problem statement, solution, markdown detail with a
   diagram, repo link, contract addresses.

## Known gaps that are choices, not oversights

- **Six regions, two actions, three factions.** Bigger would not be provable in the time left. The
  claim is about the constraint mechanism, not the size of the world.
- **No LLM in the decision path.** Deliberate. See [02](02-architecture.md).
- **Commit-reveal instead of VRF.** Cheaper, no LINK subscription, and it removes the flaw the
  predecessor had. The residual (a block producer can nudge its own block hash) is documented
  rather than sold away.
- **Testnet only.** The rules accept it; the numbers stay honest and no real value is at risk.

## Things that must not be said in the submission

From [03](03-evidence-and-limits.md), repeated here because it is the easiest place to drift:

- not "provably fair" — say *unpickable by the revealing party* and name the validator caveat;
- not "verified source on BscScan" — it is verified by RPC/`cast`, and the explorer source check
  may never be available to us;
- not "AI-driven decisions" — decisions are deterministic policy; nothing proves model provenance;
- not "reputation visibly tightened an agent's budget" — that coupling is proven by unit test, and
  at the current live reputations the bonus is still saturated;
- no claim about a market, users, or revenue — none of that exists yet.
