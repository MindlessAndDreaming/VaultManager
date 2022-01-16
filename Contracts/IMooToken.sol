// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IMooToken is IERC20 {
    function want() external view returns (address);
    function strategy() external view returns (address);
    function deposit( uint256 amount ) external ;
    function withdraw( uint256 share ) external ;
}