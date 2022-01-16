// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IAmToken is IERC20 {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
}
