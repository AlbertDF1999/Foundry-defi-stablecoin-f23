//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    DSCEngine dsce;
    address ethUsdPriceFeed;
    address weth;

    address USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() external {
        deployer = new DeployDSCEngine();
        (dsce, dsc, config) = deployer.run();
        (ethUsdPriceFeed, , weth, , ) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetUsdValue() external {
        uint256 amount = 15e18; //15 ETH
        //15e18 * 2000 = 30000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dsce.getUSDvalue(weth, amount);
        console.log(actualUsdValue);
        console.log(expectedUsdValue);
        assert(expectedUsdValue == actualUsdValue);
    }

    //////////////////////////////
    // Deposit collateral Tests //
    //////////////////////////////

    function testRevertIfCollateralZero() external {
        //arrange
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        //act /assert
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }
}
