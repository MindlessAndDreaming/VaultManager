// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

/*
    @author MindlessAndDreaming
    @notice Interface for MATIC MAI Stablecoin.

*/
interface IMAI {
    function erc721() external view returns (address);
    function depositCollateral(uint256 vaultID)  external payable;
    function transferVault(uint256 vaultID, address to) external;
}
