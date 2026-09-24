# 04 — Technical reference

## Deployment (BSC testnet, chainId 97)

| item | value |
|---|---|
| `RuneRegistry` | `0x56bf7e4ae3dea386c5e929be40c1bbac7013e7ae` (4,815 B code) |
| `RuneTreasury` | `0x94a03650e578e2553a1d74e4ea24469228df2209` (5,920 B) |
| `RuneWorld` **season 2** (current) | `0xd239713b250048763Ef9AE41A787b328F2f84104` (8,162 B) |
| `RuneWorld` season 1 (archive, read-only) | `0xf83F618C474e1ec36a4D6E13f9B16E54D81fE600` — 63 unattended actions live here permanently; `0x5D8bdA7c…` is the world before that |
| `RuneWorld` season 0 (archive) | `0x5D8bdA7cB2B40834a2D0D576Ef0cD64953Be0b3A` — replaced before the reputation loop ever ran |
| Platform owner / deployer | `0xAEc63F6cEbBfacdC3516992b6ec396147c9c8361` |
| Guardians A/B/C | `0x4e667dB4…93E3` · `0x4cc46460…2B56` · `0x6dEA871B…2442` |
| Agents A/B/C | `0x441500a5…aF79` · `0x81Cefc48…d318` · `0x5863d8c0…82b82C` |

Private keys live in `.env` (git-ignored) and are **testnet burners**, never to be reused anywhere
else. The deployer key on this development machine is deliberately shared with another hackathon
entry of mine; `--fresh-deployer` separates them for any new deployment. Regenerate on a new machine with `node tools/make-env.mjs --fresh-deployer` (idempotent: keys
already present are preserved, and no key value is ever printed). Recorded deployed addresses
with `node tools/record-addresses.mjs`, which verifies bytecode on chain before writing.

## Chain parameters, measured — not copied from docs

| thing | value | how |
|---|---|---|
| `eth_gasPrice` on 97 | `0x5f5e100` = 100,000,000 wei = **0.1 gwei** | `eth_gasPrice` |
| one full agent action | ≈ **0.000037 BNB** (2 txs, ~370k gas) | arithmetic on the above |
| Chainlink VRF v2 coordinator (97) | `0x6A2AAd07396B36Fe02a22b33cf443582f682c82f`, 24,103 B code | `eth_getCode` |
| VRF v2.5 coordinator / wrapper (97) | `0xDA3b641D438362C440Ac5458c57e00a712b66700` / `0x471506e6ADED0b9811D05B8cAc8Db25eE839Ac94` | `eth_getCode` |
| LINK on 97 | `0x84b9B910527Ad5C03A9Ca831909E21e236EA7b06`, 5,573 B | `eth_getCode` |
| ERC-8004 registries | Identity & Reputation live on **97 and 56** (130 B proxies); **no ValidationRegistry** | `eth_getCode` both chains |

The VRF/8004 rows are *not used by this project yet*. They are recorded because the obvious
objection — "you could not have done this on BNB" — is false, and the accurate answer is "the
primitives exist, we chose the cheaper one, and here is what it does not buy us"
([02](02-architecture.md)).

## Which functions are actually on chain

`node tools/probe-surface.mjs` asks the deployed bytecode, with a fictional
`CONTROL_DOES_NOT_EXIST` as the ruler. Measured 24 Sep on season 2:

| | on chain |
|---|---|
| `MIN_STRENGTH`, `LOOT_SHARE_PERCENT`, `abandon` | **yes** |
| `withdraw` on the treasury | **no** — the treasury was deliberately reused (see below) |

The treasury was *not* redeployed on purpose: it holds 0.0055 BNB of faction cash that would
otherwise be stranded, and reusing it also keeps every faction's guardian/allowlist/policy as
the guardians themselves set them. The price of that choice is that the exit door still exists
only in source and tests. Stating that is the point of this file.


```bash
npm install                      # @openzeppelin/contracts 5.1.0 + viem 2.56.5, this repo's own
forge build            # clean compile; 38 unsafe-typecast lint notes remain (see README)
forge test                       # 81 passed
npm run world                    # read-only: regions, reputations, next decision per agent
npm run readback                 # forge script; asserts the authority chain from live state
npm run agent:once               # one unattended turn, three agents, six transactions
npm run agent                    # loop (TICK_SECONDS, default 420)
```

Scripts that **move money** (all need `--broadcast`): `Deploy.s.sol` (first bring-up),
`Seed.s.sol` (idempotent region seeding), `Fund.s.sol` (agent gas + faction cash),
`ReplaceWorld.s.sol` (swap the world without touching treasuries).

## Toolchain traps already paid for — do not pay twice

1. **`Stack too deep` on the 11-argument `Action` event.** Fixed with `viaIR = true` in *both*
   profiles (default and `fork`), so the bytecode tested equals the bytecode deployed. The
   alternative — trimming the event — moves the cost onto every reader of the log.
2. **`vm.prank()` / `vm.expectRevert()` are consumed by the *next external call*, including view
   calls.** Writing `world.MAX_TARGET_HORIZON()` inside an argument list after
   `vm.expectRevert(…)` eats the expectation and the test passes for the wrong reason — or fails
   with a confusing error. Hoist constants into locals first. This bit the test suite three times.
3. **OpenZeppelin 5 reverts with custom errors, not strings.** `expectRevert("Ownable: caller is
   not the owner")` fails; use
   `abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)`.
