// SPDX-License-Identifier: MIT
pragma solidity 0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {Save} from "../src/Save.sol";

/// @title Bounded driver for Save.
/// @notice The fuzzer calls this contract, never Save directly: random senders
/// would bounce off NotOwner and never reach interesting states.
contract PendingHandler is Test {
    Save public save;
    address[3] public owners;
    address[4] public recipients;

    // Ghost counters. Without them a handler that reverts on every call would
    // keep the invariant trivially true and the test would prove nothing.
    uint256 public created;
    uint256 public confirmed;
    uint256 public revoked;
    uint256 public canceled;
    uint256 public executed; // reached by the purely random call sequence
    uint256 public chainExecuted; // reached by the scripted happy path

    constructor(Save _save, address[3] memory _owners) {
        save = _save;
        owners = _owners;
        recipients[0] = makeAddr("recipient0");
        recipients[1] = makeAddr("recipient1");
        recipients[2] = makeAddr("recipient2");
        recipients[3] = makeAddr("recipient3");
    }

    function createTx(uint256 ownerSeed, uint256 toSeed, uint256 amount) external {
        address owner = owners[bound(ownerSeed, 0, 2)];
        address to = recipients[bound(toSeed, 0, 3)];
        // Zero amount without calldata is rejected by the contract.
        amount = bound(amount, 1, 2 ether);
        vm.prank(owner);
        try save.createTx(to, amount) returns (uint256) {
            created++;
        } catch {}
    }

    function confirmTx(uint256 ownerSeed, uint256 idSeed) external {
        uint256 n = save.txCount();
        if (n == 0) return;
        address owner = owners[bound(ownerSeed, 0, 2)];
        uint256 id = bound(idSeed, 0, n - 1);
        vm.prank(owner);
        try save.confirmTx(id) {
            confirmed++;
        } catch {}
    }

    function revokeConfirm(uint256 ownerSeed, uint256 idSeed) external {
        uint256 n = save.txCount();
        if (n == 0) return;
        address owner = owners[bound(ownerSeed, 0, 2)];
        uint256 id = bound(idSeed, 0, n - 1);
        vm.prank(owner);
        try save.revokeConfirm(id) {
            revoked++;
        } catch {}
    }

    function cancelTx(uint256 ownerSeed, uint256 idSeed) external {
        uint256 n = save.txCount();
        if (n == 0) return;
        address owner = owners[bound(ownerSeed, 0, 2)];
        uint256 id = bound(idSeed, 0, n - 1);
        vm.prank(owner);
        try save.cancelTx(id) {
            canceled++;
        } catch {}
    }

    function executeTx(uint256 ownerSeed, uint256 idSeed) external {
        uint256 n = save.txCount();
        if (n == 0) return;
        address owner = owners[bound(ownerSeed, 0, 2)];
        uint256 id = bound(idSeed, 0, n - 1);
        vm.prank(owner);
        try save.executeTx(id) {
            executed++;
        } catch {}
    }

    /// @notice Scripted happy path: create, confirm with the two other owners,
    /// execute. Random sequences almost never line up on the same id, which
    /// leaves the execution branch of _releasePending untested.
    function createConfirmExecute(uint256 toSeed, uint256 amount) external {
        address to = recipients[bound(toSeed, 0, 3)];
        amount = bound(amount, 1, 1 ether);

        uint256 id;
        vm.prank(owners[0]);
        try save.createTx(to, amount) returns (uint256 newId) {
            created++;
            id = newId;
        } catch {
            return;
        }

        vm.prank(owners[1]);
        try save.confirmTx(id) {
            confirmed++;
        } catch {}

        vm.prank(owners[2]);
        try save.confirmTx(id) {
            confirmed++;
        } catch {}

        vm.prank(owners[0]);
        try save.executeTx(id) {
            chainExecuted++;
        } catch {}
    }
}

/// @title Invariant: pendingAmount always equals the sum of open transactions.
/// @notice Open means neither executed nor canceled. This is the check that
/// gates the decision about the underflow clamp in _releasePending.
contract PendingInvariantTest is Test {
    Save internal save;
    PendingHandler internal handler;

    function setUp() public {
        address[3] memory owners =
            [makeAddr("owner0"), makeAddr("owner1"), makeAddr("owner2")];

        save = new Save{value: 100 ether}(owners);
        handler = new PendingHandler(save, owners);

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = PendingHandler.createTx.selector;
        selectors[1] = PendingHandler.confirmTx.selector;
        selectors[2] = PendingHandler.revokeConfirm.selector;
        selectors[3] = PendingHandler.cancelTx.selector;
        selectors[4] = PendingHandler.executeTx.selector;
        selectors[5] = PendingHandler.createConfirmExecute.selector;

        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_pendingEqualsOpenSum() public view {
        uint256 n = save.txCount();
        uint256 sum;

        if (n > 0) {
            Save.TxSummary[] memory list = save.getTxSummaries(0, n);
            for (uint256 i; i < n; i++) {
                if (!list[i].executed && !list[i].isCanceled) {
                    sum += list[i].amount;
                }
            }
        }

        assertEq(save.pendingAmount(), sum, "pendingAmount drifted from open tx sum");
    }

    /// @notice Guard against a green but empty run. This cannot be an invariant_
    /// function: Foundry checks those against the initial state as well, where
    /// every counter is legitimately zero.
    function afterInvariant() public view {
        console2.log("created      ", handler.created());
        console2.log("confirmed    ", handler.confirmed());
        console2.log("revoked      ", handler.revoked());
        console2.log("canceled     ", handler.canceled());
        console2.log("executed     ", handler.executed());
        console2.log("chainExecuted", handler.chainExecuted());

        assertGt(handler.created(), 0, "fuzzer created nothing");
        assertGt(handler.confirmed(), 0, "fuzzer confirmed nothing");
        assertGt(handler.canceled(), 0, "fuzzer canceled nothing");
        assertGt(
            handler.executed() + handler.chainExecuted(),
            0,
            "fuzzer executed nothing"
        );
    }
}
