// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";
import {MockV3Aggregator} from "../../lib/chainlink-brownie-contracts/contracts/src/v0.8/tests/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dscEngine;
    HelperConfig config;
    address ethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    uint256 amountToMint = 100 ether;
    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL_DEPOSIT = 10 ether;
    uint256 public constant STARTING_USER_WETH_BALANCE = 50 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dscEngine, config) = deployer.run();
        (ethUsdPriceFeed, wbtcUsdPriceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_USER_WETH_BALANCE);
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    address[] tokenAddresses;
    address[] priceFeedAddresses;

    function testRevertsIfTokenAddressesLengthDoesntMatchPriceFeedsLength() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);
        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        dscEngine = new DSCEngine(tokenAddresses, priceFeedAddresses);
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE TESTS
    //////////////////////////////////////////////////////////////*/

    function testgetCollateralInUsdValue() public view {
        uint256 ethAmount = 15e18;
        // 15e18 ETH * $2000/ETH = $30,000e18
        uint256 expectedUsd = 30_000e18;
        uint256 usdValue = dscEngine.getCollateralInUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testGetTokeAmountFromUsd() public {
        uint256 usdAmountInWei = 100 ether;
        uint256 expectedWeth = 100 ether / 2000;

        uint256 tokenAmountFromUsd = dscEngine.getTokenAmountFromUsd(weth, usdAmountInWei);
        // assuming eth price ETH / $2000
        assertEq(tokenAmountFromUsd, expectedWeth);
    }

    /*//////////////////////////////////////////////////////////////
                        DEPOSIT COLLATERAL TESTS
    //////////////////////////////////////////////////////////////*/

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL_DEPOSIT);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL_DEPOSIT);
        vm.stopPrank();
        _;
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL_DEPOSIT);
        vm.expectRevert(DSCEngine.DSCEngine__MustBeMoreThanZero.selector);
        dscEngine.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock erc20mocked = new ERC20Mock("TOK", "TOK", USER, STARTING_USER_WETH_BALANCE);
        uint256 collateralAmount = 1e18;
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dscEngine.depositCollateral(address(erc20mocked), collateralAmount);
        vm.stopPrank();
    }

    function testRevertsIfMintedDscBreaksHealthFactor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        amountToMint = (AMOUNT_COLLATERAL_DEPOSIT * uint256(price) * dscEngine.getAdditionalFeedPrecision());
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL_DEPOSIT);
        uint256 expectedHealthFactor =
            dscEngine.calculateHealthFactor(amountToMint, dscEngine.getUsdValue(weth, AMOUNT_COLLATERAL_DEPOSIT));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dscEngine.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL_DEPOSIT, amountToMint);
        vm.stopPrank();
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dscEngine.getAccountInformation(USER);
        uint256 expectedtotalDscMinted = 0;
        uint256 expectedDepositAmount = dscEngine.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedtotalDscMinted);
        assertEq(AMOUNT_COLLATERAL_DEPOSIT, expectedDepositAmount);
    }

    function testCollateralDepositedEventIsEmitted() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dscEngine), AMOUNT_COLLATERAL_DEPOSIT);
        vm.expectEmit();
        emit DSCEngine.CollateralDeposited(USER, weth, AMOUNT_COLLATERAL_DEPOSIT);
        dscEngine.depositCollateral(weth, AMOUNT_COLLATERAL_DEPOSIT);
        vm.stopPrank();
    }
}
