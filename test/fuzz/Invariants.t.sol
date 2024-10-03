// This Invariants file is gonna have our "Invariances" - aka our properties of the system that should *always hold

// Ask yourself: what are our Invariants? What are the PROPERTIES of our system that SHOULD ALWAYS HOLD
// 1. The total supply of DSC tokens should (always) be LESS than the total value of collateral
// 2. Getter view functions should NEVER revert <- this is sort of an "evergreen" invariant -> that is, most protocols can & should have probably just have an invariant that looks like this

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    Handler handler;
    address weth;
    address wbtc;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();
        // targetContract(address(dsce));
        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() external view {
        // get the value of all the collateral in the protocol
        // compare it to all the debt (aka all the DSC)
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 totalUsdValueOfWethDeposited = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 totalUsdValueOfWbtcDeposited = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("weth usd value:", totalUsdValueOfWethDeposited);
        console.log("wbtc usd value:", totalUsdValueOfWbtcDeposited);
        console.log("total supply:", totalSupply);
        console.log("Times mint is called:", handler.timesMintIsCalled());

        assert(totalUsdValueOfWethDeposited + totalUsdValueOfWbtcDeposited >= totalSupply);
    }

    function invariant_gettersShouldNeverRevert() external view {
        dsce.getAccountCollateralValue(msg.sender);
        dsce.getAccountInformation(msg.sender);
        dsce.getAdditionalFeedPrecision();
        dsce.getCollateralBalanceOfUser(weth, msg.sender);
        dsce.getCollateralBalanceOfUser(wbtc, msg.sender);
        dsce.getCollateralTokens();
        dsce.getDsc();
        dsce.getHealthFactor();
        dsce.getLiquidationBonus();
        dsce.getLiquidationThreshold();
        dsce.getMinHealthFactor();
        // dsce.getCollateralInUsdValue();
        // dsce.getTokenAmountFromUsd();
        // dsce.getUsdValue();
    }
}
