# 03 — Evidence and limits

The rule for this file: **every number came from a command that was run**, and "not tested" is
written as "not tested" instead of skipped. Re-measure before quoting anything below in the
submission — these are snapshots with a timestamp, not constants.

## Proven

| claim | how it is reproducible | measured |
|---|---|---|
| Contracts run on BSC testnet | `npm run readback` (reads `registry.world()`, `treasury.REGISTRY()`, `world.REGISTRY/TREASURY()` from chain) | all four equalities `true`, chainId 97 |
| Unit coverage of the rules | `forge test` | **81 passed / 0 failed** — 26 registry, 25 treasury, 30 world |
| Agents broadcast their own transactions | `npm run agent:once` from three agent EOAs, platform key uninvolved | 6 transactions, one per commit/resolve |
| Reputation moves **down** on chain | same run; `show-world` reads `getAgent` | agent C: 500 → **460**, tier 5 → 4 after its first failure |
| A failed raid becomes a bounty | `show-world` | region 2 pool `0` → **0.0003 BNB**, strength 20 → 21, owner still neutral |
| A won raid pays the attacker, not the loser | `test_...` + on chain | regions 0 and 1 changed owner to factions 2 and 1; their pools returned to 0 |
| The dice are the documented formula | `test_worldRollsMatchTheDocumentedFormula` recomputes `keccak(secret ‖ blockhash(target)) % 20 + 1` | matches the emitted `roll`; 23 live rolls so far: 12, 18, 4, 14, 7, 2, 16, 15, 3, 2, 12, 13, 2, 13, 13, 6, 10, 8, 2, 5, … |
| **Both** action types actually reach the chain | `agent/history/actions.jsonl` + `npm run world` | 21 RAID and **2 ENTRENCH**; both entrenched rolls raised strength as the rule says (roll 8 → +2 on region 0; roll 13 → +3 on region 3). The first 20 world actions were **100% RAID, 0% ENTRENCH** — a policy ordering bug, fixed by defending weak owned regions first (`DEFEND_BELOW = 10`); see the note below on how we know |
| Reputation keeps falling on real failures | `npm run world` reads `getAgent` | agent C: 500 → 460 → 380 → **350**, tier 5 → 4 → **3**, 5 failures in 7 actions |
| Cross-faction spend is refused | `test_rejectCrossFactionAgentDrain` | reverts `GuardianMismatch` |
| One faction cannot spend another's deposit | `test_oneFactionCannotSpendAnotherFactionDeposit` | reverts `NotEnoughFunds` while the contract holds 1 BNB of someone else's money |
| Gas is measured, not assumed | `eth_gasPrice` on chain 97 | **0.1 gwei** (`100000000` wei) → one full action ≈ **0.000037 BNB** |
| **Reputation tightens an agent's real budget, live** | `npm run world` reads `getAgent` + `effectiveCaps` from chain | agent C: reputation **260 / tier 2** → per-action ceiling **0.0007 BNB**, while A (605 / tier 6) and B (560 / tier 5) get **0.0008**. 12.5% smaller, caused only by 8 failures in 12 actions — this replaces the earlier "not yet observable" row |
| Stuck commitments are escaped, and *detected* | `agent/history/actions.jsonl` + `stuckReport()` | 2 `abandon()` transactions mined; the streak metric reports `A:3x B:3x C:9x`, the very failures the old `stuck` counter reported as **0** |
| The world can be replaced without touching the money | `script/ReplaceWorld.s.sol` | treasury held 0.0075 BNB across the swap; second world live at the addresses in [04](04-technical-reference.md) |

## Emergent behaviour we measured and did not tune away

**Capturing a region weakens it, and only failure strengthens it.** A win applies `strength − 6`;
a lost raid applies `strength + 1`. Contested regions therefore slide toward the floor: Vhal'Mor
went 20 → 0 and its raid threshold 11 → 4 (≈85% success), Abu Kelabu reached 1. Left unfixed on
purpose: repairing the rule means deploying a new world, and that erases the ~23 unattended actions
that are the actual demo material for beat 1. It is recorded here as measured behaviour, and the
agent-side `DEFEND_BELOW` is what currently damps it.

