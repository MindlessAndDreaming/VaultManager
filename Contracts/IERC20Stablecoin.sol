// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

import "./IStablecoin.sol";

/*
    @author MindlessAndDreaming
    @notice Interface for Erc20Stablecoin for MAI.

*/
interface IERC20Stablecoin is IStablecoin{
    function checkCollateralPercentage(uint256 vaultID) external view returns ( uint256 );
    function ownerOf(uint256 vaultID) external view returns ( address );

    function exists(uint256 vaultID) external view returns (bool);
    
    function collateralDecimals() external view returns (uint256);
    
    function mai() external view returns ( address );
    function collateral() external view returns ( address );

    function depositNative(uint256 vaultID) external payable;
    function depositCollateral(uint256 vaultID, uint256 amount) external;

    function safeTransferFrom(address from, address to, uint256 vaultID) external;
    function approve(address to, uint256 vaultID) external;
}