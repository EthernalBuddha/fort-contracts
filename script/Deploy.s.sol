// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "../src/Save.sol";

contract DeployFactory is Script {
    function run() external returns (address factory) {
        vm.startBroadcast();
        SaveFactory f = new SaveFactory();
        vm.stopBroadcast();

        factory = address(f);
        console2.log("SaveFactory deployed at:", factory);
    }
}
