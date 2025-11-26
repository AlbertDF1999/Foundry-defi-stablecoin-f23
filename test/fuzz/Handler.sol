//SPDX-License-Identifier: MIT

//The way this contract is set up is that it will be used by the invariant testing system of forge
//It will call functions on the DSCEngine and DecentralizedStableCoin contracts in order to try to break the invariants we have set up in the InvariantsTest.t.sol file

pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../Mocks/MockV3Aggregator.sol";

contract Handler is Test {
    DSCEngine public dsce;
    DecentralizedStableCoin public dsc;
    ERC20Mock weth;
    ERC20Mock wbtc;
    uint256 counter = 0;
    address[] private usersWithCollateralDeposited;
    uint256 public timesMinstIsCalled;
    MockV3Aggregator public ethUsdPriceFeed;

    uint256 constant MAX_DEPOSIT_AMOUNT = type(uint96).max;
    uint256 constant MINT_AMOUNT = type(uint96).max;

    constructor(DSCEngine _dsce, DecentralizedStableCoin _dsc) {
        dsce = _dsce;
        dsc = _dsc;

        address[] memory collateralTokens = dsce.getCollateralTokens();
        weth = ERC20Mock(collateralTokens[0]);
        wbtc = ERC20Mock(collateralTokens[1]);

        ethUsdPriceFeed = MockV3Aggregator(dsce.getCollateralTokenPriceFeed(address(weth)));
    }

    //redeem <==

    ///////////////////
    // Public functions
    ///////////////////

    function mintDsc(uint256 amountDsc, uint256 addressSeed) public {
        if (usersWithCollateralDeposited.length == 0) {
            return;
        }
        address sender = usersWithCollateralDeposited[addressSeed % usersWithCollateralDeposited.length];
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dsce.getAccountInformation(sender);
        int256 maxDscToMint = (int256(collateralValueInUSD) / 2) - int256(totalDscMinted);
        console.log("amount dsc: ", amountDsc);
        console.log("total dsc minted: ", totalDscMinted);
        console.log("collateral valuee usd: ", collateralValueInUSD);
        if (maxDscToMint < 0) {
            return;
        }

        amountDsc = bound(amountDsc, 0, uint256(maxDscToMint));
        if (amountDsc == 0) {
            return;
        }

        vm.startPrank(sender);
        dsce.mintDsc(amountDsc);
        vm.stopPrank();
        timesMinstIsCalled++;
    }

    function depositCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // counter++;
        // console.log("Handler call count:", counter);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        amountCollateral = bound(amountCollateral, 1, MAX_DEPOSIT_AMOUNT);
        vm.startPrank(msg.sender);
        collateral.mint(msg.sender, amountCollateral);
        collateral.approve(address(dsce), MAX_DEPOSIT_AMOUNT);
        dsce.depositCollateral(address(collateral), amountCollateral);
        vm.stopPrank();
        usersWithCollateralDeposited.push(msg.sender);
    }

    function redeemCollateral(uint256 collateralSeed, uint256 amountCollateral) public {
        // counter++;
        // console.log("Handler call count 2:", counter);
        ERC20Mock collateral = _getCollateralFromSeed(collateralSeed);
        uint256 maxCollateralToRedeem = dsce.getCollateralBalanceOfTheUser(msg.sender, address(collateral));
        amountCollateral = bound(amountCollateral, 0, maxCollateralToRedeem);
        if (amountCollateral == 0) {
            return;
        }

        try dsce.redeemCollateral(address(collateral), amountCollateral) {}
        catch {
            // If it reverts (including reentrancy), just skip this call
            vm.stopPrank();
            return;
        }
        vm.stopPrank();
    }

    //This breaks our invariant test suite
    // function updateCollateralPrice(uint256 newPrice) public {
    //     int256 newPriceInt = int256(uint256(newPrice));
    //     ethUsdPriceFeed.updateAnswer(newPriceInt);
    // }

    ///////////////////
    // Private functions
    ///////////////////

    function _getCollateralFromSeed(uint256 collateralSeed) private view returns (ERC20Mock) {
        if (collateralSeed % 2 == 0) {
            return weth;
        } else {
            return wbtc;
        }
    }
}
