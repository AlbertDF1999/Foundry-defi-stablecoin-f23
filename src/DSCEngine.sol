// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "../script/libraries/OracleLib.sol";
import {console} from "forge-std/Test.sol";

/*
 * @title DSCEngine
 * @author Alberto Castro
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg at all times.
 * This is a stablecoin with the properties:
 * - Exogenously Collateralized
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was backed by only WETH and WBTC.
 *
 * Our DSC system should always be "overcollateralized". At no point, should the value of
 * all collateral < the $ backed value of all the DSC.
 *
 * @notice This contract is the core of the Decentralized Stablecoin system. It handles all the logic
 * for minting and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is based on the MakerDAO DSS system
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    error DSCEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressMustBeSameLenght();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    ///////////////////
    // Types
    ///////////////////

    using OracleLib for AggregatorV3Interface;

    ///////////////////
    // State Variables
    ///////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18; //1.0
    uint256 private constant LIQUIDATOR_BONUS = 10; //this means 10% bonus
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    // Events
    ///////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

    event CollateralRedeemed(
        address indexed reedemedFrom, address indexed reedemedto, address indexed token, uint256 amount
    );

    ///////////////////
    // Modifiers
    ///////////////////

    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    ///////////////////
    // Functions
    ///////////////////

    constructor(address[] memory tokenAddreses, address[] memory priceFeedAddress, address dscAddress) {
        //USD Price Feeds
        //For example ETH/USD, BTC/USD, MRK/USD, etc...
        if (tokenAddreses.length != priceFeedAddress.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressMustBeSameLenght();
        }

        for (uint256 i = 0; i < tokenAddreses.length; i++) {
            s_priceFeeds[tokenAddreses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddreses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ///////////////////
    // External Functions
    ///////////////////

    /*
     * @notice follows CEI pattern
     * @param tokenCollateralAddress: The ERC20 token address of the collateral you're redeeming
     * @param amountCollateral: The amount of collateral you're redeeming
     * @notice This function will redeem your collateral.
     * @notice If you have DSC minted, you will not be able to redeem until you burn your DSC
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     *  This function will deposit collateral and mint DSC in one transaction
     *  tokenCollateralAddress the ERC20 token address of the collateral you're depositing
     *  amountCollateral the amount of collateral you're depositing
     *  amountDscToMint the amount of DSC you want to mint
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     *
     * @notice follows CEI pattern
     * @param amoutDscToMint: The amount of DSC you want to mint
     * @notice This function will mint DSC to the caller
     * @notice You must have enough collateral deposited to mint DSC
     */
    function mintDsc(uint256 amoutDscToMint) public moreThanZero(amoutDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amoutDscToMint;
        //if the health factor is too low, revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amoutDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    //in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral is pulled
    //
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     *
     * param tokenCollateralAddress the ERC20 token address of the collateral you're redeeming
     * param amountCollateral the amount of collateral you're redeeming
     * param amountToBurn the amount of DSC you want to burn
     * notice This function will redeem your collateral and burn DSC in one transaction.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountToBurn)
        external
    {
        burnDsc(amountToBurn);
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    //Do we need to see if the health factor is broken after burning DSC?
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); //I don't think this will ever hit
    }

    /*
     * @param collateralAddress: The ERC20 token address of the collateral you're using to make the protocol solvent again.
     * This is collateral that you're going to take from the user who is insolvent.
     * In return, you have to burn your DSC to pay off their debt, but you don't pay off your own.
     * @param user: The user who is insolvent. They have to have a _healthFactor below MIN_HEALTH_FACTOR
     * @param debtToCover: The amount of DSC you want to burn to cover the user's debt.
     *
     * @notice: You can partially liquidate a user.
     * @notice: You will get a 10% LIQUIDATION_BONUS for taking the users funds.
    * @notice: This function working assumes that the protocol will be roughly 150% overcollateralized in order for this
    to work.
    * @notice: A known bug would be if the protocol was only 100% collateralized, we wouldn't be able to liquidate
    anyone.
     * For example, if the price of the collateral plummeted before anyone could be liquidated.
     FOLLOWS CEI PATTERN
     */
    function liquidate(address collateralAddress, address user, uint256 debtToCover)
        external
        nonReentrant
        moreThanZero(debtToCover)
    {
        //Need to check health factor of user is broken
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        //We want to burn their DSC
        //we want to take their collateral + bonus
        //Bad user: $140 worth of ETH, $100 DSC minted
        //debtToCover = $100 DSC
        //$100 of DSC == ???? EHT?
        //Here we are basically tranfroming the users debt into eth, without includiing the bonus as compensation.
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralAddress, debtToCover);
        //and give them a 10% bonus
        //so we are giving the liquidator $110 worth of ETH for $100 worth of DSC
        //we should implement a feature to liquidate in the event the protocol is insolvent
        //aand sweep extra amounts into a treasury

        //.05eth * .1 = .005eth = .055eth total
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATOR_BONUS) / LIQUIDATION_PRECISION;
        //this amount is in ETH
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        //in _redeemCollateral we subract the collateral from the insolvent user
        //and transfer the debtToCover + bonus to the liquidator from dsc engine
        _redeemCollateral(collateralAddress, totalCollateralToRedeem, user, msg.sender);
        //in _burnDsc, we remove the dsc from the insolvent user,
        //transfer the dsc from the liquidator to dsc engine, and finally burn the dsc
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    // function getHealthFactor(address user) external view {
    //     _healthFactor(user);
    // }

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

    /**
     * low level internal function, do not call unless function calling it is
     * checking for health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        //this condition is hypothetical unreachable since transferFrom will revert if it fails
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUSD = getAccountCollateralValue(user);
    }

    /**
     * Check if a user is close to liquidation
     * If health factor is less than MIN_HEALTH_FACTOR, then the user is liquidatable
     */
    function _healthFactor(address user) private view returns (uint256) {
        //total dsc minted
        //total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUSD) = _getAccountInformation(user);

        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //get the health factor
    //if the health factor is less than the minimum, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(healthFactor);
        }
    }

    //This function is only for testing purposes
    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    ////////////////////////////////////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////

    function getHealthFactor(address user) public view returns (uint256) {
        return _healthFactor(user);
    }

    function getAccountInformation(address user)
        public
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUSD)
    {
        (totalDscMinted, collateralValueInUSD) = _getAccountInformation(user);
        return (totalDscMinted, collateralValueInUSD);
    }

    //amount in wei means that the $100 dollars are in terms of 1e18
    function getTokenAmountFromUsd(address collateralAddress, uint256 usdAmountInWei) public view returns (uint256) {
        //Price of eth (token)
        //usdAmountInWei in eth ?
        //$100 1e18 / $2000 per eth = .05 eth
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralAddress]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        //console.log(price);
        //$100e18 * 1e18 / ($2000 * 1e18) = .05e18
        uint256 amountToCoverInEther = (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
        // console.log(usdAmountInWei);
        // console.log(price);
        // console.log(amountToCoverInEther);
        return amountToCoverInEther;
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUSD) {
        //loop though each collateral token, get the amount deposited and the price, and sum it up
        //map the price to get value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUSD += getUSDvalue(token, amount);
        }

        return totalCollateralValueInUSD;
    }

    function getUSDvalue(address token, uint256 amount) public view returns (uint256) {
        //get the price feed address
        //get the price from the price feed
        //calculate the USD value
        (, int256 price,,,) = AggregatorV3Interface(s_priceFeeds[token]).staleCheckLatestRoundData();
        //1 eth = $1,000
        // the returned value from cl is 1000 * e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //1000 * e8 *(e10) * 1000 *1e18
    }

    //this test function is only for testing purposes
    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    ///////////////
    // GETTERS
    ///////////////

    function getUserBalanceInEth(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralBalanceOfTheUser(address user, address token) public view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getDscMinted(address user) public view returns (uint256) {
        return s_dscMinted[user];
    }

    function getAdditionalFeedPrecision() public pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getPrecision() public pure returns (uint256) {
        return PRECISION;
    }

    function getCollateralTokens() public view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralTokenPriceFeed(address tokenAddress) public view returns (address) {
        return s_priceFeeds[tokenAddress];
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }
}
