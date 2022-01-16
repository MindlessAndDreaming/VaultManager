// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.11;

import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "./Withdrawable.sol";
import "./IERC20Stablecoin.sol";
import "./IMaticStablecoin.sol";
import "./ICamToken.sol";
import "./IAmToken.sol";
import "./ILendingPool.sol";

import "./IMooToken.sol";
import "./IStrategy.sol";



contract VaultManager is Withdrawable, IERC721Receiver {
    using SafeMath for uint256;

    address constant MAI_MATIC = 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1;
    enum VaultType { SingleToken, CamToken, MooSingleToken, MooLPToken }

    function receiveERC20Vault(
        address _vaultAddress, 
        uint256 _vaultID
    ) 
        external 
        onlyOwner
    {
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
        vault.safeTransferFrom(msg.sender, address(this), _vaultID);
    }

    function returnVault(
        address _vaultAddress, 
        uint256 _vaultID
    ) 
        external
        onlyOwner
    {
        if (_vaultAddress == MAI_MATIC) {
            IMaticStablecoin(MAI_MATIC).transferVault(_vaultID, msg.sender);
        } 
            else 
        {
            IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
            vault.safeTransferFrom(address(this), msg.sender, _vaultID);
        }
    }

    function onERC721Received(
        address , 
        address , 
        uint256 , 
        bytes memory 
    ) 
        public 
        virtual 
        override 
        returns (bytes4) 
    {
        return this.onERC721Received.selector;
    }

    function payERC20LoanAndWithhdrawCollateral (
        address _vaultAddress,
        uint256 _vaultID,
        bool _unwrap
    )
        internal
        returns (uint256, uint256)
    {
        
        // received the loan in MAI
        // find out how much is owed on qidao
        
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
        // vaultDebt in wei (MAI)
        uint256 vaultDebt = vault.vaultDebt(_vaultID);

        // ask for approval
        IERC20(vault.mai()).approve(_vaultAddress, vaultDebt);
        // ask the vaultContract to pull payment
        vault.payBackToken(_vaultID, vaultDebt);
        // withdraw collateral from the vaultContract
        uint256 withdrawableCollateralAmount = vault.vaultCollateral(_vaultID);
        if (_unwrap) {
            vault.withdrawCollateral(_vaultID, withdrawableCollateralAmount, _unwrap);
        } 

        else {
            vault.withdrawCollateral(_vaultID, withdrawableCollateralAmount);
        }  
        
        return (vaultDebt, withdrawableCollateralAmount);
    }

    function payMaticLoanWithdrawCollateral(
        uint256 _vaultID
    ) 
        internal
        returns (uint256, uint256)
    {
        IStablecoin vault = IStablecoin(MAI_MATIC);
        uint256 vaultDebt = vault.vaultDebt(_vaultID);
        // ask the vaultContract to pull payment
        vault.payBackToken(_vaultID, vaultDebt);
        // withdraw collateral from the vaultContract
        uint256 withdrawableCollateralAmount = vault.vaultCollateral(_vaultID);    
        vault.withdrawCollateral(_vaultID, withdrawableCollateralAmount);

        return (vaultDebt, withdrawableCollateralAmount);
    }


    function swapTokensForCamTokens (
        address _camTokenAddress,
        uint256 _minAcceptedTokens,
        address _fromToken,
        uint256 _maxOffered,
        address _routerAddress,
        address[] memory _path
    ) 
        public
        onlyOwner
    {
        // get the starting amount of amTokens
        address amTokenAddress = ICamToken(_camTokenAddress).Token();
        uint256 amTokenAmount = _minAcceptedTokens.mul(IERC20(amTokenAddress).balanceOf(_camTokenAddress)).div(IERC20(_camTokenAddress).totalSupply());// amToken amount == base Token amount

        // get the swap router
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        uint256[] memory amountsIn = swapRouter.getAmountsIn(amTokenAmount, _path);
        uint256 amountInMax = amountsIn[0].mul(101).div(100); // with max 1% slippage

        require (amountInMax <= _maxOffered, "TOO LITTLE OFFERED");
        IERC20(_fromToken).approve(address(swapRouter), amountInMax);

        // make the swap
        uint256[] memory amountsOut = swapRouter.swapExactTokensForTokens(
            amountInMax, 
            amTokenAmount, // equal to the token amount
            _path,
            address(this),
            block.timestamp
        );

        // deposit tokens for amtokens
        address underlyingAssetAddress = IAmToken(amTokenAddress).UNDERLYING_ASSET_ADDRESS();

        IERC20(underlyingAssetAddress).approve(ICamToken(_camTokenAddress).LENDING_POOL(), amountsOut[amountsOut.length - 1]); // all tokens received
        ILendingPool(ICamToken(_camTokenAddress).LENDING_POOL()).deposit(
            underlyingAssetAddress,
            amountsOut[amountsOut.length - 1],
            address(this),
            0
        );

        // deposit amTokens for camTokens

        IERC20(amTokenAddress).approve(_camTokenAddress, amountsOut[amountsOut.length - 1]); // tokens received equal to amtokens swapped
        ICamToken(_camTokenAddress).enter(amountsOut[amountsOut.length - 1]);
        // there are now CamTokens in the address
    }

    function swapCamTokensForTokens (
        address _maiVaultAddress,
        address _camTokenAddress,
        uint256 _minAccepted,
        address _routerAddress,
        address[] memory _path
    ) 
        public
        returns (uint256)
    {
        uint256 accepted = _minAccepted.mul(101).div(100); // angling for a 1% slippage
        // get camTokens to swap from the minimum accepted
        uint256 precision8price = IERC20Stablecoin(_maiVaultAddress).getEthPriceSource();
        uint256 camTokensToLiquidate = accepted.mul(1e8).div(precision8price);
        // predict how many amTokens we'll receive
        address amTokenAddress = ICamToken(_camTokenAddress).Token();
        uint256 amTokensReceived = camTokensToLiquidate.mul(IERC20(amTokenAddress).balanceOf(_camTokenAddress)).div(IERC20(_camTokenAddress).totalSupply());
        // unwrap camTokens to amTokens
        ICamToken(_camTokenAddress).leave(camTokensToLiquidate);

        // amTokens received == base tokens received
        // withdraw amtokens for tokens
        address lendingPool = ICamToken(_camTokenAddress).LENDING_POOL();
        address underlyingAssetAddress = IAmToken(amTokenAddress).UNDERLYING_ASSET_ADDRESS();
        // approve the lendingpool to take the amtokens to return actual tokens
        IERC20(amTokenAddress).approve(address(lendingPool), amTokensReceived);
        ILendingPool(lendingPool).withdraw(
            underlyingAssetAddress,
            amTokensReceived,
            address(this)
        );

        // we have received the underlying asset we can now swap to the required token
        // get the swap router
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        // make the swap
        IERC20(underlyingAssetAddress).approve(address(swapRouter), amTokensReceived);
        swapRouter.swapExactTokensForTokens(
            amTokensReceived, 
            _minAccepted, // equal to the token amount
            _path,
            address(this),
            block.timestamp
        );

        return camTokensToLiquidate;
    }
    
    function swapTokensForMooSingleTokens (
        address _mooTokenAddress,
        uint256 _minAcceptedTokens,
        address _fromToken,
        uint256 _maxOffered,
        address _routerAddress,
        address[] memory _path
    ) 
        public
        onlyOwner
    {
        // get the starting amount of the single tokens
        address tokenAddress = IMooToken(_mooTokenAddress).want();
        address stratAddress = IMooToken(_mooTokenAddress).strategy();
        // total value in token locked in moo contract
        uint256 totalTokenLocked = (IERC20(tokenAddress).balanceOf(_mooTokenAddress)).add(IStrategy(stratAddress).balanceOf());
        uint256 tokenAmount = _minAcceptedTokens.mul(totalTokenLocked).div(IERC20(_mooTokenAddress).totalSupply()); // amount of tokens I need to make the moo tokens minimum 
        
        uint256[] memory amountsIn = IUniswapV2Router02(_routerAddress).getAmountsIn(tokenAmount, _path);
        uint256 amountInMax = amountsIn[0].mul(101).div(100); // with max 3% slippage

        require (amountInMax <= _maxOffered, "TOO LITTLE OFFERED");
        IERC20(_fromToken).approve(_routerAddress, amountInMax);

        // make the swap
        uint256[] memory amountsOut = IUniswapV2Router02(_routerAddress).swapExactTokensForTokens(
            amountInMax,
            tokenAmount, // equal to the token amount
            _path,
            address(this),
            block.timestamp
        );

        // deposit tokens for moo tokens
        IERC20(tokenAddress).approve(_mooTokenAddress, amountsOut[amountsOut.length - 1]);
        IMooToken(_mooTokenAddress).deposit(amountsOut[amountsOut.length - 1]);

        // the address now has mootokens

    }

    function swapMooSingleTokensForTokens (
        address _maiVaultAddress,
        address _mooTokenAddress,
        uint256 _minAccepted,
        address _routerAddress,
        address[] memory _path
    ) 
        public
        returns (uint256)
    {
        uint256 accepted = _minAccepted.mul(101).div(100); // angling for a 3% slippage
        // get mooTokens to swap from the minimum accepted
        uint256 precision8price = IERC20Stablecoin(_maiVaultAddress).getEthPriceSource();
        uint256 mooTokensToLiquidate = accepted.mul(1e8).div(precision8price);
        // predict amount of tokens we get after withdrawal
        address tokenAddress = IMooToken(_mooTokenAddress).want();
        address stratAddress = IMooToken(_mooTokenAddress).strategy();
        // total value in token locked in moo contract
        uint256 totalTokenLocked = (IERC20(tokenAddress).balanceOf(_mooTokenAddress)).add(IStrategy(stratAddress).balanceOf());
        uint256 baseTokenAmount = mooTokensToLiquidate.mul(totalTokenLocked).div(IERC20(_mooTokenAddress).totalSupply()); // amount of tokens I need to make the moo tokens minimum 
        // approve mootoken contract to take mootokens in return for tokens
        IERC20(tokenAddress).approve(_mooTokenAddress, mooTokensToLiquidate);
        IMooToken(_mooTokenAddress).withdraw(mooTokensToLiquidate);

        // we have received the underlying asset we can now swap to the required token
        // get the swap router
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        // make the swap
        
        IERC20(tokenAddress).approve(address(swapRouter), baseTokenAmount);
        swapRouter.swapExactTokensForTokens(
            baseTokenAmount,
            _minAccepted, // equal to the token amount
            _path,
            address(this),
            block.timestamp
        );

        return mooTokensToLiquidate;
    }

    receive () external payable {}
}