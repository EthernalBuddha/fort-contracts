# FORT contracts

Solidity sources for FORT, a 2-of-3 multisig safe on Arc Testnet. Built with Foundry.

Frontend: [fortsafe.vercel.app](https://fortsafe.vercel.app/) вЂ” source in [EthernalBuddha/FORT](https://github.com/EthernalBuddha/FORT).

## Contracts

`src/Save.sol` holds both contracts.

### Save

A safe with three fixed owners and a threshold of two. Owners and threshold are set in the constructor and cannot change: moving to N-of-M would touch the constructor, the factory and the frontend, so it is out of scope.

- Create, confirm, revoke, cancel and execute native transfers.
- A transfer executes with 2 of 3 confirmations.
- A transfer is canceled with 2 of 3 cancel votes. Exception: the proposer can cancel their own transfer alone, as long as no other owner has confirmed it.
- Transfers may carry calldata (up to `MAX_DATA_LENGTH` = 4096 bytes), so the safe can call other contracts.
- Reads are batched through `getTxs` and `getTxSummaries`; the latter omits calldata and therefore has a bounded response size.

### SaveFactory

Deploys `Save` instances, indexes them by owner and stores safe names on chain (`MAX_NAME_LENGTH` = 32 bytes, only an owner can rename). The factory embeds the full `Save` creation code, so `Save`'s size counts against the factory's EIP-170 limit.

## Design notes

**Access control is enforced on actions, not on reading.** Only an owner can create, confirm, revoke, cancel or execute. All safe state is readable by anyone through public view functions and directly from the chain, so the contents of a safe are public information.

**Reserved amounts.** Every created transfer reserves its amount in `pendingAmount`, so `availableBalance()` is lower than the raw balance while transfers are pending. Creation is checked against the available balance, execution against the full balance. Native currency only: a transfer that moves ERC-20 tokens through its calldata reserves nothing, so `availableBalance()` makes no statement about token balances.

**Cancellation is deliberately not symmetric with execution.** Once `confirms` reaches the threshold the transfer can no longer be canceled, so that a cancel vote cannot race an execution that is already authorized. The way to unwind such a transfer is `revokeConfirm`: the count drops below the threshold and the normal cancel flow becomes available again.

That same path is the only way out of a transfer whose recipient always reverts. It can never execute, and its amount would otherwise stay reserved forever, lowering `availableBalance()` for everyone. `test_RevertingRecipientLocksFundsUntilCancel` covers the full recovery.

**Reentrancy.** `executeTx` is the only function that calls out of the contract. It follows checks-effects-interactions вЂ” the `executed` flag and the reserve release are written before the external call вЂ” and carries OpenZeppelin's `nonReentrant` as a second line of defence. `test_ReentrantOwnerCannotDrainSafe` exercises an owner contract that re-enters from its `receive` hook.

## Deployment

| | |
| --- | --- |
| Network | Arc Testnet |
| ChainId | `5042002` |
| RPC | https://rpc.testnet.arc.network |
| Currency | USDC (also the gas token) |
| Explorer | https://testnet.arcscan.app |
| Faucet | https://faucet.circle.com |
| SaveFactory | `0xc965e062f93F35507DF0F9E9a3973F04704215dA` (block 54284174) |

Events: `SaveCreated`, `SafeRenamed` on the factory; `Deposit`, `TxCreated`, `TxConfirmed`, `TxRevoked`, `TxCancelVoted`, `TxCancelVoteRevoked`, `TxCanceled`, `TxExecuted` on each safe.

## Development

Requires [Foundry](https://getfoundry.sh). The compiler version is pinned to `0.8.35`.

Clone with submodules вЂ” `lib/forge-std` and `lib/openzeppelin-contracts` (pinned to `v5.6.1`) are git submodules:

```sh
git clone --recurse-submodules https://github.com/EthernalBuddha/fort-contracts.git
```

If the repository is already cloned:

```sh
git submodule update --init --recursive
```

Build, test and format:

```sh
forge build
forge test
forge fmt
```

## Tests

32 tests across five files:

| File | Covers |
| --- | --- |
| `Pending.t.sol` | reserved amounts, batch reads, calldata limits, owner gating |
| `Cancel.t.sol` | cancel votes, quorum rules, sole-proposer cancel, vote revocation |
| `Reentrancy.t.sol` | reentrancy guard, stuck reserve recovery, recipient validation, execution guards |
| `Guards.t.sol` | `Deposit` events, out-of-range read arguments |
| `Factory.t.sol` | safe names, rename permissions |

## License

MIT