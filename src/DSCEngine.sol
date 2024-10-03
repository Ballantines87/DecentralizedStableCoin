// SPDX-License-Identifier: MIT

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

pragma solidity ^0.8.20;

import {DecentralizedStableCoin} from "../src/DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Paolo Monte
 *
 * The system is designed to be as minimal as possible, and have the tokens maintain a 1 token == $1 peg
 * The stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 *
 * Our DSC System should always be "overcollateralized". At no point, should the value of all collateral <= the value of the $ dollar backed all the DSC.
 *
 * @notice This contract is the core of the DSC System. It handles all the logic for minting and redeeming DSC, as well as depositiing and withdrawing collateral.
 * @notice This contract is very loosely based on DAI on the MakerDAO DSS (DAI) system.
 */
contract DSCEngine is ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DSCEngine__MustBeMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__HealthFactorTooLow(uint256 healthFactor);
    error DSCEngine__HealthFactorNotImproved(uint256 endingHealthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsNotTooLow(uint256 healthFactor);
    error DSCEngine__BreaksHealthFactor();

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    using OracleLib for AggregatorV3Interface;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // meaning you have to be 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant LIQUIDATION_BONUS = 10;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;

    DecentralizedStableCoin immutable i_dsc;
    mapping(address token => address priceFeed) private s_priceFeeds; // s_tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 collateralDepositedAmount)) private
        s_collateralDepositedAmount;
    mapping(address user => uint256 amountDscMinted) private s_dscMinted;
    address[] private s_collateralTokens;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event CollateralDeposited(address indexed user, address indexed tokenDeposited, uint256 indexed depositedAmount);
    event DscBurned(address indexed user, uint256 indexed burnedAmount);
    event CollateralRedeemed(
        address indexed liquidatedFrom, address indexed sentTo, address indexed tokeAddress, uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/
    modifier moreThanZero(uint256 amount) {
        if (amount <= 0) {
            revert DSCEngine__MustBeMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address allowedTokenAddress) {
        // N.B. the default address that's returned if a token address is not present in the mapping is address(0)
        if (s_priceFeeds[allowedTokenAddress] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    constructor(address[] memory _tokenAddresses, address[] memory _priceFeedAddresses) {
        // USD Price Feeds
        if (_tokenAddresses.length != _priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        // For example ETH / USD, BTC / USD, MKR / USD, etc...
        for (uint256 i = 0; i < _tokenAddresses.length; i++) {
            s_priceFeeds[_tokenAddresses[i]] = _priceFeedAddresses[i];
            s_collateralTokens.push(_tokenAddresses[i]);
        }
        i_dsc = new DecentralizedStableCoin();
    }

    /*////////////////////////////////////////////
                External & Public Functions
    ////////////////////////////////////////////*/

    /**
     * @param collateralTokenAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of Dsc (decentralized stablecoin) the user wants to mint
     * @notice Combines the depositCollateral and mintDsc functions
     * @notice This function will deposit your collateral and mint Dsc in one transaction
     */
    function depositCollateralAndMintDsc(
        address collateralTokenAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(collateralTokenAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @param collateralTokenAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address collateralTokenAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(collateralTokenAddress)
        nonReentrant
    {
        s_collateralDepositedAmount[msg.sender][collateralTokenAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, collateralTokenAddress, amountCollateral);

        bool success = IERC20(collateralTokenAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param collateralTokenAddress The address of the token to redeem
     * @param amountCollateral The amount of collateral to redeem
     * @notice Combines the burnDsc and redeemCollateral functions
     * This function will burn your Dsc debt and redeem your deposited collateral in one transaction
     */
    function redeemCollateralForDsc(address collateralTokenAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(collateralTokenAddress, amountCollateral);
        // N.B.the redeemCollateral function ALREADY checks the Health Factor, so we don't need to check it here
    }

    // in order to redeem collateral:
    // 1. health factor must be over 1 AFTER collateral is pulled
    // DRY: Don't repeat yourself
    // Follows CEI: Checks, Effects, Interactions
    function redeemCollateral(address collateralTokenAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        // if it happens for example that the user tries to redeem 100 - 1000 -> the new versions of solidity will revert
        // automatically, because they don't allow to do this "unsafe math" stuff anymore
        _redeemCollateral(collateralTokenAddress, amountCollateral, msg.sender, msg.sender); // N.B. this is the case where one is calling the function FOR ONESELF
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint The amount of Dsc (decentralized stablecoin) the user wants to mint
     * @notice the collateral value must ALWAYS be MORE than the the minimum threshold
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_dscMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    // We don't need to check health factor because when we burn Dsc, we're burning/removing debt
    function burnDsc(uint256 amountDsc) public moreThanZero(amountDsc) nonReentrant {
        // if it happens for example that the user tries to redeem 100 - 1000 -> the new versions of solidity will revert
        // automatically, because they don't allow to do this "unsafe math" stuff anymore
        _burnDsc(amountDsc, msg.sender, msg.sender); // N.B. this is the case where one is calling the function FOR ONESELF

        // We likely don't need to check health factor because when we burn Dsc, we're burning/removing debt
        // but we're still adding this below here as an additional check before audit
        // which will point out if we need this line or not
        _revertIfHealthFactorIsBroken(msg.sender);
        emit DscBurned(msg.sender, amountDsc);
    }

    // if someone is undercollateralized, we will pay you to liquidate them

    /**
     * @param collateralTokenAddress The address of the ERC20 collateral to liquidate from the user
     * @param user The user who has broken the health factor. Their _healthFactor() should be below MIN_HEALTH_FACTOR
     * @param debtToCover The amount of DSC to burn that must be repaid to in place of the user in order to liquidate their position and improve their health factor
     * @notice You can *partially liquidate* a user, so long as you improve their health factor.
     * @notice You will get a "liquidation bonus" when successfully liquidating a user
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work. If the protocol were 100% collateralized or undercollateralized, then we wouldn't be able to incentivize the liquidators.
     *
     * Follows CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateralTokenAddress, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check the health factor of the user
        uint256 userStartingHealthFactor = _healthFactor(user);
        if (userStartingHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsNotTooLow(userStartingHealthFactor);
        }
        // We want to burn their DSC "debt" and take their collateral
        // E.g. bad user: $140 ETH, $100 DSC
        // Then debtToCover = $100 DSC
        // $100 DSC == ??? ETH
        // e.g. 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateralTokenAddress, debtToCover);
        // And give them a 10% bonus -
        // So, e.g., we are giving the liquidator $110 of WETH for 100 DSC
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        // N.B.  We should implement a feature to liquidate in the event the protocol is insolvent and sweep extra amounts into a treasury - not implemented here

        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateralTokenAddress, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorNotImproved(endingUserHealthFactor);
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function getTokenAmountFromUsd(address collateralTokenAddress, uint256 usdAmountInWei)
        public
        view
        returns (uint256)
    {
        // price of ETH (token)
        // if price is $ / ETH -> then ($ / ETH) / $ = ETH collateral amount from Usd amount
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[collateralTokenAddress]);
        (, int256 tokenPriceInUsd,,,) = priceFeed.staleCheckLatestRoundData();
        // e.g. let's say we have ($10e18 * 1e18) / ($2000e8 * 1e10) = 0.005 ETH ovvero 5e18 / 2000
        return (usdAmountInWei * PRECISION) / (uint256(tokenPriceInUsd) * ADDITIONAL_FEED_PRECISION);
    }

    function getHealthFactor() external view {}

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited, and map it to
        // the price to get the USD value
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address collateralTokenAddress = s_collateralTokens[i];
            uint256 collateralAmountDeposited = s_collateralDepositedAmount[user][collateralTokenAddress];
            totalCollateralValueInUsd += getCollateralInUsdValue(collateralTokenAddress, collateralAmountDeposited);
        }
        return totalCollateralValueInUsd;
    }

    function getCollateralInUsdValue(address collateralTokenAddress, uint256 amountOfToken)
        public
        view
        returns (uint256)
    {
        (, int256 tokenPriceInUsd,,,) =
            AggregatorV3Interface(s_priceFeeds[collateralTokenAddress]).staleCheckLatestRoundData();
        // the tokenPriceInUsd DOLLAR value will be expressed as VALUE times 1e8 (8 decimal places) - e.g. if 1 ETH = $1000 -> then $1000 * 1e8;
        // whereas the erc20 token has 18 decimal (1e18) places in general
        // tokenPriceInUsd    * amountOfToken
        // (1000 *1e8)*(1e10) * (1000 * 1e18);
        return ((uint256(tokenPriceInUsd) * ADDITIONAL_FEED_PRECISION) * amountOfToken) / PRECISION; // we divide by e18 to avoid having a massive number
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        view
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getUsdValue(
        address token,
        uint256 amount // in WEI
    ) external view returns (uint256) {
        return _getUsdValue(token, amount);
    }

    /*//////////////////////////////////////////////////////////////
                     Private & Internal View Functions
    //////////////////////////////////////////////////////////////*/

    function _getUsdValue(address token, uint256 amount) private view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.staleCheckLatestRoundData();
        // 1 ETH = 1000 USD
        // The returned value from Chainlink will be 1000 * 1e8
        // Most USD pairs have 8 decimals, so we will just pretend they all do
        // We want to have everything in terms of WEI, so we add 10 zeros at the end
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    function _redeemCollateral(
        address collateralTokenAddress,
        uint256 amountCollateral,
        address liquidateFrom,
        address sendLiquidationRewardsTo
    ) private {
        s_collateralDepositedAmount[liquidateFrom][collateralTokenAddress] -= amountCollateral;
        emit CollateralRedeemed(liquidateFrom, sendLiquidationRewardsTo, collateralTokenAddress, amountCollateral);

        bool success = IERC20(collateralTokenAddress).transfer(liquidateFrom, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     *
     * @dev low-level internal function -> do not call unless the function calling it is checking for health factors being broken
     * @param amountDscToBurn The Amount of DSC to burn
     * @param onBehalfOf Who's the original debtor
     * @param dscFrom Who's the user paying the Dsc in place of the debtor
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        private
        moreThanZero(amountDscToBurn)
    {
        s_dscMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _revertIfHealthFactorIsBroken(address user) internal view {
        // 1. Check health factor (do they have enough collateral?)
        // 2. Revert if they don't have good health factor
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorTooLow(userHealthFactor);
        }
    }

    /**
     *
     * Returns how close to a liquidation a user it
     * If a user goes below 1, then they can get liquidated
     */
    function _healthFactor(address user) private view returns (uint256) {
        // total Dsc minted
        // total collateral value
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        // this check is required in case someone deposits some collateral but hasn't yet minted ANY Dsc
        // if we didn't have the check, we would have a DIVISION BY 0 in the last return collateralAdjustedForThreshold * 1e18) / totalDscMinted; statement
        if (totalDscMinted == 0) {
            return type(uint256).max;
        }
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * 1e18) / totalDscMinted;
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_dscMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
        return (totalDscMinted, collateralValueInUsd);
    }

    function getDsc() public view returns (DecentralizedStableCoin) {
        return i_dsc;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDepositedAmount[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
