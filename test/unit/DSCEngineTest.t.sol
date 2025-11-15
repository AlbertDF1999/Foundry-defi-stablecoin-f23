//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {Script} from "forge-std/Script.sol";

contract DSCEngineTest is Script {
    DeployDSCEngine deployer = new DeployDSCEngine();

    function setUp() external {}
}
