// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.11;

import "./VaultManager.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";


contract VaultRepayer is VaultManager, IUniswapV2Callee {
    using SafeMath for uint256;

    struct FlashDetails { 
        address vaultAddress;
        uint256 vaultID;
        VaultType vaultType; 
        address routerAddress; 
        address tokenReceived; 
        uint256 amountReceived; 
        uint256 amountRequired; 
        address[] repaymentPath;
    }

    struct SwapAndWithdrawDetails {
        uint256 WithdrawableCollateralAmount;
        address VaultAddress;
        address CollateralAddress;
        uint256 MinMAIAccepted;
        address RouterAddress;
        address[] Path;
        address Sender;
    }

    function repayERC20Vault(
        address _vaultAddress,
        uint256 _vaultID,
        VaultType _vaultType,
        address _otherAssetAddress,
        address _routerAddress,
        address[] calldata _repaymentPath
    )
        external
        onlyOwner
    {
        requestERC20Vault(_vaultAddress, _vaultID, msg.sender);
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
        uint256 vaultDebt = vault.vaultDebt(_vaultID);
        address vaultMaiAddress = vault.mai();

        address pairAddress = IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(vaultMaiAddress, _otherAssetAddress);
        require(pairAddress != address(0), "Pool ! exist");

        uint256 amountRequired = vaultDebt.mul(1000).div(996); // the amount required plus premium

        bytes memory params = abi.encode(
            FlashDetails(
                _vaultAddress, 
                _vaultID,
                _vaultType, 
                _routerAddress, 
                vaultMaiAddress, 
                vaultDebt, 
                amountRequired, 
                _repaymentPath
            )
        );

        address token0 = IUniswapV2Pair(pairAddress).token0();
        address token1 = IUniswapV2Pair(pairAddress).token1();

        uint amount0 = vaultMaiAddress == token0 ? vaultDebt : 0;
        uint amount1 = vaultMaiAddress == token1 ? vaultDebt : 0;

        IUniswapV2Pair(pairAddress).swap(
            amount0, 
            amount1, 
            address(this), 
            params
        );
    }

    function repayMATICVault(
        address _vaultAddress, 
        uint256 _vaultID, 
        address _routerAddress,
        address _otherAssetAddress,
        address[] calldata _repaymentPath
    ) 
        external
        onlyOwner 
    { 

        // amount of mai being borrowed to repay the vault
        uint256 amount = IMaticStablecoin(_vaultAddress).vaultDebt(_vaultID);


        address pairAddress = IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(MAI_MATIC, _otherAssetAddress);
        require(pairAddress != address(0), "Pool ! exist");

        uint256 amountRequired = amount.mul(1000).div(996); // the amount required plus premium

        bytes memory params = abi.encode(
            FlashDetails(
                _vaultAddress, 
                _vaultID,
                VaultType.SingleToken, 
                _routerAddress, 
                MAI_MATIC, 
                amount, 
                amountRequired, 
                _repaymentPath
            )
        );


        address token0 = IUniswapV2Pair(pairAddress).token0();
        address token1 = IUniswapV2Pair(pairAddress).token1();

        uint amount0 = MAI_MATIC == token0 ? amount : 0;
        uint amount1 = MAI_MATIC == token1 ? amount : 0;

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

        FlashDetails memory flashDetails = abi.decode(_data, (FlashDetails));

        require(msg.sender == IUniswapV2Factory(IUniswapV2Router02(flashDetails.routerAddress).factory()).getPair(token0, token1), "Unauthorized"); 
        require(_amount0 == 0 || _amount1 == 0, "There must be a zero asset");
        require(_amount0 != 0 || _amount1 != 0, "There must be a non zero asset");
        

        if (flashDetails.vaultAddress == MAI_MATIC) {
            // matic token vault
            repayNativeMAIVault(
                flashDetails.routerAddress,
                flashDetails.vaultID,
                flashDetails.amountRequired - flashDetails.amountReceived,
                flashDetails.repaymentPath,
                owner()
            );     
        } else {
            repayTokenMAIVault(
                flashDetails.routerAddress,
                flashDetails.vaultAddress,
                flashDetails.vaultID,
                flashDetails.vaultType,
                flashDetails.amountRequired - flashDetails.amountReceived,
                flashDetails.repaymentPath,
                owner()
            );
            returnVaultToSender(flashDetails.vaultAddress, flashDetails.vaultID, owner());

        }

        IERC20(flashDetails.tokenReceived).transfer(msg.sender, flashDetails.amountRequired);
    }

    function repayNativeMAIVault(
        address _routerAddress,
        uint256 _vaultID,
        uint256 _premiumOwed,
        address[] memory _path,
        address _sender
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
        
        payable(address(_sender)).transfer(withdrawableCollateralAmount.sub(amountsOut[0]));

    }

    function repayTokenMAIVault(
        address _routerAddress,
        address _vaultAddress,
        uint256 _vaultID,
        VaultType _vaultType,
        uint256 _premiumOwed,
        address[] memory _path,
        address _sender
    ) 
        internal
    {
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        address collateralAddress = IERC20Stablecoin(_vaultAddress).collateral();

        (uint256 vaultDebt, uint256 withdrawableCollateralAmount) = payERC20LoanAndWithhdrawCollateral(_vaultAddress, _vaultID, (swapRouter.WETH() == collateralAddress));

        uint256 minAccepted = _premiumOwed.add(vaultDebt);

        SwapAndWithdrawDetails memory swapDetails = SwapAndWithdrawDetails(
            withdrawableCollateralAmount,
            _vaultAddress,
            collateralAddress,
            minAccepted,
            _routerAddress,
            _path,
            _sender
        );

        if (_vaultType == VaultType.CamToken ) {
            swapAndWithdrawCamTokens(swapDetails);
        }

        else if (_vaultType == VaultType.MooSingleToken ) {
            swapAndWithdrawMooTokens(swapDetails);
        }

        else if (_vaultType == VaultType.SingleToken ) {
            swapAndWithdrawSingleTokens(swapDetails);
        }
    }

    function swapAndWithdrawCamTokens(
        SwapAndWithdrawDetails memory details
    )
        internal
    {
        uint256 liquidatedCamTokens = swapCamTokensForTokens(
            details.VaultAddress,
            details.CollateralAddress,
            details.MinMAIAccepted,
            details.RouterAddress,
            details.Path
        ); 
        uint256 surplusCollateral = details.WithdrawableCollateralAmount - liquidatedCamTokens;
        IERC20(details.CollateralAddress).transfer(details.Sender, surplusCollateral);
    }

    function swapAndWithdrawMooTokens(
        SwapAndWithdrawDetails memory details
    )
        internal
    {
        uint256 liquidatedMooTokens = swapMooSingleTokensForTokens(
            details.VaultAddress,
            details.CollateralAddress,
            details.MinMAIAccepted,
            details.RouterAddress,
            details.Path
        );
        uint256 surplusCollateral = details.WithdrawableCollateralAmount - liquidatedMooTokens;
        IERC20(details.CollateralAddress).transfer(details.Sender, surplusCollateral);
    }

    function swapAndWithdrawSingleTokens (
        SwapAndWithdrawDetails memory details
    )
        internal
    {
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(details.RouterAddress);
        // get amount to put in
        uint256[] memory amountsIn = swapRouter.getAmountsIn(details.MinMAIAccepted, details.Path);
        uint256 amountInMax = amountsIn[0].mul(101).div(100); // with 1% slippage
        IERC20(details.CollateralAddress).approve(address(details.RouterAddress), amountInMax);
        // make the swap
        uint256[] memory amountsOut = swapRouter.swapTokensForExactTokens(
            details.MinMAIAccepted,
            amountInMax,
            details.Path,
            address(this),
            block.timestamp
        );

        uint256 surplusCollateral = details.WithdrawableCollateralAmount - amountsOut[0];

        if (swapRouter.WETH() == details.CollateralAddress) {
            payable(address(details.Sender)).transfer(surplusCollateral);
        } else {
            IERC20(details.CollateralAddress).transfer(details.Sender, surplusCollateral);
        }
    }
}
