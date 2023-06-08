// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ERC20, ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title DecentralizedStablecoin
 * @author Chirag
 * Collateral: Exogenous (ETH & BTC)
 * Minting: Algorithmic
 * Relative Stability: Pegged to USD
 */
contract DecentralizedStablecoin is ERC20Burnable, Ownable {
    error DecentralizedStablecoin_BurnAmountExceedsBalance();

    constructor() ERC20("DecentralizedStablecoin", "DSC") {}

    function burn(uint256 amount) public override(ERC20Burnable) onlyOwner {
        // zero address check is implemented in ERC20._burn()

        if (balanceOf(msg.sender) < amount) {
            revert DecentralizedStablecoin_BurnAmountExceedsBalance();
        }

        super.burn(amount);
    }

    function mint(address to, uint256 amount) external onlyOwner {
        // zero address check is implemented in ERC20._mint()
        _mint(to, amount);
    }
}
