//SPDX-License-Identifier: MIT

//HAVE OUR INVARIANT AKA PROPERTIES TESTS THAT SHOULD ALWAYS HOLD TRUE

//WHAT ARE OUR INVARIANTS?

//1. THE TOTAL SUPPLY OF DSC SHOULD NEVER EXCEED THE TOTAL COLLATERAL VALUE IN USD / MIN_HEALTH_FACTOR
//2. GETTER VIEW FUNCTIONS SHOULD NEVER REVERT <- EVERGREEN INVARIANT

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Handler} from "../fuzz/Handler.sol";

contract Invariants is StdInvariant {
    DeployDSCEngine private deployer;
    DecentralizedStableCoin private dsc;
    DSCEngine private dsce;
    HelperConfig private helpConfig;
    address private weth;
    address private wbtc;

    function setUp() public {
        deployer = new DeployDSCEngine();
        (dsce, dsc, helpConfig) = deployer.run();
        (,, weth, wbtc,) = helpConfig.activeNetworkConfig();
        //targetContract(address(dsce));

        Handler handler = new Handler(dsce, dsc);
        targetContract(address(handler));
        //dont call reddemCollateral unless there is some collateral deposited
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        //get the value of all collateral in the protocol
        //compare it to the total supply of DSC
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 totalWethValue = dsce.getUSDvalue(weth, totalWethDeposited);
        uint256 totalWbtcValue = dsce.getUSDvalue(wbtc, totalWbtcDeposited);

        assert(totalWethValue + totalWbtcValue >= totalSupply);
    }
}

