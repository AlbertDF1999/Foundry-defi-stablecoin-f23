//SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSCEngine} from "../../script/DeployDSCEngine.s.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../Mocks/MockFailedTransferFrom.sol";
import {MockFailedMintDSC} from "../Mocks/MockFailedMintDSC.sol";
import {MockV3Aggregator} from "../Mocks/MockV3Aggregator.sol";
import {MockFailedTransfer} from "../Mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../Mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    DSCEngine dsce;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address public USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 100 ether;
    uint256 public constant AMOUNT_COLLATERAL_VIEW_FUNCTIONS = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 10 ether;
    uint256 public constant AMOUNT_TO_MINT_FOR_HF_BELOW_1 = 910 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public amountToMint;

    //Liquidation
    uint256 public collateralToCover = 20 ether;
    address public LIQUIDATOR = makeAddr("LIQUIDATOR");

    function setUp() external {
        deployer = new DeployDSCEngine();
        (dsce, dsc, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
        ERC20Mock(wbtc).mint(USER, STARTING_ERC20_BALANCE);
    }

    /////////////////////
    // Modifiers //
    //////////////////////
    modifier depositCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    modifier liquidated() {
        uint256 amountToMintLiquidated = 100 ether;
        uint256 amountCollateralLiquidated = 10 ether;
        uint256 collateralToCoverLiquidated = 20 ether;
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), amountCollateralLiquidated);
        dsce.depositCollateralAndMintDsc(weth, amountCollateralLiquidated, amountToMintLiquidated);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCoverLiquidated);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCoverLiquidated);
        dsce.depositCollateralAndMintDsc(weth, collateralToCoverLiquidated, amountToMintLiquidated);
        dsc.approve(address(dsce), amountToMintLiquidated);
        dsce.liquidate(weth, USER, amountToMintLiquidated); // We are covering their whole debt
        vm.stopPrank();
        _;
    }

    /////////////////////
    // Constuctor Tests //
    //////////////////////
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertIfTokenLengthDoesntMatchPriceFeedLength() external {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressMustBeSameLenght.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //////////////////
    // Price Tests //
    //////////////////

    function testGetUsdValue() external {
        uint256 amount = 15e18; //15 ETH
        //15e18 * 2000 = 30000e18
        uint256 expectedUsdValue = 30000e18;
        uint256 actualUsdValue = dsce.getUSDvalue(weth, amount);
        assert(expectedUsdValue == actualUsdValue);
    }

    function testGetTokenAmountFromUsd() external {
        //ARRANGE
        uint256 usdAmount = 100 ether; //100 USD
        uint256 expectedTokenAmount = 0.05 ether; //0.05 ETH

        //ACT
        uint256 tokenInEther = dsce.getTokenAmountFromUsd(weth, usdAmount);

        //ASSERT
        assert(expectedTokenAmount == tokenInEther);
    }

    //////////////////////////////
    // Deposit collateral Tests //
    //////////////////////////////

    function testRevertIfCollateralZero() external {
        //arrange
        vm.prank(USER);

        //act /assert
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
    }

    function testRevertWithUnapprovedCollateralToken() external {
        address ranToken = address(new ERC20Mock("RAN", "RAN"));
        vm.prank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
    }

    function testCanDepositCollateralAndGetAccountInfo() external depositCollateral {
        //ARRANGE
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = dsce.getAccountInformation(USER);
        //ACT
        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositedAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUSD);
        //ASSERT
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositedAmount);
    }

    function testCanDepositCollateralWithoutMinting() external depositCollateral {
        uint256 dscBalance = dsc.balanceOf(USER);
        assert(0 == dscBalance);
    }

    function testRevertIfTransferFromReverts() external {
        //ARRANGE
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();
        tokenAddresses = [address(mockCollateralToken)];
        priceFeedAddresses = [ethUsdPriceFeed];
        //DSCEngine receives the third parameter as dscAddress, not the tokenAddress used as collateral
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsce));
        mockCollateralToken.mint(USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        MockFailedTransferFrom(address(mockCollateralToken)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        //ACT/assert
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.depositCollateral(address(mockCollateralToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // depositCollateralAndMintDsc Tests //
    ///////////////////////////////////////

    function testMintedMoreThanAllowedByHealthFactor() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert();
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, 100001 ether);
        vm.stopPrank();
    }

    function testCanMintWithdepositCollateral() external depositCollateralAndMintDsc {
        uint256 mintedDsc = dsce.getDscMinted(USER);
        assert(mintedDsc == AMOUNT_TO_MINT);
    }

    function testRevertIfMintedDscBreaksHealthFactor() external {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUSDvalue(weth, AMOUNT_COLLATERAL));
        // console.log(AMOUNT_COLLATERAL);
        // console.log(amountToMint);
        // console.log(expectedHealthFactor);
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, amountToMint);
        vm.stopPrank();
    }

    ///////////////////////////////////////
    // MintDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfMintFails() external {
        //ARRANGE
        MockFailedMintDSC mockToken = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockToken));
        mockToken.transferOwnership(address(mockDsce));
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine_MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testUserCanDepositAndMintDsc() external depositCollateralAndMintDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assert(userBalance == AMOUNT_TO_MINT);
    }

    function testRevertIfMintAmountIsZero() external {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function testRevertsIfMintAmountBreaksHealthFactor() public depositCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(amountToMint, dsce.getUSDvalue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine_BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(amountToMint);
        vm.stopPrank();
    }

    function testCanMintDsc() public depositCollateral {
        vm.prank(USER);
        dsce.mintDsc(AMOUNT_TO_MINT);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, AMOUNT_TO_MINT);
    }

    ///////////////////////////////////////
    // burnDsc Tests //
    ///////////////////////////////////////

    function testRevertsIfBurnAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function testCantBurnMoreThanUserHas() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function testCanBurnDsc() public depositCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        dsce.burnDsc(AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ///////////////////////////////////
    // redeemCollateral Tests //
    //////////////////////////////////

    // this test needs it's own setup
    function testRevertsIfTransferFails() public {
        // Arrange - Setup
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransfer mockDsc = new MockFailedTransfer();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsce), AMOUNT_COLLATERAL);
        // Act / Assert
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_TransferFailed.selector);
        mockDsce.redeemCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function testRevertsIfRedeemAmountIsZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateral(weth, 0);
        vm.stopPrank();
    }

    function testCanRedeemCollateral() public depositCollateral {
        vm.startPrank(USER);
        uint256 userBalanceBeforeRedeem = dsce.getCollateralBalanceOfTheUser(USER, weth);
        assertEq(userBalanceBeforeRedeem, AMOUNT_COLLATERAL);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        uint256 userBalanceAfterRedeem = dsce.getCollateralBalanceOfTheUser(USER, weth);
        assertEq(userBalanceAfterRedeem, 0);
        vm.stopPrank();
    }

    function testEmitCollateralRedeemedWithCorrectArgs() public depositCollateral {
        vm.expectEmit(true, true, true, true, address(dsce));
        emit DSCEngine.CollateralRedeemed(USER, USER, weth, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        dsce.redeemCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    ///////////////////////////////////
    // redeemCollateralForDsc Tests //
    //////////////////////////////////

    function testMustRedeemMoreThanZero() public depositCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), AMOUNT_COLLATERAL);
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, AMOUNT_TO_MINT);
        vm.stopPrank();
    }

    function testCanRedeemDepositedCollateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        dsc.approve(address(dsce), AMOUNT_TO_MINT);
        dsce.redeemCollateralForDsc(weth, AMOUNT_TO_MINT, AMOUNT_TO_MINT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    ////////////////////////
    // healthFactor Tests //
    ////////////////////////

    function testProperlyReportsHealthFactor() public depositCollateralAndMintDsc {
        uint256 expectedHealthFactor = 10000 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // console.log(healthFactor);
        // console.log(expectedHealthFactor);
        assertEq(healthFactor, expectedHealthFactor);
    }

    function testHealthFactorCanGoBelowOne() public depositCollateral {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_TO_MINT_FOR_HF_BELOW_1);
        dsce.mintDsc(AMOUNT_TO_MINT_FOR_HF_BELOW_1);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        // Remember, we need $200 at all times if we have $100 of debt

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        // 180*50 (LIQUIDATION_THRESHOLD) / 100 (LIQUIDATION_PRECISION) / 100 (PRECISION) = 90 / 100 (totalDscMinted) =
        // 0.9
        // console.log(userHealthFactor);
        assert(userHealthFactor < 1 ether);
    }

    ///////////////////////
    // Liquidation Tests //
    ///////////////////////

    // This test needs it's own setup
    function testMustImproveHealthFactorOnLiquidation() public {
        // Arrange - Setup
        uint256 amountCollateralUser2 = 10 ether;
        uint256 amountToMintUser2 = 100 ether;
        uint256 startingUserBalanceUser2 = 10 ether;
        address USER2 = makeAddr("USER2");

        ERC20Mock(weth).mint(USER2, startingUserBalanceUser2);
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));
        // Arrange - User
        vm.startPrank(USER2);
        ERC20Mock(weth).approve(address(mockDsce), amountCollateralUser2);
        mockDsce.depositCollateralAndMintDsc(weth, amountCollateralUser2, amountToMintUser2); //at this point USER2 has $100 DSC minted and has $20k worth of WETH as collateral, because 1 weth = $2000
        vm.stopPrank();

        // Arrange - Liquidator
        collateralToCover = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover); // 1 wether = $2000

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), collateralToCover);
        uint256 debtToCover = 10 ether; // this amount represents $10 dsc,
        //when we crash the weth price to 1 weth = $18, USER2 will only have $180 worth of WETH as collateral for his $100 DSC debt
        //USER2 minted dsc cannot be more than $90 but he has $100, so the debtToCover will be $10 after the price crash DSC to make up for that missing amount
        mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMintUser2); //collateral worth $2000, minted $100 DSC
        mockDsc.approve(address(mockDsce), debtToCover);
        // Act
        int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        // Act/Assert
        //at this point, USER2 has $100 DSC debt, and only $180 worth of WETH as collateral, so Health Factor < 1
        //LIQUIDATOR has $18 of weth as collateral, and $10 DSC minted

        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorNotImproved.selector);
        //current holdings of USER 2 is $180 worth of WETH as collateral for $100 DSC minted
        //current holdings of LIQUIDATOR is $18 worth of WETH as collateral for $100 DSC minted
        mockDsce.liquidate(weth, USER2, debtToCover);
        // the health factor of user2 improves from .9 to .93 but the error goes true because
        //when we crash the price to 0 in out mock aggregator the new health factor becomes 0
        //thats why we need the mock aggregator because a real case in unlikely to happen

        vm.stopPrank();
    }

    function testCantLiquidateGoodHealthFactor() public depositCollateralAndMintDsc {
        uint256 amountToMintLiquidator = 100 ether;

        ERC20Mock(weth).mint(LIQUIDATOR, collateralToCover); //collateral to cover is 20 ether

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), collateralToCover);
        dsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMintLiquidator); //LIQUIDATOR has 20 eth collateral and $100 dsc minted
        dsc.approve(address(dsce), amountToMintLiquidator);

        vm.expectRevert(DSCEngine.DSCEngine_HealthFactorOk.selector);
        dsce.liquidate(weth, USER, amountToMintLiquidator);
        vm.stopPrank();
    }

    function testLiquidationPayoutIsCorrect() public liquidated {
        uint256 amountToMintLiquidated = 100 ether;
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        console.log(liquidatorWethBalance);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, amountToMintLiquidated)
            + (dsce.getTokenAmountFromUsd(weth, amountToMintLiquidated)
                * dsce.getLiquidationBonus()
                / dsce.getLiquidationPrecision());
        uint256 hardCodedExpected = 6_111_111_111_111_111_110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    //  modifier liquidated() {
    //     uint256 amountToMintLiquidated = 100 ether;
    //     uint256 amountCollateralLiquidated = 10 ether;
    //     uint256 collateralToCoverLiquidated = 20 ether;
    //     vm.startPrank(USER);
    //     ERC20Mock(weth).approve(address(dsce), amountCollateralLiquidated);
    //     dsce.depositCollateralAndMintDsc(weth, amountCollateralLiquidated, amountToMintLiquidated); //USER has $20000 eth collateral and $100 dsc minted
    //     vm.stopPrank();
    //     int256 ethUsdUpdatedPrice = 18e8; // 1 ETH = $18 // user now has $180 eth collateral and $100 dsc minted, health factor < 1

    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
    //     uint256 userHealthFactor = dsce.getHealthFactor(USER); // < 1

    //     ERC20Mock(weth).mint(LIQUIDATOR, collateralToCoverLiquidated);

    //     vm.startPrank(LIQUIDATOR);
    //     ERC20Mock(weth).approve(address(dsce), collateralToCoverLiquidated);
    //     dsce.depositCollateralAndMintDsc(weth, collateralToCoverLiquidated, amountToMintLiquidated); //LIQUIDATOR has $360 eth collateral and $100 dsc minted
    //     dsc.approve(address(dsce), amountToMintLiquidated);
    //     dsce.liquidate(weth, USER, amountToMintLiquidated); // We are covering their whole debt
    //     User now has $70 eth collateral and 0 dsc minted, health factor > 1
    //     LIQUIDATOR now has $469.99999999999999998 eth collateral and 0 dsc minted
    //     vm.stopPrank();
    //     _;
    // }

    function testUserStillHasSomeEthAfterLiquidation() public liquidated {
        uint256 amountToMintLiquidated = 100 ether;
        uint256 amountCollateralLiquidated = 10 ether;
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, amountToMintLiquidated)
            + (dsce.getTokenAmountFromUsd(weth, amountToMintLiquidated)
                * dsce.getLiquidationBonus()
                / dsce.getLiquidationPrecision()); // This is the amount in weth USER has to pay to LIQUIDATOR from being liquidated

        uint256 usdAmountLiquidated = dsce.getUSDvalue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd =
            dsce.getUSDvalue(weth, amountCollateralLiquidated) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70_000_000_000_000_000_020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function testLiquidatorKeepsTheirOwnDebtAfterLiquidation() public liquidated {
        uint256 amountToMintLiquidated = 100 ether;
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, amountToMintLiquidated);
    }

    function testUserHasNoMoreDebt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    ///////////////////////////////////
    // View & Pure Function Tests //
    //////////////////////////////////

    function testGetCollateralTokenPriceFeed() public {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function testGetCollateralTokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function testGetMinHealthFactor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function testGetLiquidationThreshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function testGetAccountCollateralValueFromInformation() public depositCollateral {
        address USER_WITH_10_ETH_COLLATERAL = makeAddr("USER_WITH_10_ETH_COLLATERAL");
        vm.startPrank(USER_WITH_10_ETH_COLLATERAL);
        ERC20Mock(weth).mint(USER_WITH_10_ETH_COLLATERAL, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        vm.stopPrank();

        (, uint256 collateralValue) = dsce.getAccountInformation(USER_WITH_10_ETH_COLLATERAL);
        uint256 expectedCollateralValue = dsce.getUSDvalue(weth, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        console.log(expectedCollateralValue);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetCollateralBalanceOfUser() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        vm.stopPrank();
        uint256 collateralBalance = dsce.getCollateralBalanceOfTheUser(USER, weth);
        assertEq(collateralBalance, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
    }

    function testGetAccountCollateralValue() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        vm.stopPrank();
        uint256 collateralValue = dsce.getAccountCollateralValue(USER);
        uint256 expectedCollateralValue = dsce.getUSDvalue(weth, AMOUNT_COLLATERAL_VIEW_FUNCTIONS);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function testGetDscAddress() public {
        address dscAddress = dsce.getDsc();
        assertEq(dscAddress, address(dsc));
    }

    function testLiquidationPrecision() public {
        uint256 expectedLiquidationPrecision = 100;
        uint256 actualLiquidationPrecision = dsce.getLiquidationPrecision();
        assertEq(actualLiquidationPrecision, expectedLiquidationPrecision);
    }

    // How do we adjust our invariant tests for this?
    // function testInvariantBreaks() public depositedCollateralAndMintedDsc {
    //     MockV3Aggregator(ethUsdPriceFeed).updateAnswer(0);

    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 wethDeposted = ERC20Mock(weth).balanceOf(address(dsce));
    //     uint256 wbtcDeposited = ERC20Mock(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, wethDeposted);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, wbtcDeposited);

    //     console.log("wethValue: %s", wethValue);
    //     console.log("wbtcValue: %s", wbtcValue);
    //     console.log("totalSupply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