4. **`RuneRegistry.Agent` / structs from another contract**: access public constants through the
   instance (`registry.MAX_REPUTATION()`), not `Registry.MAX_REPUTATION()`, from a non-derived
   contract.
5. **Solidity string literals reject em dashes** (`—`) — the compiler reports *Invalid character in
   string*. Keep ASCII inside strings; em dashes are fine in comments.
6. **PowerShell `Set-Content -Encoding UTF8` writes a BOM** that breaks the Solidity parser at
   line 1. Use `[IO.File]::WriteAllText($p,$t,(New-Object System.Text.UTF8Encoding($false)))`.
7. **`abi.encodePacked` is not string concatenation.** The runner's commit hash must be
   `encodePacked(["bytes32","uint32","address","uint256"], […])`; a hex-string concat produced a
   hash the contract could never match.
8. **viem has no `waitForBlockNumber`.** Poll `getBlockNumber()`.
9. **`effectiveCaps()` returns a tuple** — viem hands back one array. Destructuring it into two
   slots silently reads the pair as the first value and `undefined` as the second.
10. **Public RPC endpoints fail in ways that look like contract bugs.** Observed on 23 Sep from
    this machine: `bsc-testnet-rpc.publicnode.com` → HTTP 520 mid-script; `bsc-testnet.drpc.org` →
    408 "Request timeout on the free plan"; stale heads caused `TargetBlockNotFuture` reverts.
    any live endpoint from the `[rpc_endpoints]` table works; the runner re-reads the head
    and retries once.
11. **`run-latest.json` `transactionIndex` is not a reliable ordering key** — several entries share
    a value, which once made a readback script report "1 CREATE". Filter
    `transactionType == "CREATE"` and keep file order.
12. **`cast balance --unit bnb` is invalid** (units are wei/gwei/ether/…); it fails silently under
    `2>nul`. Use `--unit ether` or JSON-RPC.

13. **`node --check` does not catch ESM/CJS mismatches.** The single-instance lock was written with
    `require("node:fs")` inside a `.mjs` file; it passed `node --check` cleanly and would only have
    failed at *runtime, on exit* — the one path that never runs in a smoke test. Static imports
    only in `.mjs`, and exercise the exit path (Ctrl+C / normal end), not just the happy loop.
14. **Only one agent loop per machine.** Two processes sharing the same agent keys collide on
    nonces, which is the most likely source of the dangling commitments above. `agent/rune-agent.lock`
    holds the live PID and a second instance refuses with an explanation; a stale lock (dead PID) is
    taken over automatically, and the lock file is git-ignored because it is machine state.
    Verified: second instance prints the refusal and exits non-zero.

15. **Never use `os.kill(pid, 0)` as a liveness probe on Windows.** Python documents that on
    Windows the signal is handed to `TerminateProcess`, so a "successful" probe *kills* the target.
    Measured here: it raised `OSError` and the process survived — but surviving was luck, not
    semantics. Use `tasklist /fi "PID eq N" /fo csv /nh` (read-only, no side effect). The runner's
    lock check is Node's `process.kill(pid, 0)`, which Node explicitly defines as an existence test.
16. **Background-shell status files are nested under a per-session uuid directory.** A flat
    `glob("<tmp>/shell-bg_*.status")` silently returns nothing and reads as "no loop is running".
    Use `**` with `recursive=True`, and never let an empty directory listing become a negative
    conclusion — same class of mistake as a watchdog that reports zero when it simply looked
    in the wrong place.

## Design traps worth naming

- **Balance the books per owner, not per contract.** Checking `address(this).balance` looked
  correct and let one faction spend another's.
- **Never let a caller pick its own randomness input.** The predecessor's reveal step accepted any
  pre-image matching the revealer's own commitment — searchable offline.
- **Every irreversible lock needs a paid exit.** One-open-commit is the right rule; without
  `abandon()` it becomes permanent denial of service on the agent's own account.
- **Log secrets when they become binding, not when they are used.** The crash window between
  commit and resolve is exactly where an agent becomes unrecoverable.
- **A monitoring metric must be able to see the failure it is named after.** `show-world` printed
  "0 terkunci" while one agent had failed 9 ticks running, because the counter watched the `stuck`
  event, which only fires when a secret is missing. `stuckReport()` now measures consecutive
  non-productive ticks and prints them as `A:3x B:3x C:9x`. The first version of a watchdog that
  cannot see the incident is worse than none, because it manufactures confidence.
- **An escape hatch added to a contract is not a fix until the client uses it.** `abandon()` shipped
  in the world rewrite; the runner never called it, so a stuck agent retried an impossible
  `resolve()` every 6 minutes for ~50 minutes (two agents at once).
- **A balance read is a timestamp, not a fact.** `Fund.s.sol` was nearly left unrun because a
  number measured at 03:11 UTC ("0.000757 BNB, we need a faucet") was still being quoted at
  03:44 — by which time the same wallet held 0.020506 BNB (confirmed identically on
  publicnode, rpc.publicnode and drpc). Re-read any balance before it becomes a blocker claim,
  especially on a key shared with another live project on this machine.
- **A script that silently skips a step is the polite way to lie.** Both funding paths in
  `Fund.s.sol` lacked an affordability guard and logged nothing when skipping, so "already
  funded" and "out of money" looked identical from the outside. Each branch now logs its reason.
- **A docstring that promises protection must be matched by a gate.** The line that claimed agents
  "cannot spend another faction's treasury" was written *before* the check existed.
