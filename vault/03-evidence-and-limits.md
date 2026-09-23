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
| The dice are the documented formula | `test_worldRollsMatchTheDocumentedFormula` recomputes `keccak(secret ‖ blockhash(target)) % 20 + 1` | matches the emitted `roll` |
| Cross-faction spend is refused | `test_rejectCrossFactionAgentDrain` | reverts `GuardianMismatch` |
| One faction cannot spend another's deposit | `test_oneFactionCannotSpendAnotherFactionDeposit` | reverts `NotEnoughFunds` while the contract holds 1 BNB of someone else's money |
| Gas is measured, not assumed | `eth_gasPrice` on chain 97 | **0.1 gwei** (`100000000` wei) → one full action ≈ **0.000037 BNB** |
| The world can be replaced without touching the money | `script/ReplaceWorld.s.sol` | treasury held 0.0075 BNB across the swap; second world live at the addresses in [04](04-technical-reference.md) |

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
| "reputation visibly tightens an agent's budget" | true in unit tests, **not yet observable live**: the tier bonus saturates at 3, so agent C at 380 still gets the full multiplier. The ceiling only bites below reputation 300. Either run longer or present the unit test, not a live screenshot |
| "the world is unmanipulable" | a block producer can nudge the target block hash; VRF remains the upgrade, unimplemented |
| "any LLM verified anything" | none is in the decision path |
| "the frontend shows the world" | does not exist yet; `show-world.mjs` is a terminal view reading the same contract |
| "agents sustain themselves" | faction funds recirculate through pools, but the platform top-up wallet is at 0.000757 BNB; the loop will eventually stop for money, and a faucet claim needs a human (bot-check, 12 h cooldown) |

## Honest numbers we should not round

- Deploy of the first world + setup: **37 transactions**, ~8.60M gas estimated by forge.
- Total testnet BNB consumed so far is under 0.01 — small enough that it must not be presented as
  a cost analysis of anything; these are testnet figures.
- `perActionCap` configured by guardians (0.0005) is *not* the enforced ceiling: the effective
  number is `× (100 + min(tier,3)·20)%`, i.e. **0.0008** at tier ≥ 3. `show-world` prints the
  effective value; quote that one.
