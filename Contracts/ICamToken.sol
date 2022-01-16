// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ICamToken is IERC20 {
    function Token() external view returns (address);
    function LENDING_POOL() external view returns (address);
    function enter( uint256 amount ) external ;
    function leave( uint256 share ) external ;
}