**A faction whose treasury hits zero cannot climb back.** Money does not leave the system — a failed
raid's cost becomes the region's pool, and the next winner collects it — but a broke faction can no
longer pay an entry cost, so it can neither raid nor entrench. It abstains honestly (visible in the
ledger) and has to be topped up from outside (`script/Fund.s.sol`). Any v2 of the rules should want
either a recovery route or a lower entry cost; this is a known hole, not an unnoticed one.

### Live world snapshot — 23 Sep 2026, 03:15 UTC, from `npm run world`

| region | owner | strength | threshold | pool |
|---|---|---|---|---|
| 0 Vhal'Mor | faction 2 | 8 | 5 | 0 |
| 1 Abu Kelabu | faction 1 | 8 | 5 | 0 |
| 2 Rawa Gema | neutral | 21 | 11 | 0.0003 |
| 3 Pintu Garam | faction 1 | 15 | 9 | 0.0003 |
| 4 Tulang Raja | neutral | 21 | 11 | 0.0003 |
| 5 Simpul Asing | neutral | 21 | 11 | 0.0003 |

| agent | reputation | tier | actions | failures | treasury |
|---|---|---|---|---|---|
| A | 575 | 5 | 3 | 0 | 0.0021 |
| B | 510 | 5 | 3 | 1 | 0.0021 |
| C | 380 | 3 | 3 | 3 | 0.0021 |

Nine actions completed unattended: rolls **12, 18, 4, 14, 7, 2, 16, 15, 3** — five wins, four
losses. The local ledger holds 28 records; 9 of those are `error` entries from *before* 02:59 UTC
(a null wallet client and a stale-block commit rejection), and the loop restarted at 03:01:42 UTC
has produced no errors since. Say it that way rather than "0 errors": the earlier ones really
happened and are in the file.

## Not proven — do not write these as claims

| tempting claim | actual state |
|---|---|
| "contract source verified on BscScan" | **not done and probably not possible here**: explorer source-verification is deprecated on V1 and paid on V2 for BSC. Verification is by RPC + `cast call`, and the README says so |
| "address resolves on `testnet.bscscan.com`" | unconfirmed for these contracts (that check needs a browser; the explorer returns 403 to our tooling). **Hard submission requirement** — confirm before submitting |
| ~~"reputation visibly tightens an agent's budget"~~ | **now proven live** (see Proven, tier 2 → 0.0007 vs tier 6 → 0.0008). Kept here as history: it was false when written, and the reason it was false is that `MAX_TIER_BONUS = 3` makes every tier ≥ 3 identical, so only dropping *below* 300 reputation changes anything |
| "a faction can be throttled into stillness" | true and correct behaviour: after `Fund.s.sol`, all three agents hit the **daily** ceiling and abstained with explicit reasons (A 0.0031/0.0032, B 0.0032/0.0032, C 0.0031/**0.0028**). It opens again on the UTC day boundary, unaided |
| "the world is unmanipulable" | a block producer can nudge the target block hash; VRF remains the upgrade, unimplemented |
| "any LLM verified anything" | none is in the decision path |
| "the frontend shows the world" | does not exist yet; `show-world.mjs` is a terminal view reading the same contract |
| "agents sustain themselves" | faction funds recirculate through pools, but a faction that hits zero has no in-contract route back — it abstains until `script/Fund.s.sol` is run by someone. Funded to 0.003/faction on 23 Sep ~03:45 UTC, which is roughly a day of the current action rate, **not** self-sustaining |

## Honest numbers we should not round

- Deploy of the first world + setup: **37 transactions**, ~8.60M gas estimated by forge.
- Total testnet BNB consumed so far is under 0.01 — small enough that it must not be presented as
  a cost analysis of anything; these are testnet figures.
- `perActionCap` configured by guardians (0.0005) is *not* the enforced ceiling: the effective
  number is `× (100 + min(tier,3)·20)%`, i.e. **0.0008** at tier ≥ 3. `show-world` prints the
  effective value; quote that one.
