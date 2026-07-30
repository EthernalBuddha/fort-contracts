# FORT contracts

Solidity contracts behind [FORT](https://fortsafe.vercel.app): a 2-of-3 multisig safe for
Arc Testnet, where gas is paid in USDC. Foundry project, MIT licensed.

The frontend lives in a separate repository; this one holds the canonical contract source.

## Contracts

### `Save`

The safe itself. Three fixed owners set in the constructor, threshold of two.

- Native transfers and arbitrary contract calls (`bytes data`, up to 4096 bytes).
- Reserved funds tracking: every open transaction holds its amount in `pendingAmount`,
  so `availableBalance()` is what can still be committed. Without it, several transactions
  could each be created against the full balance and all but the first would fail at
  execution time.
- Block numbers of creation and execution are stored on-chain, so the frontend can find a
  transaction hash by scanning a single block instead of a wide range. Without this the
  hashes only existed in `localStorage`, and history was not cross-device.
- Batch reads: `getTxSummaries` for lists (bounded response size), `getTxs` and
  `getTxFull` when calldata is actually needed.
- Reentrancy: OpenZeppelin `ReentrancyGuard` on `executeTx`, plus
  checks-effects-interactions. The `executed` flag is set and the reserve released before
  the external call.

### `SaveFactory`

Deploys safes and indexes them: `getSafesForOwner`, `safeOwners`, `getSafeOwners`, and
optional names limited to 32 **bytes**, not characters. The limit applies to the UTF-8
encoded length.

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

**Owners and threshold are immutable.** N-of-M and owner rotation would change the
constructor, the factory and the whole frontend, and are deliberately out of scope.

## Layout

```
src/Save.sol          Save and SaveFactory
script/Deploy.s.sol   DeployFactory (no constructor args)
test/                 36 tests in 6 files
```

| Test file | Covers |
| --- | --- |
| `Cancel.t.sol` | Two-vote cancellation, sole-proposer branch, revoking a cancel vote |
| `Factory.t.sol` | Name length limit in bytes, only owners may rename |
| `Guards.t.sol` | Owner validation and access checks |
| `Pending.t.sol` | Reserves, `ExceedsAvailableBalance`, release on cancel and execution, block numbers, calldata limits, batch slices |
| `Reentrancy.t.sol` | Reentrant owner cannot drain, pinned reserve and its recovery, both `BadRecipient` branches, confirmation and double-execution guards |
| `Summaries.t.sol` | `getTxSummaries` matches `getTxFull` field by field, identical slice clamping |

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
remapping in `remappings.txt`.

The optimizer is enabled with 200 runs and `solc` is pinned to 0.8.35 in `foundry.toml`.
Both matter: `SaveFactory` embeds the `Save` bytecode and exceeds the EIP-170 limit of
24576 bytes without optimization, and verification only reproduces with the exact same
settings.

## Deployment

| Contract | Address | Status |
| --- | --- | --- |
| `SaveFactory` | `0xc965e062f93F35507DF0F9E9a3973F04704215dA` | Live, verified, block 54284174 |
| `Save` (test safe) | `0x77c92939Bd7f35bd8e2899d1393B8632542E0553` | Live |

Network: Arc Testnet, chain id 5042002, RPC `https://rpc.testnet.arc.network`, explorer
`https://testnet.arcscan.app`, faucet `https://faucet.circle.com`. Gas and balances are
denominated in USDC.

Deploy. The key lives in an encrypted Foundry keystore, never in `.env`:

```bash
forge script script/Deploy.s.sol:DeployFactory \
  --rpc-url arc \
  --account <keystore-account> \
  --sender <deployer-address> \
  --broadcast
```

Verify on Blockscout. `Save` needs its constructor arguments in the order returned by
`getOwners()`:

```bash
forge verify-contract <address> src/Save.sol:SaveFactory \
  --verifier blockscout \
  --verifier-url https://testnet.arcscan.app/api \
  --compiler-version 0.8.35 \
  --num-of-optimizations 200 \
  --watch
```

Note that the metadata hash embedded in the bytecode covers the full source, comments and
SPDX header included, so verifying an address requires the exact source it was deployed
from.

## License

MIT, see `LICENSE`.
