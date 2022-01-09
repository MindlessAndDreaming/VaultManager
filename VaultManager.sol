// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.11;


import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Callee.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";

import "./Withdrawable.sol";
import "./IERC20Stablecoin.sol";
import "./INativeStablecoin.sol";
import "./IMAI.sol";


contract VaultManager is Withdrawable, IERC721Receiver, IUniswapV2Callee {

    mapping (string => address[]) public paths;
    address MAI_MATIC = 0xa3Fa99A148fA48D14Ed51d610c367C61876997F1; 

    function repay(
        address _vaultAddress, 
        uint256 _vaultID, 
        address _assetAddress, 
        uint256 _amountInHuman, 
        address _routerAddress,
        address _otherAssetAddress
    ) 
        public
        onlyOwner 
    { 

        // amount of mai being borrowed to repay the vault
        uint256 amount = _amountInHuman * (10 ** ERC20(_assetAddress).decimals());


        address pairAddress = IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(_assetAddress, _otherAssetAddress);
        require(pairAddress != address(0), "There is no such pool");

        uint256 amountRequired = ( amount * 1000 ) / 996;

        bytes memory params = abi.encode(_vaultAddress, _vaultID, _routerAddress, _assetAddress, amount, amountRequired);


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

        (address _vaultAddress, uint256 _vaultID, address _routerAddress, address _tokenReceived, uint256 _amountReceived, uint256 _amountRequired) = abi.decode(_data, (address, uint256, address, address, uint256, uint256));

        require(msg.sender == IUniswapV2Factory(IUniswapV2Router02(_routerAddress).factory()).getPair(token0, token1), "Unauthorized"); 
        require(_amount0 == 0 || _amount1 == 0, "There must be a zero asset");
        require(_amount0 != 0 || _amount1 != 0, "There must be a non zero asset");

        if (_vaultAddress == _tokenReceived) {
            // matic token vault
            flashLogicToRepayNativeMAIVault(
                _routerAddress,
                _vaultAddress,
                _vaultID,
                _amountRequired - _amountReceived
            );            
        } else {
            flashLogicToRepayTokenMAIVault(
                _routerAddress,
                _vaultAddress,
                _vaultID,
                _amountRequired - _amountReceived
            );
        }

        ERC20(_tokenReceived).transfer(msg.sender, _amountRequired);
    }

   

    function flashLogicToRepayTokenMAIVault (
        address _routerAddress,
        address _vaultAddress,
        uint256 _vaultID,
        uint256 _premiumOwed
    )
        internal 
    {
        // received the loan in MAI
        // find out how much is owed on qidao
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
        // vaultDebt in wei (MAI)
        uint256 vaultDebt = vault.vaultDebt(_vaultID);

        // approve the vaultContract to pull the debt
        ERC20(vault.mai()).approve(_vaultAddress, vaultDebt);
        // ask the vaultContract to pull payment
        vault.payBackToken(_vaultID, vaultDebt);

        // withdraw collateral from the vaultContract
        uint256 withdrawableCollateralAmount = vault.vaultCollateral(_vaultID);

        if (vault.collateral() == IUniswapV2Router02(_routerAddress).WETH()) {
            INativeStablecoin(_vaultAddress).withdrawCollateral(_vaultID, withdrawableCollateralAmount, true);
            // swap collateral for the loan asset
            uint256 surplusCollateral = swapEthForToken(
                _routerAddress, 
                vault.mai(), 
                withdrawableCollateralAmount, 
                vaultDebt + _premiumOwed  // swap for the amount used to pay the vault debt and the premium
            );

            payable(address(owner())).transfer(surplusCollateral);
        } 
            else 
        {
            vault.withdrawCollateral(_vaultID, withdrawableCollateralAmount);
            // swap collateral for the loan asset
            uint256 surplusCollateral = swaptokenForToken(
                _routerAddress, 
                vault.collateral(), 
                vault.mai(), 
                withdrawableCollateralAmount, 
                vaultDebt + _premiumOwed  // swap for the amount used to pay the vault debt and the premium
            );

            //transfer the collateral to the owner Address
            ERC20(vault.collateral()).transfer(address(owner()), surplusCollateral);
        }

        

        // leaving enough to repay the loan + premium
    }

    function flashLogicToRepayNativeMAIVault(
        address _routerAddress,
        address _vaultAddress,
        uint256 _vaultID,
        uint256 _premiumOwed
    )
        internal
    {
        // received the loan in MAI
        // find out how much is owed on qidao
        IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
        // vaultDebt in wei (MAI)
        uint256 vaultDebt = vault.vaultDebt(_vaultID);


        // approve the vaultContract to pull the debt
        // ERC20(_vaultAddress).approve(_vaultAddress, vaultDebt);
        // ask the vaultContract to pull payment
        vault.payBackToken(_vaultID, vaultDebt);

        // withdraw collateral from the vaultContract
        uint256 withdrawableCollateralAmount = vault.vaultCollateral(_vaultID);
        vault.withdrawCollateral(_vaultID, withdrawableCollateralAmount);

        // swap collateral for the loan asset
        uint256 surplusCollateral = swapEthForToken(
             _routerAddress, 
             MAI_MATIC, 
             withdrawableCollateralAmount, 
             vaultDebt + _premiumOwed  // swap for the amount used to pay the vault debt and the premium
        );

        payable(address(owner())).transfer(surplusCollateral);

    }

    function swaptokenForToken(
        address _routerAddress, 
        address _from, 
        address _to, 
        uint256 _maxOffered, 
        uint256 _minAccepted
    ) 
        internal
        returns (uint256)  
    {
        address[] memory path;
        
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        string memory pathName = string(abi.encodePacked(ERC20(_from).symbol(), ERC20(_to).symbol()));
        address[] memory sPath = paths[pathName];
        
        if (sPath.length < 2 ) {
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            path = sPath;
        }


        uint256[] memory amountsIn = swapRouter.getAmountsIn(_minAccepted, path);
        
        require(amountsIn[0] <= _maxOffered, "UniswapV2Router: INCREASE MAX OFFER");
        
        ERC20(_from).approve(address(swapRouter), amountsIn[0]);

        swapRouter.swapExactTokensForTokens(
            amountsIn[0],
            _minAccepted,
            path,
            address(this),
            block.timestamp
        );

        return _maxOffered - amountsIn[0];
    }

    function swapEthForToken(
        address _routerAddress, 
        address _to, 
        uint256 _maxOffered, 
        uint256 _minAccepted
    ) 
        public
        returns (uint256)  
    {
        address[] memory path;
        
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        string memory pathName = string(abi.encodePacked(ERC20(swapRouter.WETH()).symbol(), ERC20(_to).symbol()));
        address[] memory sPath = paths[pathName];
        
        if (sPath.length < 2 ) {
            path = new address[](2);
            path[0] = swapRouter.WETH();
            path[1] = _to;
        } else {
            path = sPath;
        }

        uint256[] memory amountsIn = swapRouter.getAmountsIn(_minAccepted, path);
        
        require(amountsIn[0] <= _maxOffered, "UniswapV2Router: INCREASE MAX OFFER");
        
        uint256[] memory amounts = swapRouter.swapExactETHForTokens{value:amountsIn[0]}(
            _minAccepted,
            path,
            address(this),
            block.timestamp
        );

        return _maxOffered - amounts[0];
    }

    function swapTokenForEth(
        address _routerAddress, 
        address _from, 
        uint256 _maxOffered, 
        uint256 _minAccepted
    ) 
        public
        returns (uint256)  
    {
        address[] memory path;
        
        IUniswapV2Router02 swapRouter = IUniswapV2Router02(_routerAddress);
        
        string memory pathName = string(abi.encodePacked(ERC20(_from).symbol(), ERC20(swapRouter.WETH()).symbol()));
        address[] memory sPath = paths[pathName];
        
        if (sPath.length < 2 ) {
            path = new address[](2);
            path[0] = _from;
            path[1] = swapRouter.WETH();
        } else {
            path = sPath;
        }
        
        uint256[] memory amountsIn = swapRouter.getAmountsIn(_minAccepted, path);
        
        require(amountsIn[0] <= _maxOffered, "UniswapV2Router: INCREASE MAX OFFER");
        
        ERC20(_from).approve(address(swapRouter), amountsIn[0]);

        uint256[] memory amounts = swapRouter.swapExactTokensForETH(
            amountsIn[0],
            _minAccepted,
            path,
            address(this),
            block.timestamp
        );

        return _maxOffered - amounts[0];
    }

    function returnVault(
        address _vaultAddress, 
        uint256 _vaultID
    ) 
        external
        onlyOwner
    {
        if (_vaultAddress == MAI_MATIC) {
            IMAI(MAI_MATIC).transferVault(_vaultID, address(owner()));
        } else {
            IERC721 vault = IERC721(_vaultAddress);
            vault.safeTransferFrom(address(this), address(owner()), _vaultID);
        }
    }

    function receiveVault(
        address _vaultAddress, 
        uint256 _vaultID
    ) 
        external 
    {
        require(_vaultAddress != MAI_MATIC, "Not supported on Native MATIC Vault");
        IERC721 vault = IERC721(_vaultAddress);
        vault.safeTransferFrom(msg.sender, address(this), _vaultID);
    
    }

    function savePath (
        address[] memory path
    ) 
        external 
        onlyOwner 
    {
        string memory pathName = string(abi.encodePacked(ERC20(path[0]).symbol(), ERC20(path[path.length-1]).symbol()));
        paths[pathName] = path;
    }

    function rebalanceVault(
        address _vaultAddress, 
        uint256 _desiredCollateralPercentage, 
        uint256 _vaultID,
        address _routerAddress
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
                uint256 collateralValue = (vault.vaultCollateral(_vaultID) * vault.getEthPriceSource()) / ( 10 ** 8 );
                collateralPercentage = (collateralValue * 100) / vault.vaultDebt(_vaultID);    
            } else {
                collateralPercentage = vault.checkCollateralPercentage(_vaultID);
            }

            uint256 desiredCollateral = (_desiredCollateralPercentage * vault.vaultCollateral(_vaultID)) / collateralPercentage;

            if(desiredCollateral > vault.vaultCollateral(_vaultID) ) {
                uint256 shortfallCollateral = desiredCollateral - vault.vaultCollateral(_vaultID);
                buyAndDepositCollateralIntoVault(_vaultAddress, _vaultID, shortfallCollateral, _routerAddress);
            } else if (desiredCollateral < vault.vaultCollateral(_vaultID) ) {
                uint256 surplusCollateral = vault.vaultCollateral(_vaultID) - desiredCollateral;
                borrowMaiFromVault(_vaultAddress, _vaultID, surplusCollateral, _desiredCollateralPercentage);
            }
        }
    }

    function buyAndDepositCollateralIntoVault(
        address _vaultAddress, 
        uint256 _vaultID, 
        uint256 _shortfallCollateral,
        address _routerAddress
    ) 
        public
        onlyOwner 
    {   
        uint256 availableMAI;

        if (MAI_MATIC == _vaultAddress && block.chainid == 137) {
            // Swap For the collateral
            availableMAI = IERC20(MAI_MATIC).balanceOf(address(this));
            swapTokenForEth(_routerAddress, MAI_MATIC, availableMAI, _shortfallCollateral);
            IMAI(MAI_MATIC).depositCollateral{value:_shortfallCollateral}(_vaultID);
        } else {
            IERC20Stablecoin vault = IERC20Stablecoin(_vaultAddress);
            // Swap For the collateral
            availableMAI = IERC20(vault.mai()).balanceOf(address(this));
            swaptokenForToken(_routerAddress, vault.mai(), vault.collateral(), availableMAI, _shortfallCollateral);
            // deposit collateral in vault
            IERC20(vault.collateral()).approve(address(vault), _shortfallCollateral);
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

        uint256 surplusCollateralValue = (_surplusCollateralAmount * vault.getEthPriceSource()) / ( 10 ** 8 );
        uint256 borrowValue = (surplusCollateralValue * 100) / _desiredCollateralPercentage;

        vault.borrowToken(_vaultID, borrowValue);
    }

    function withdrawERC721(
        address _nftAddress, 
        uint256 _nftID
    ) 
        external 
        onlyOwner 
    {
        IERC721 nft = IERC721(_nftAddress);
        nft.safeTransferFrom(address(this), address(owner()), _nftID);
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

    receive () external payable {}
}
