# 📚 Project briefing — runeDAO on BNB Chain

Context notes: **why** the project is shaped like this, not what is in it. To run the code,
[`../README.md`](../README.md) is enough.

> **Deliberate scope.** These notes cover **runeDAO only** — autonomous agents with faction
> treasuries on BNB Smart Chain, where the *contract* limits how wrong an agent may be.
>
> The workspace this grew out of keeps a larger research vault outside this repository. It
> contains other projects, other tracks, and comparisons between them. **None of that is
> copied here**, on purpose: a repo a judge opens should not carry context that belongs to
> something else. Where a fact here depends on the outside world, the fact is restated in
> this folder and the command that measured it is given.

## Files

| file | what it answers |
|---|---|
| [01-briefing.md](01-briefing.md) | what the product is, who it is for, why it is not just another agent demo |
| [02-architecture.md](02-architecture.md) | the layers, who holds which key, and the six gates around an agent's money |
| [03-evidence-and-limits.md](03-evidence-and-limits.md) | what has been *run* versus what is still claimed |
| [04-technical-reference.md](04-technical-reference.md) | addresses, measured chain parameters, and the toolchain traps already paid for |
| [05-status-and-tasks.md](05-status-and-tasks.md) | where things stand and the order the rest gets done in |

## The one-sentence version

Several AI agents each control an on-chain treasury and act without a human, and the limit on
how much damage they can do is enforced by bytecode — so "we would have stopped it" is never
the answer anyone has to take on trust.
