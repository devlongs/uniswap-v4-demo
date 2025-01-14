// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {PoolManager} from "v4-core/contracts/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPoolManager} from "v4-core/contracts/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

import {Currency} from "v4-core/contracts/types/Currency.sol";
import {PoolKey} from "v4-core/contracts/types/PoolKey.sol";
import {Hooks}   from "v4-core/contracts/libraries/Hooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {BalanceDelta} from "v4-core/contracts/types/BalanceDelta.sol";

import {TestERC20} from "../src/TestERC20.sol";

contract DeployV4Demo is Script {
    PoolManager public manager;
    PositionManager public posManager;

    TestERC20 public tokenA;
    TestERC20 public tokenB;

    function run() external {
        vm.startBroadcast();

        manager = new PoolManager(); 
        posManager = new PositionManager(IPoolManager(address(manager)), address(0)); 

        tokenA = new TestERC20("TokenA", "TKA", 18);
        tokenB = new TestERC20("TokenB", "TKB", 18);

        tokenA.mint(msg.sender, 1_000_000 ether);
        tokenB.mint(msg.sender, 1_000_000 ether);

        tokenA.approve(address(posManager), type(uint256).max);
        tokenB.approve(address(posManager), type(uint256).max);

        PoolKey memory poolKey = createPool(
            address(tokenA),
            address(tokenB),
            3000, 
            60   
        );


        mintFullRange(poolKey, 1000 ether, 1000 ether);

        doSwap(poolKey, 100 ether); 
        collectFees( 1, poolKey);

        vm.stopBroadcast();
    }

    function createPool(
        address addr0,
        address addr1,
        uint24 feePips,
        int24 tickSpacing
    ) internal returns (PoolKey memory poolKey) {
        address lower = addr0 < addr1 ? addr0 : addr1;
        address higher = lower == addr0 ? addr1 : addr0;

        poolKey = PoolKey({
            currency0: Currency.wrap(lower),
            currency1: Currency.wrap(higher),
            fee: feePips,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        manager.initialize(poolKey, sqrtPriceX96, bytes(""));

        return poolKey;
    }

    function mintFullRange(
        PoolKey memory poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal {
        int24 tickLower = -887272;
        int24 tickUpper =  887272;

        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        uint128 liquidity = 1e18; 

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Desired,
            amount1Desired,
            msg.sender,     
            bytes("")      
        );

        params[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1
        );

        posManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 600
        );
    }


    function doSwap(PoolKey memory poolKey, uint256 amountIn) internal {

        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true,         
            amountSpecified: int256(amountIn) * -1, 
        
            sqrtPriceLimitX96: 0,       
            callbackData: bytes("")
        });

        manager.swap(poolKey, sp);
    }

    function collectFees(uint256 tokenId, PoolKey memory poolKey) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            tokenId,
            0,     
            0,       
            0,       
            bytes("")
        );

        params[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1,
            msg.sender
        );

        posManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 600
        );
    }
}
