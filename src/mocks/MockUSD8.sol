// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Local stand-in for tUSD8 (6 decimals). Only used on anvil and in tests —
///         on Aevum testnet the vault points at the real tUSD8 contract.
contract MockUSD8 is ERC20 {
    constructor() ERC20("Mock tUSD8", "tUSD8") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
