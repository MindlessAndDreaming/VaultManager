// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.11;

import "./VaultManager.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";

contract VaultRepayer is VaultManager, IUniswapV2Callee {
    using SafeMath for uint256;

    function repay(
        address _vaultAddress, 
        uint256 _vaultID,
        VaultType _vaultType, 
        address _assetAddress, 
        uint256 _amountInHuman, 
        address _routerAddress,
        address _otherAssetAddress,
        address[] calldata _repaymentPath
    ) 
        public
        onlyOwner 
    { 

        // amount of mai being borrowed to repay the vault
        uint256 amount = _amountInHuman.mul(1e18);


        address pairAddress = IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(_assetAddress, _otherAssetAddress);
        require(pairAddress != address(0), "Pool ! exist");

        uint256 amountRequired = amount.mul(1000).div(996); // the amount required plus premium

        bytes memory params = abi.encode(
            _vaultAddress, 
            _vaultID,
            _vaultType, 
            _routerAddress, 
            _assetAddress, 
            amount, 
            amountRequired, 
            _repaymentPath
        );


        address token0 = IUniswapV2Pair(pairAddress).token0();
        address token1 = IUniswapV2Pair(pairAddress).token1();

        uint amount0 = _assetAddress == token0 ? amount : 0;
        uint amount1 = _assetAddress == token1 ? amount : 0;

        IUniswapV2Pair(pairAddress).swap(
            amount0, 
            amount1, 
            address(this), 
            params
        );
    }

    /**
        This function is called after your contract has received the flash loaned amount
     */

    function uniswapV2Call(
        address , 
        uint _amount0, 
        uint _amount1, 
        bytes calldata _data
    ) 
        external 
        override 
    {
        // msg.sender is the pair address 
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();

        (
            address _vaultAddress, 
            uint256 _vaultID,
            VaultType _vaultType, 
            address _routerAddress, 
            address _tokenReceived, 
            uint256 _amountReceived, 
            uint256 _amountRequired, 
            address[] memory _repaymentPath
        ) = abi.decode(_data, (address, uint256, VaultType, address, address, uint256, uint256, address[]));

        require(msg.sender == IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(token0, token1), "Unauthorized"); 
        require(_amount0 == 0 || _amount1 == 0, "There must be a zero asset");
        require(_amount0 != 0 || _amount1 != 0, "There must be a non zero asset");

        if (_vaultAddress == _tokenReceived) {
            // matic token vault
            repayNativeMAIVault(
                _routerAddress,
                _vaultID,
                _amountRequired - _amountReceived,
                _repaymentPath
            );            
        } else {
            repayTokenMAIVault(
                _routerAddress,
                _vaultAddress,
                _vaultID,
                _vaultType,
                _amountRequired - _amountReceived,
                _repaymentPath
            );
        }

        IERC20(_tokenReceived).transfer(msg.sender, _amountRequired);
    }

    function repayNativeMAIVault(
        address _routerAddress,
        uint256 _vaultID,
        uint256 _premiumOwed,
        address[] memory _path
    )
        internal
    {
        (uint256 vaultDebt, uint256 withdrawableCollateralAmount) = payMaticLoanWithdrawCollateral( _vaultID);
        
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        uint256 minAccepted = vaultDebt.add(_premiumOwed);
        uint256[] memory amountsIn = swapRouter.getAmountsIn(minAccepted, _path);
        uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 1% slippage
        
        // swap collateral for the loan asset
        uint256[] memory amountsOut = swapRouter.swapExactETHForTokens{value:amountInMax}(
            minAccepted,
            _path,
            address(this),
            block.timestamp
        );
        
        payable(address(owner())).transfer(withdrawableCollateralAmount.sub(amountsOut[0]));

    }

    function repayTokenMAIVault(
        address _routerAddress,
        address _vaultAddress,
        uint256 _vaultID,
        VaultType _vaultType,
        uint256 _premiumOwed,
        address[] memory _path
    ) 
        internal
    {
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        address collateralAddress = IERC20Stablecoin(_vaultAddress).collateral();

        (uint256 vaultDebt, uint256 withdrawableCollateralAmount) = payERC20LoanAndWithhdrawCollateral(_vaultAddress, _vaultID, (swapRouter.WETH() == collateralAddress));

        uint256 minAccepted = _premiumOwed.add(vaultDebt);

        if (_vaultType == VaultType.CamToken ) {
            swapAndWithdrawCamTokens(
                withdrawableCollateralAmount,
                _vaultAddress,
                collateralAddress,
                minAccepted,
                _routerAddress,
                _path
            );
        }

        else if (_vaultType == VaultType.MooSingleToken ) {
            swapAndWithdrawMooTokens(
                withdrawableCollateralAmount,
                _vaultAddress,
                collateralAddress,
                minAccepted,
                _routerAddress,
                _path
            );
        }

        else if (_vaultType == VaultType.SingleToken ) {
            // get amount to put in
            uint256[] memory amountsIn = swapRouter.getAmountsIn(minAccepted, _path);
            uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 3% slippage
            IERC20(collateralAddress).approve(address(swapRouter), amountInMax);
            // make the swap
            uint256[] memory amountsOut = swapRouter.swapTokensForExactTokens(
                minAccepted,
                amountInMax,
                _path,
                address(this),
                block.timestamp
            );

            uint256 surplusCollateral = withdrawableCollateralAmount - amountsOut[0];

            if (swapRouter.WETH() == collateralAddress) {
                payable(address(owner())).transfer(surplusCollateral);
            } else {
                IERC20(collateralAddress).transfer(owner(), surplusCollateral);
            }
        }

        

    }

    function swapAndWithdrawCamTokens(
        uint256 _withdrawableCollateralAmount,
        address _camVaultAddress,
        address _camTokenAddress,
        uint256 _minMAIAccepted,
        address _routerAddress,
        address[] memory _path
    )
        internal
    {
        uint256 liquidatedCamTokens = swapCamTokensForTokens(
            _camVaultAddress,
            _camTokenAddress,
            _minMAIAccepted,
            _routerAddress,
            _path
        ); 
        uint256 surplusCollateral = _withdrawableCollateralAmount - liquidatedCamTokens;
        IERC20(_camTokenAddress).transfer(owner(), surplusCollateral);
    }

    function swapAndWithdrawMooTokens(
        uint256 _withdrawableCollateralAmount,
        address _mooVaultAddress,
        address _mooTokenAddress,
        uint256 _minMAIAccepted,
        address _routerAddress,
        address[] memory _path
    )
        internal
    {
        uint256 liquidatedMooTokens = swapMooSingleTokensForTokens(
            _mooVaultAddress,
            _mooTokenAddress,
            _minMAIAccepted,
            _routerAddress,
            _path
        );
        uint256 surplusCollateral = _withdrawableCollateralAmount - liquidatedMooTokens;
        IERC20(_mooTokenAddress).transfer(owner(), surplusCollateral);
    }
}