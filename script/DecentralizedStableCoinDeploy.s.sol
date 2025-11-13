//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script, console} from "forge-std/Script.sol";
import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";

contract DecentralizedStableCoinDeploy is Script {
    function run() public returns (DecentralizedStableCoin) {
        vm.startBroadcast();
        DecentralizedStableCoin dsc = new DecentralizedStableCoin();
        vm.stopBroadcast();

        return dsc;
    }
}
