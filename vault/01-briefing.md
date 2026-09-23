# 01 — Product briefing

## One paragraph

**runeDAO** is a small world of six regions held by three factions, where each faction is run by
an autonomous agent that signs and broadcasts its own transactions from its own wallet, spending
from a treasury it does not fully control. The agent decides; **the contract decides how far a
wrong decision can go.** A failed raid costs the faction real BNB testnet value that does not
vanish — it becomes the bounty on that region. A successful one raises the agent's reputation,
and reputation is what its spending ceiling is made of; failure lowers it, and the ceiling shrinks
with it, on chain, without anyone at a terminal intervening.

What is being demonstrated is not "an AI plays a game". It is **accountable autonomy**: an agent
that can be *measured* — what it considered, what it spent, what it rolled, what it cost, and what
happened to its authority afterwards — all from public chain state.

## Why it is shaped like this

Every "autonomous agent holds a wallet" demo dies on the same follow-up question:

> *What happens when the agent is wrong, confused, or compromised?*

The honest answer in most demos is "we turn it off". That cannot be audited, cannot be shown to a
judge, and does not scale past a demo. So the answer here is mechanical, and it is four gates plus
one feedback loop:

| gate | what it stops |
|---|---|
| `perActionCap` | one decision taking an unbounded amount |
| `dailyCap` (tracks **sum**, not count) | a hundred small spends slipping through |
| `minInterval` | draining the treasury inside a single block |
| `allowedTarget` (empty by default) | sending funds to an address the agent invented |
| reputation-scaled ceilings | an agent that keeps failing keeping full spending power |

Every one of them can be read from chain state or made to revert in front of an audience.

## Why the predecessor's two flaws are the design brief

The concept came from an earlier buildathon entry of mine, written for 0G Chain and deployed to
its Galileo testnet. Reading that code before porting anything turned up two things worth keeping
as the reason this repo exists:

1. **The treasury had no limits at all.** `executeAgentAction()` checked only
   `msg.sender == aiAgent`, then released *any* amount. No cap, no target allowlist, no interval.
   That is not autonomy, that is an unbussed button.
2. **The "AI proof" was decorative.** A field called `aiProofHash` accepted any `bytes32` and
   verified nothing. A claim that cannot fail a check is not evidence.

So this project does not carry those over. Item 1 became the five gates above; item 2 was deleted —
we prove only what actually gets checked, and say so in the UI rather than a footnote.

There is a third finding: the old commit-reveal dice let **the party doing the reveal also pick
the secret**, so outcomes were searchable offline before being revealed. Those dice were not
migrated either; see [02-architecture.md](02-architecture.md) for what replaced them and what that
replacement still does *not* protect against.

## The four questions the product answers mechanically

| question | answer | where it is enforced |
|---|---|---|
| Who may make this agent act? | its guardian — never the platform | `RuneRegistry.registerAgent`, `NotGuardian` |
| What may it spend? | up to a ceiling derived from its own track record | `RuneTreasury.spend`, `effectiveCaps` |
| What happens when it is wrong? | money leaves the treasury, reputation falls, the ceiling follows | `RuneWorld.resolve` → `recordOutcome` |
| How do I stop it? | two brakes, different owners | `suspend()` (guardian) and `delist()` (venue) |

## Who touches it

| | who | relationship to crypto |
|---|---|---|
| **The agent** | an EOA per faction, funded with ~0.001 testnet BNB | it signs and broadcasts its own transactions. The platform key never signs for it |
| **A guardian** (the faction owner) | deploys and configures the agent's limits | can freeze its own faction instantly; cannot raise the hard ceilings |
| **A viewer** (judge, or anyone) | opens the world page or `cast`s the contracts directly | needs no account, no permission, and no trust in our server |

## The demo, as designed

Five minutes, four beats. Each beat answers one of the four questions above, and each can be
repeated by the audience without our tooling.

| # | beat | what the audience sees |
|---|---|---|
| 1 | **A world that moved by itself** | the region map, built from `eth_getLogs`; owner and strength changes with the timestamps of agents acting unattended |
| 2 | **One decision, end to end** | transcript → `commit` hash on chain → future-block dice → `Action` event → the exact BNB that moved, and where it went |
| 3 | **The wrong choice costs** | a failed raid: treasury down, pool up, reputation down — then the *same agent* being refused at a ceiling it just lowered |
| 4 | **The brake, and its limits** | `suspend()` reverts live; `delist()` cannot be undone by the guardian; and out loud: what the venue still *cannot* do |

## Limits printed in the product, not in a footnote

This project does **not** prove:

- that an agent's decision was *smart* — it proves who made it, what it cost, and what the rules
  allowed;
- that any language model produced anything — **no LLM is in the decision path**, and narration is
  cosmetic;
- that the dice are unmanipulable by a block producer — a validator that mines the target block can
  nudge its own block hash slightly. That is enough for a game and not enough for real stakes, and
  the difference is stated rather than glossed;
- that an agent's identity corresponds to any real person or organisation;
- legal standing, or any form of institutional recognition, anywhere.

Naming our own limits is what makes the rest of the claims worth reading: a judge who tries to break
point four should find we already wrote it down.
