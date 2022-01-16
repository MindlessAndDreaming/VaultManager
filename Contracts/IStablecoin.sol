// SPDX-License-Identifier: MIT
pragma solidity ^0.8.11;


interface IStablecoin {
    function getDebtCeiling() external view returns (uint256);

	function getClosingFee() external view returns (uint256);
    function getOpeningFee() external view returns (uint256);

    function vaultDebt(uint256 vaultID) external view returns ( uint256 );
    function vaultCollateral(uint256 vaultID) external view returns ( uint256 );
    
    function borrowToken(uint256 vaultID, uint256 amount) external;
    function payBackToken(uint256 vaultID, uint256 amount) external;

    function getTokenPriceSource() external view returns (uint256);
    function getEthPriceSource() external view returns (uint256);
    
    function withdrawCollateral(uint256 vaultID, uint256 amount, bool unwrap) external;
    function withdrawCollateral(uint256 vaultID, uint256 amount) external;

    function createVault() external returns (uint256);
    function destroyVault(uint256 vaultID) external;
}