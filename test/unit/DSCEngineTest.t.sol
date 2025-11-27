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

contract DSCEngineTest is Test {
    DeployDSCEngine deployer;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    DSCEngine dsce;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;
    address weth;
    address wbtc;

    address USER = makeAddr("USER");
    uint256 public constant AMOUNT_COLLATERAL = 100 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 100 ether;
    uint256 public constant AMOUNT_TO_MINT = 10 ether;
    uint256 public amountToMint;

    function setUp() external {
        deployer = new DeployDSCEngine();
        (dsce, dsc, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPriceFeed, weth, wbtc,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, AMOUNT_COLLATERAL);
        ERC20Mock(wbtc).mint(USER, AMOUNT_COLLATERAL);
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

    modifier depositCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

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

    modifier depositCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, AMOUNT_TO_MINT);
        vm.stopPrank();
        _;
    }

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
}
