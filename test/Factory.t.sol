// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/Save.sol";

contract FactoryTest is Test {
    SaveFactory f;
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");

    function setUp() public {
        f = new SaveFactory();
    }

    // Длинное имя больше не принимается.
    function test_LongSafeNameReverts() public {
        address safe = f.createSave([a, b, c]);

        string memory long = new string(10_000);

        vm.prank(a);
        vm.expectRevert("name too long");
        f.setSafeName(safe, long);
    }

    // Имя ровно на границе проходит.
    function test_NameAtLimitAccepted() public {
        address safe = f.createSave([a, b, c]);

        string memory name = new string(32);

        vm.prank(a);
        f.setSafeName(safe, name);

        assertEq(bytes(f.getSafeName(safe)).length, 32);
    }

    // Чужой не может переименовать сейф.
    function test_NonOwnerCannotRename() public {
        address safe = f.createSave([a, b, c]);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert("not owner");
        f.setSafeName(safe, "hack");
    }
}
