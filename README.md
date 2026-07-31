# FORT contracts

Solidity contracts behind [FORT](https://fortsafe.vercel.app): a 2-of-3 multisig safe for
Arc Testnet, where gas is paid in USDC. Foundry project, MIT licensed.

The frontend lives in a separate repository; this one holds the canonical contract source.

## Contracts

### `Save`

The safe itself. Three fixed owners set in the constructor, threshold of two.

- Native transfers and arbitrary contract calls (`bytes data`, up to `MAX_DATA_LENGTH`,
  which is 4096 bytes).
- Reserved funds tracking: every open transaction holds its amount in `pendingAmount`,
  so `availableBalance()` is what can still be committed. Without it, several transactions
  could each be created against the full balance and all but the first would fail at
  execution time. Native currency only: a transaction that moves ERC-20 tokens through its
  calldata reserves nothing, so `availableBalance()` makes no statement about token balances.
- Block numbers of creation and execution are stored on-chain, so the frontend can find a
  transaction hash by scanning a single block instead of a wide range. Without this the
  hashes only existed in `localStorage`, and history was not cross-device.
- Batch reads: `getTxSummaries` for lists (bounded response size), `getTxs` and
  `getTxFull` when calldata is actually needed. Ranges are clamped, not rejected: the window
  length is computed by subtracting `from` from the total rather than adding `from` and
  `count`, so `type(uint256).max` as `count` cannot overflow into a Panic.
- Reentrancy: OpenZeppelin `ReentrancyGuard` on `executeTx`, plus
  checks-effects-interactions. The `executed` flag is set and the reserve released before
  the external call.
- Self-calls are rejected in `_createTx`: every state-changing entry point is owner-gated,
  so a call from the safe to itself could only ever revert.

### `SaveFactory`

Deploys safes and indexes them by owner.

| Function | Purpose |
| --- | --- |
| `createSave(address[3])` | Deploys a safe, optionally funding it with the sent value, and records its owners |
| `safesCountForOwner(owner)` | Number of safes an address co-owns. Read this first |
| `getSafesForOwnerPaged(owner, offset, limit)` | A window of that list. Bounds are clamped, so paging blindly to the end never reverts |
| `getSafesForOwner(owner)` | The full list. Unbounded and kept only for backwards compatibility: a large owner can push this call past the node gas limit. Prefer the paged pair above |
| `safesByOwner` / `safeOwners` | Public mappings behind the getters |
| `getSafeOwners(safe)` | The three owners recorded at creation time |
| `setSafeName(safe, name)` / `getSafeName(safe)` | Optional display name, callable by any of the safe's owners |

Names are limited to `MAX_NAME_LENGTH`, which is 32 **bytes**, not characters. The limit
applies to the UTF-8 encoded length, so multi-byte names are shorter.

## Design decisions

**Access control restricts actions, not reads.** All state is public on-chain and readable
by anyone over RPC. `view` functions have no owner checks because such checks would be
theatre. What is actually protected is the right to create, confirm, cancel and execute.

**Cancellation is asymmetric on purpose.** Cancelling needs two votes, same as executing.
Otherwise any single owner could veto legitimate payments of the other two. The one
exception: the proposer may cancel their own transaction alone, as long as nobody else has
confirmed it. Once quorum is reached, cancellation reverts with `QuorumReached`, so a
confirmed transaction cannot lose a race against a cancel vote. The way out of a bad but
confirmed transaction is `revokeConfirm` first, then cancel.

**A reverting recipient can pin the reserve.** If the destination rejects the transfer,
`executeTx` reverts as a whole and the amount stays in `pendingAmount`, lowering
`availableBalance()`. Recovery is `revokeConfirm` followed by `cancelTx`, which releases
the reserve. This is covered by `test_RevertingRecipientLocksFundsUntilCancel`.

**Errors are custom errors, not revert strings.** Cheaper, and revert strings would
otherwise sit in the deployed bytecode. Clients need the selectors to decode them.

**Owners and threshold are fixed for the lifetime of a safe.** `THRESHOLD` is a compile-time
constant and `owners` is written once in the constructor with no rotation path. Note that
`owners` is ordinary storage (`address[3] public owners`), not a Solidity `immutable`: the
values are read from state, and verification of a `Save` needs its constructor arguments in
the order `getOwners()` returns. N-of-M and owner rotation would change the constructor, the
factory and the whole frontend, and are deliberately out of scope.

## Layout

```
src/Save.sol          Save and SaveFactory
script/Deploy.s.sol   DeployFactory (no constructor args)
test/                 45 unit tests in 6 files, plus 1 invariant suite
```

| Test file | Tests | Covers |
| --- | --- | --- |
| `Cancel.t.sol` | 5 | Single owner cannot veto, two-vote cancellation, cancel blocked after quorum, sole-proposer branch, revoking a cancel vote |
| `Factory.t.sol` | 12 | Name length limit in bytes and at the limit, only owners may rename, and nine pagination cases: count matches the full list, unknown owner, offset past the end, zero limit, limit clamped to the remainder, full window, pages concatenating without gaps or duplicates, `type(uint256).max` limit without Panic, consistency across all owners |
| `Guards.t.sol` | 4 | Range clamping in `getTxs` / `getTxSummaries` on huge counts, and `Deposit` event behaviour: silent on zero-value transfers, exactly one event on funded transfers, none for funding at construction |
| `Pending.t.sol` | 14 | Reserves, `ExceedsAvailableBalance`, release on cancel and execution, no double release, block numbers, batch reads and their bounds, confirmations, calls with calldata, zero-value calls, `EmptyTransaction`, calldata limit and the limit boundary, owner gate on the calldata overload |
| `Reentrancy.t.sol` | 6 | Reentrant owner cannot drain, pinned reserve and its recovery, both `BadRecipient` branches (zero address and the safe itself), execution below threshold, double execution |
| `Summaries.t.sol` | 4 | `getTxSummaries` matches `getTxFull` field by field, the fixture exercises non-default fields, batch reads agree, identical slice clamping |
| `PendingInvariant.t.sol` | 1 invariant | `invariant_pendingEqualsOpenSum`: `pendingAmount` equals the sum of open transactions and never exceeds the safe's balance. Runs 256 with depth 128 and `fail_on_revert = false`, configured in `foundry.toml` |

## Build and test

Dependencies are git submodules, so a plain `git clone` will not compile:

```bash
git clone --recurse-submodules https://github.com/EthernalBuddha/fort-contracts.git
cd fort-contracts
forge build --sizes
forge test
```

Already cloned without submodules: `git submodule update --init --recursive`.

Pinned dependencies: `forge-std` v1.16.2 and `openzeppelin-contracts` v5.6.1, with the
remapping in `remappings.txt`. The exact revisions are committed in `foundry.lock`, so the
versions above are reproducible rather than merely documented.

The optimizer is enabled with 200 runs and `solc` is pinned to 0.8.35 in `foundry.toml`.
Both matter: `SaveFactory` embeds the `Save` bytecode and exceeds the EIP-170 limit of
24576 bytes without optimization, and verification only reproduces with the exact same
settings.

### CI

`.github/workflows/test.yml` runs on every push, pull request and manual dispatch. It checks
out submodules recursively, installs Foundry, then runs three steps in order:

```bash
forge fmt --check
forge build --sizes
forge test -vvv
```

The formatting gate is not optional, so run `forge fmt` before pushing.

## Deployment

Current deployment on Arc Testnet:

| Contract | Address | Status |
| --- | --- | --- |
| `SaveFactory` | `0x0a12aEa5A35d7199F2B7cac3C14A7a9e470F561a` | Live, verified, block 54503427 |
| `Save` (example safe) | `0x2297366Ec137154d51Df9247f66D199275D6878C` | Live, verified |

The factory is immutable and embeds the `Save` creation code in its own bytecode, so any
change to `src/Save.sol` produces a different factory. Earlier factories remain live with
their original logic; safes created through them keep working and do not migrate. Superseded
addresses: `0xc965e062f93F35507DF0F9E9a3973F04704215dA` (block 54284174) and
`0x264E2d5537B0073F35eD6A0Ed006Eb21022985c7`. The frontend takes the address it uses from
its own environment variable, not from this file.

Verifying one safe covers the rest: owners live in ordinary storage, so the runtime bytecode
is identical across safes and Blockscout matches new ones automatically.

Network: Arc Testnet, chain id 5042002, RPC `https://rpc.testnet.arc.network`, explorer
`https://testnet.arcscan.app`, faucet `https://faucet.circle.com`. Gas and balances are
denominated in USDC.

Deploy. The key lives in an encrypted Foundry keystore, never in a plaintext file:

```bash
forge script script/Deploy.s.sol:DeployFactory \
  --rpc-url arc \
  --account <keystore-account> \
  --sender <deployer-address> \
  --broadcast
```

Verify on Blockscout. The explorer runs Blockscout, not Etherscan, so no API key is needed.
Compiler settings are taken from `foundry.toml`. The factory has no constructor arguments:

```bash
forge verify-contract <factory-address> src/Save.sol:SaveFactory \
  --chain-id 5042002 \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api/ \
  --watch
```

A `Save` needs its three owners as constructor arguments, in the order `getOwners()` returns.
Do not reconstruct that order from memory; read it from the chain first with
`cast call <safe> "getOwners()(address[3])" --rpc-url arc`. A permutation changes the
bytecode and verification fails:

```bash
forge verify-contract <safe-address> src/Save.sol:Save \
  --chain-id 5042002 \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api/ \
  --constructor-args $(cast abi-encode "constructor(address[3])" "[<owner0>,<owner1>,<owner2>]") \
  --watch
```

Note that the metadata hash embedded in the bytecode covers the full source, comments and
SPDX header included, so verifying an address requires the exact source it was deployed
from.

## License

MIT, see `LICENSE`.
