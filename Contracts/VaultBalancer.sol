// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.11;


import "./VaultManager.sol";

contract VaultBalancer is VaultManager {
    using SafeMath for uint256;
    
    function rebalanceVault(
        address _vaultAddress, 
        uint256 _vaultID,
        VaultType _vaultType,
        uint256 _desiredCollateralPercentage, 
        address _routerAddress,
        address[] memory _path
    ) 
        external
        onlyOwner
    {
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);

        if (vault.vaultDebt(_vaultID) == 0) {
            borrowMaiFromVault(_vaultAddress, _vaultID, vault.vaultCollateral(_vaultID), _desiredCollateralPercentage);
        } else {
            uint256 collateralPercentage;

            if (MAI_MATIC == _vaultAddress) {
                uint256 collateralValue = vault.vaultCollateral(_vaultID).mul(vault.getEthPriceSource()).div( 10 ** 8 );
                collateralPercentage = collateralValue.mul(100).div(vault.vaultDebt(_vaultID));    
            } else {
                collateralPercentage = vault.checkCollateralPercentage(_vaultID);
            }

            uint256 desiredCollateral = _desiredCollateralPercentage.mul(vault.vaultCollateral(_vaultID)).div(collateralPercentage);

            if(desiredCollateral > vault.vaultCollateral(_vaultID) ) {
                uint256 shortfallCollateral = desiredCollateral - vault.vaultCollateral(_vaultID);
                buyAndDepositCollateralIntoVault(_vaultAddress, _vaultID, _vaultType, shortfallCollateral, _routerAddress, _path);
            } else if (desiredCollateral < vault.vaultCollateral(_vaultID) ) {
                uint256 surplusCollateral = vault.vaultCollateral(_vaultID) - desiredCollateral;
                borrowMaiFromVault(_vaultAddress, _vaultID, surplusCollateral, _desiredCollateralPercentage);
            }
        }
    }

    function buyAndDepositCollateralIntoVault(
        address _vaultAddress, 
        uint256 _vaultID,
        VaultType _vaultType, 
        uint256 _shortfallCollateral,
        address _routerAddress,
        address[] memory _path
    ) 
        public
        onlyOwner 
    {   
        uint256 availableMAI;

        //get the swap router
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        if (MAI_MATIC == _vaultAddress && block.chainid == 137) {
            // all MAI vailable
            availableMAI = IERC20(MAI_MATIC).balanceOf(address(this));
            // approve the swaprouter for trade
            IERC20(MAI_MATIC).approve(address(swapRouter), availableMAI);
            // make the swap
            uint256[] memory amountsIn = swapRouter.getAmountsIn(_shortfallCollateral, _path);
            uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 3% slippage
                
            swapRouter.swapExactTokensForETH(
                amountInMax,
                _shortfallCollateral,
                _path,
                address(this),
                block.timestamp
            );
            // deposit the collaterall gianed into the vault
            IMaticStablecoin(MAI_MATIC).depositCollateral{value:_shortfallCollateral}(_vaultID);
        } 
            else 
        {
            IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
            // get the MAI available
            availableMAI = IERC20(vault.mai()).balanceOf(address(this));
                
            if (_vaultType == VaultType.CamToken ) {
                swapTokensForCamTokens(
                    vault.collateral(),
                    _shortfallCollateral,
                    vault.mai(),
                    availableMAI,
                    _routerAddress,
                    _path
                );
            }

            else if (_vaultType == VaultType.MooSingleToken) {
                swapTokensForMooSingleTokens(
                    vault.collateral(),
                    _shortfallCollateral,
                    vault.mai(),
                    availableMAI,
                    _routerAddress,
                    _path
                );
            }

            else if (_vaultType == VaultType.SingleToken){
                // approve the swaprouter for trade
                IERC20(vault.mai()).approve(address(swapRouter), availableMAI);
                // get amount to put in
                uint256[] memory amountsIn = swapRouter.getAmountsIn(_shortfallCollateral, _path);
                uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 3% slippage
                // make the swap
                swapRouter.swapExactTokensForTokens(
                    amountInMax,
                    _shortfallCollateral,
                    _path,
                    address(this),
                    block.timestamp
                );
            }
            // deposit collateral in vault after approval
            IERC20(vault.collateral()).approve(_vaultAddress, _shortfallCollateral);
            vault.depositCollateral(_vaultID, _shortfallCollateral);
        }
    }

    function borrowMaiFromVault(
        address _vaultAddress, 
        uint256 _vaultID, 
        uint256 _surplusCollateralAmount,
        uint256 _desiredCollateralPercentage
    ) 
        public
        onlyOwner 
    {
        // the borrow should be a percent of the collateral value
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);

        uint256 surplusCollateralValue = _surplusCollateralAmount.mul(vault.getEthPriceSource()).div( 10 ** 8 );
        uint256 borrowValue = surplusCollateralValue.mul(100).div(_desiredCollateralPercentage);

        vault.borrowToken(_vaultID, borrowValue);
    }
}