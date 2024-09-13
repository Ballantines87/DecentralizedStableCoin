// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
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

/*
 * @title DecentralizedStableCoin
 * @author Paolo Monte
 * Collateral: Exogenous (ETH and BTC)
 * Stability Mechanism (Minting and Burning): Algorithmic
 * Anchored/Pegged Stable: to USD
 *
 * This is the contract that will be governed by the DSCEngine. This contract is just the ERC20 implementation of our stablecoin system.
 */

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountHigherThanAvailableBalance();
    error DecentralizedStableCoin__InvalidReceiverAddress(
        address receiverAddress
    );

    constructor()
        ERC20("DecentralizedStableCoin", "DSC")
        Ownable(address(0x0))
    {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);

        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }

        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountHigherThanAvailableBalance();
        }

        super.burn(_amount);
    }

    function mint(
        address _to,
        uint256 _amount
    ) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__InvalidReceiverAddress(address(0));
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__MustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}
