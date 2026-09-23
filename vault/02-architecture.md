# 02 — Architecture and the decisions behind it

## Three contracts, and who holds which key

| contract | holds | owner | what it deliberately cannot do |
|---|---|---|---|
| `RuneRegistry` | agents, capabilities, reputation | the venue (platform) | cannot register an agent on someone's behalf, cannot edit a faction's spending caps, cannot change reputation |
| `RuneTreasury` | all faction BNB, per-faction books | each faction's guardian (per policy) | cannot let one faction spend another's deposit; cannot raise its own hard ceilings |
| `RuneWorld` | the game state, region pools | the venue | is the **only** caller allowed to move reputation, and cannot mint money — only move what passed the gates |

Authority is wired in one direction and measured, not assumed:

```
Deploy → Registry ──(setWorld)──→ World ←──(REGISTRY, TREASURY immutable)── Treasury
                                      │
                                      └── spend() only accepted when msg.sender == Registry.world()
```

Because `RuneTreasury.spend()` reads `REGISTRY.world()` **on every call** rather than storing a
world address, the world can be replaced without touching the money: `setWorld(newWorld)` plus each
guardian re-allowlisting the new target. That is how the current world became the second contract
deployed at this address pair, with 0.0075 testnet BNB of faction cash left undisturbed
(`script/ReplaceWorld.s.sol`).

## The five gates on an agent's money

`RuneTreasury.spend(agent, target, amount, proofHash)` — called only by the world — evaluates in
this order, and each revert is a named custom error:

| # | gate | error | why the order matters |
|---|---|---|---|
| 1 | caller must be `world` | `OnlyWorld` | nothing else may move faction money, including the guardian |
| 2 | `proofHash` non-zero | `EmptyProof` | spending without a reference to a logged action is cash without a receipt |
| 3 | agent's guardian **is** the faction's guardian | `GuardianMismatch` | see below — this one was found by writing the test |
| 4 | faction not frozen | `FactionFrozenError` | the owner's instant brake |
| 5 | target on the allowlist | `TargetNotAllowed` | empty by default; an agent cannot pay an address it invented |
| 6 | `amount ≤ perActionCap × tier bonus` | `AbovePerActionCap` | the ceiling that follows reputation |
| 7 | `spentToday + amount ≤ dailyCap × tier bonus` | `AboveDailyCap` | tracks the **sum**, so many small spends do not slip |
| 8 | `now ≥ lastSpendAt + minInterval` | `TooSoon` | kills drain-in-one-block |
| 9 | `faction.balance ≥ amount` | `NotEnoughFunds` | per-faction book, not the contract total |

**The bug that gate 3 exists for.** `registerAgent(factionId, …)` accepts *any* `factionId`. Before
gate 3, an attacker registering their own agent under someone else's faction id got a world that
would happily spend that victim's treasury. Every cap and allowlist still passed — they were the
*victim's* caps. Nothing in the design review caught it; writing
`test_rejectCrossFactionAgentDrain` did. The lesson is recorded in [04](04-technical-reference.md).

**Per-faction accounting is not decoration.** The first draft checked `address(this).balance`, which
is the pooled total of every faction. That passes a unit test and fails reality: faction A could
spend faction B's deposit. `Faction.balance` was added, the contract's `receive()` was deleted
(unattributed transfers are rejected rather than becoming everyone's money), and
`test_oneFactionCannotSpendAnotherFactionDeposit` now pins it.

## The dice: why the old scheme was dropped

The predecessor's `RuneDice` was commit-reveal, which *sounds* right and isn't: the party revealing
was the same party who chose `secret`, subject only to `keccak(secret ‖ actionId) == ownCommitHash`.
You can search offline for a secret that produces a good number, then reveal only that one. The
`REVEAL_WINDOW = 250` also sat four blocks from the 256-block `blockhash()` limit.

Here the commitment binds to a block that **does not exist yet**:

```text
commit  : hash = keccak256(abi.encodePacked(secret, targetBlock, agent, nonce))    // targetBlock > now
resolve : seed = keccak256(abi.encodePacked(secret, blockhash(targetBlock)))
          roll = seed % 20 + 1
```

At commit time `blockhash(targetBlock)` is unknown to everyone, so no search over secrets can
target an outcome — the missing input is not the agent's to choose. `targetBlock` is capped
`block.number + 20` so the wait stays short and the hash stays readable.

What this still does not defend against, stated plainly: whoever mines `targetBlock` has some
influence over its own block hash. For a game with testnet money that is acceptable; for real
stakes it is not. Chainlink VRF v2 **is** present on chain 97 (coordinator `0x6A2AAd07…c82f`,
24,103 bytes of code) is the upgrade path behind the same interface, if that day comes.

## One open commit per agent, and why leaving is paid

`commit()` refuses a second open commitment (`CommitAlreadyOpen`). Without that, "commit, look at
the outcome, commit again" is just the old searchable-secret bug wearing a contract.

But a stuck commit must not brick an agent forever, so `abandon()` exists — allowed only after the
reveal window has closed (`RevealWindowOpen` before that), and **always charged as a failure**
through the same `recordOutcome(false)` path as a lost raid. Fleeing is legal; it costs reputation,
and reputation is what the spending ceiling is built from. An agent that rerolls until it likes the
answer is therefore still possible — it just pays for every discarded roll, which is the honest
shape of the trade-off.

The need for `abandon()` was not theoretical: a first version of the runner logged the secret only
at *resolve* time. A crash between the two transactions left a commit on chain whose opening value
was nowhere, locking that agent permanently. The runner now logs the secret at commit time and
replays any pending commitment at the start of each turn.

## Region dynamics

Six regions, each with `owner`, `strength` (0–40), and a `pool`. The rules are small on purpose:

| event | effect |
|---|---|
| raid **wins** | ownership flips to the attacker, `strength −6`, and the whole pool is **credited to the attacker's treasury** |
| raid **loses** | the raid's 0.0003 BNB cost is **not burned** — it is added to that region's pool, and `strength +1` |
| entrench | only the owner may; `strength += roll/4`, capped at 40; a small reputation gain, no punishment for a low roll |
| raid threshold | `11 + (strength − 20)/2`, clamped 4…19 — so the strongest region is still capturable and the weakest is not free |

Money that leaves a treasury on a failure therefore does not disappear: it becomes the prize that
makes the next attack rational. A judge can watch the same 0.0003 BNB move from a faction's book to
a region's pool to another faction's book.

## The agent runtime

`agent/rune-agent.mjs` is deliberately boring: read chain state → `decide()` (pure, deterministic,
no RNG of its own) → write a canonical transcript → `commit` → wait for the block → `resolve`. The
transcript records the reputation, tier, per-action cap, faction balance, gas, and every region the
agent saw — its hash goes on chain **before** the action exists.

Two things are policy, stated so they can be argued with:

- **No LLM in the decision path.** A model can supply flavour text; it never chooses an action, a
  cost, or a region. What we can prove on chain is rules and consequence, not the quality of a
  mind, and we do not claim the latter.
- **One region per tick, reserved locally.** All three agents read the same state in a tick and
  initially all three chose region 0 (measured), so the runner marks a region taken before the next
  agent decides — mirroring exactly what `RegionCooldownActive` would do on chain, not loosening it.
