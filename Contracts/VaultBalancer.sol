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
    {
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);

        if (vault.vaultDebt(_vaultID) == 0) {
            borrowMaiAndSendToOwner(_vaultAddress, _vaultID, vault.vaultCollateral(_vaultID), _desiredCollateralPercentage);
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
                borrowMaiAndSendToOwner(_vaultAddress, _vaultID, surplusCollateral, _desiredCollateralPercentage);

            }
        }
        returnVaultToSender(_vaultAddress, _vaultID, msg.sender);
    }

    function buyAndDepositCollateralIntoVault(
        address _vaultAddress, 
        uint256 _vaultID,
        VaultType _vaultType, 
        uint256 _shortfallCollateral,
        address _routerAddress,
        address[] memory _path
    ) 
        internal 
    {   
        
        //get the swap router
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        if (MAI_MATIC == _vaultAddress && block.chainid == 137) {
            
            // make the swap
            uint256[] memory amountsIn = swapRouter.getAmountsIn(_shortfallCollateral, _path);
            uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 1% slippage
                
            IERC20(MAI_MATIC).transferFrom(address(msg.sender), address(this), amountInMax);
            
            IERC20(MAI_MATIC).approve(address(swapRouter), amountInMax);
            
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
            
            this.receiveERC20Vault(_vaultAddress, _vaultID);
            
            SwapForCollateralDetails memory details = SwapForCollateralDetails (
                vault,
                _shortfallCollateral,
                swapRouter,
                _path
            );

            if (_vaultType == VaultType.CamToken ) {
                swapTokensForCamTokens(details);
            }

            else if (_vaultType == VaultType.MooSingleToken) {
                swapTokensForMooSingleTokens(details);
            }

            else if (_vaultType == VaultType.SingleToken){
                
                // get amount to put in
                uint256[] memory amountsIn = swapRouter.getAmountsIn(_shortfallCollateral, _path);
                uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 3% slippage
                IERC20(vault.mai()).transferFrom(address(msg.sender), address(this), amountInMax);
            
                IERC20(vault.mai()).approve(address(swapRouter), amountInMax);
            
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

    function borrowMaiAndSendToOwner(
        address _vaultAddress, 
        uint256 _vaultID, 
        uint256 _surplusCollateralAmount,
        uint256 _desiredCollateralPercentage
    ) 
        internal
    {
        // the borrow should be a percent of the collateral value
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);

        uint256 surplusCollateralValue = _surplusCollateralAmount.mul(vault.getEthPriceSource()).div( 10 ** 8 );
        uint256 borrowValue = surplusCollateralValue.mul(100).div(_desiredCollateralPercentage);

        vault.borrowToken(_vaultID, borrowValue);
        IERC20(vault.mai()).transfer(msg.sender, borrowValue);
    }
}