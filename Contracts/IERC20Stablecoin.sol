// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;

/*
    @author MindlessAndDreaming
    @notice Interface for Erc20Stablecoin for MAI.

*/
interface IERC20Stablecoin {
    function vaultDebt(uint256 vaultID) external view returns ( uint256 );
    function vaultCollateral(uint256 vaultID) external view returns ( uint256 );
    function checkCollateralPercentage(uint256 vaultID) external view returns ( uint256 );
    function ownerOf(uint256 vaultID) external view returns ( address );

    function createVault() external returns (uint256);

    function exists(uint256 vaultID) external view returns (bool);
    function getClosingFee() external view returns (uint256);
    function getOpeningFee() external view returns (uint256);
    function getEthPriceSource() external view returns (uint256);
    function collateralDecimals() external view returns (uint256);
    function mai() external view returns ( address );
    function collateral() external view returns ( address );

    function payBackToken (uint256 vaultID, uint256 amount) external ;
    function depositCollateral(uint256 vaultID, uint256 amount) external;

    function borrowToken(uint256 vaultID, uint256 amount) external;
    function withdrawCollateral(uint256 vaultID, uint256 amount) external;
    function destroyVault(uint256 vaultID) external;
    function safeTransferFrom(address from, address to, uint256 vaultID) external;

    function approve(address to, uint256 vaultID) external;
}