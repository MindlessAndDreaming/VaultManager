// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./IStablecoin.sol";

interface IMaticStablecoin is IStablecoin{	
    function transferVault(uint256 vaultID, address to) external;
    function depositCollateral(uint256 vaultID) external payable;

    function erc721() external returns (address);
}