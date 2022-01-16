// SPDX-License-Identifier: MIT
pragma solidity >=0.6.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IStrategy {
    function vault() external view returns (address);
    function want() external view returns (IERC20);
    function balanceOf() external view returns (uint256);
    function paused() external view returns (bool);
}
