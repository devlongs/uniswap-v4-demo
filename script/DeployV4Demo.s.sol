// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

// Core & Periphery
import {PoolManager} from "v4-core/contracts/PoolManager.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {IPoolManager} from "v4-core/contracts/interfaces/IPoolManager.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";

// Types & Libraries
import {Currency} from "v4-core/contracts/types/Currency.sol";
import {PoolKey} from "v4-core/contracts/types/PoolKey.sol";
import {Hooks}   from "v4-core/contracts/libraries/Hooks.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {BalanceDelta} from "v4-core/contracts/types/BalanceDelta.sol";

// Local test token
import {TestERC20} from "../src/TestERC20.sol";

contract DeployV4Demo is Script {
    PoolManager public manager;
    PositionManager public posManager;

    TestERC20 public tokenA;
    TestERC20 public tokenB;

    function run() external {
        // Start broadcast with the private key from .env or CLI
        vm.startBroadcast();

        // 1) Deploy Uniswap V4 PoolManager & PositionManager
        manager = new PoolManager(); 
        posManager = new PositionManager(IPoolManager(address(manager)), address(0)); 
        // address(0) for "permit2" in a local test, or real Permit2 on mainnet

        // 2) Deploy two test tokens for demonstration
        tokenA = new TestERC20("TokenA", "TKA", 18);
        tokenB = new TestERC20("TokenB", "TKB", 18);

        // 3) Mint some tokens to msg.sender
        tokenA.mint(msg.sender, 1_000_000 ether);
        tokenB.mint(msg.sender, 1_000_000 ether);

        // 4) Approve PositionManager to pull tokens
        tokenA.approve(address(posManager), type(uint256).max);
        tokenB.approve(address(posManager), type(uint256).max);

        // 5) Create a pool (TokenA < TokenB by address)
        PoolKey memory poolKey = createPool(
            address(tokenA),
            address(tokenB),
            3000, // 0.3% fee
            60    // tickSpacing
        );

        // 6) Mint a position (add liquidity)
        mintFullRange(poolKey, 1000 ether, 1000 ether);

        // 7) Optionally, do a quick swap from A -> B
        //    We'll do a direct call to manager.swap(...) for the example
        //    (In production, you'd likely use the Universal Router or aggregator)
        doSwap(poolKey, 100 ether); 

        // 8) Collect fees (if any)
        //    We'll do "decrease liquidity" with zero liquidity to just collect fees
        collectFees( /* tokenId = */ 1, poolKey);

        vm.stopBroadcast();
    }

    // -------------------------------------------------------------
    // Create a new v4 pool and initialize it at 1:1 price
    // -------------------------------------------------------------
    function createPool(
        address addr0,
        address addr1,
        uint24 feePips,
        int24 tickSpacing
    ) internal returns (PoolKey memory poolKey) {
        // sort addresses
        address lower = addr0 < addr1 ? addr0 : addr1;
        address higher = lower == addr0 ? addr1 : addr0;

        poolKey = PoolKey({
            currency0: Currency.wrap(lower),
            currency1: Currency.wrap(higher),
            fee: feePips,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(0))
        });

        // sqrtPriceX96 for 1:1
        uint160 sqrtPriceX96 = 79228162514264337593543950336;
        manager.initialize(poolKey, sqrtPriceX96, bytes(""));

        return poolKey;
    }

    // -------------------------------------------------------------
    // Mint a full-range position
    // -------------------------------------------------------------
    function mintFullRange(
        PoolKey memory poolKey,
        uint256 amount0Desired,
        uint256 amount1Desired
    ) internal {
        // full-range tick bounds:
        int24 tickLower = -887272;
        int24 tickUpper =  887272;

        // actions: MINT_POSITION + SETTLE_PAIR
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION),
            uint8(Actions.SETTLE_PAIR)
        );

        // We'll guess some large liquidity, e.g. 1e18
        uint128 liquidity = 1e18; 

        // parameters for MINT_POSITION
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            poolKey,
            tickLower,
            tickUpper,
            liquidity,
            amount0Desired,
            amount1Desired,
            msg.sender,     // who gets the position NFT
            bytes("")       // no hook data
        );

        // parameters for SETTLE_PAIR
        params[1] = abi.encode(
            poolKey.currency0,
            poolKey.currency1
        );

        // Execute
        posManager.modifyLiquidities(
            abi.encode(actions, params),
            block.timestamp + 600
        );

        // That minted a new position token with ID = 1 (since it’s the first position minted)
    }

    // -------------------------------------------------------------
    // Example direct swap on PoolManager
    // -------------------------------------------------------------
    function doSwap(PoolKey memory poolKey, uint256 amountIn) internal {
        // We'll do a simple "exact in" swap from currency0 -> currency1
        // because by address sorting, currency0 is tokenA

        // transfer in some tokenA from msg.sender to the manager
        // (We already did approve so let's just do the swap which triggers "flash accounting")

        IPoolManager.SwapParams memory sp = IPoolManager.SwapParams({
            zeroForOne: true,            // swap from currency0 -> currency1
            amountSpecified: int256(amountIn) * -1, 
               // negative means "exact input" in v4. 
               // e.g. -100 => we want to spend exactly 100 of currency0
            sqrtPriceLimitX96: 0,        // no limit
            callbackData: bytes("")
        });

        // Actually do the swap
        manager.swap(poolKey, sp);
    }

    // -------------------------------------------------------------
    // Collect fees by "decreasing liquidity with zero amount"
    // -------------------------------------------------------------
    function collectFees(uint256 tokenId, PoolKey memory poolKey) internal {
        bytes memory actions = abi.encodePacked(
            uint8(Actions.DECREASE_LIQUIDITY),
            uint8(Actions.TAKE_PAIR)
        );

        bytes[] memory params = new bytes[](2);
        // Decrease 0 liquidity => just collect fees
        params[0] = abi.encode(
            tokenId,
            0,        // liquidity
            0,        // minAmount0
            0,        // minAmount1
            bytes("")
        );

        // TAKE_PAIR: transfer tokens owed to msg.sender
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
