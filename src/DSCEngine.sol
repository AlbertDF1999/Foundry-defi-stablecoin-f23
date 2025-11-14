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

contract DSCEngige is ReentrancyGuard {
    ///////////////////
    // Errors
    ///////////////////

    error DSCEngine_NeedsMoreThanZero();
    error DSCEngige_TokenAddressesAndPriceFeedAddressMustBeSameLenght();
    error DSCEngige_NotAllowedToken();
    error DSCEngige_TransferFailed();
    error DSCEngige_BreaksHealthFactor(uint256 healthFactor);

    ///////////////////
    // State Variables
    ///////////////////

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;
    DecentralizedStableCoin private immutable i_dsc;

    ///////////////////
    // Events
    ///////////////////

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);

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
            revert DSCEngige_NotAllowedToken();
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
            revert DSCEngige_TokenAddressesAndPriceFeedAddressMustBeSameLenght();
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
        external
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngige_TransferFailed();
        }
    }

    function depositCollateralAndMintDsc() external {}

    function redeemCollateral() external {}

    /**
     *
     * @notice follows CEI pattern
     * @param amoutDscToMint: The amount of DSC you want to mint
     * @notice This function will mint DSC to the caller
     * @notice You must have enough collateral deposited to mint DSC
     */
    function mintDsc(uint256 amoutDscToMint) external moreThanZero(amoutDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amoutDscToMint;
        //if the health factor is too low, revert
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function redeemCollateralForDsc() external {}

    function burnDsc() external {}

    function liquidate() external {}

    function getHealthFactor() external view {}

    //////////////////////////////
    // Private & Internal View & Pure Functions
    //////////////////////////////

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
        uint256 collateralAdjustedForThreshold = (collateralValueInUSD * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    //get the health factor
    //if the health factor is less than the minimum, revert
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngige_BreaksHealthFactor(healthFactor);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    // External & Public View & Pure Functions
    ////////////////////////////////////////////////////////////////////////////

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
        (, int256 price,,,) = AggregatorV3Interface(s_priceFeeds[token]).latestRoundData();
        //1 eth = $1,000
        // the returned value from cl is 1000 * e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //1000 * e8 *(e10) * 1000 *1e18
    }
}
