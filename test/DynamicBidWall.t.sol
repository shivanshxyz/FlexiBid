// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {DynamicBidWallStrategy} from "../src/DynamicBidWallStrategy.sol";
import {DynamicBidWall} from "../src/DynamicBidWall.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {MockMemecoin} from "./MockMemecoin.sol";
import {MockPositionManager} from "./MockPositionManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PositionManager} from "@flaunch/PositionManager.sol";

contract DynamicBidWallTest is Test {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    DynamicBidWallStrategy public strategy;
    DynamicBidWall public bidWall;
    IPoolManager public poolManager;
    MockPositionManager public positionManager;
    MockMemecoin public memecoin;
    address public nativeToken;
    address public protocolOwner;
    
    // Pool variables
    PoolKey public poolKey;
    PoolId public poolId;

    error LookAtMe(string message, address caller);

    function setUp() public {
        // Setup mock contracts instead of relying on the fork
        nativeToken = makeAddr("nativeToken");
        protocolOwner = makeAddr("protocolOwner");
        
        // Create mock pool manager
        address poolManagerAddr = makeAddr("poolManager");
        poolManager = IPoolManager(poolManagerAddr);
        
        // Create a real mock position manager with all required parameters
        try new MockPositionManager(
            nativeToken,
            poolManagerAddr,
            protocolOwner
        ) returns (MockPositionManager _positionManager) {
            positionManager = _positionManager;
        } catch Error(string memory reason) {
            revert LookAtMe(reason, address(this));
        } catch {
            revert LookAtMe("unknown error in MockPositionManager creation", address(this));
        }
        
        // Create a memory address for memecoin 
        address memecoinAddr = makeAddr("memecoin");
        vm.etch(memecoinAddr, bytes("mock code"));
        memecoin = MockMemecoin(memecoinAddr);
        
        // Mock required functions for the memecoin
        vm.mockCall(
            address(memecoin),
            abi.encodeWithSelector(bytes4(keccak256("creator()"))),
            abi.encode(makeAddr("memeCreator"))
        );
        
        // Deploy our contracts with the mock addresses
        vm.startPrank(protocolOwner);  // Important: Deploy as protocolOwner
        strategy = new DynamicBidWallStrategy(
            nativeToken,
            poolManagerAddr,
            protocolOwner
        );
        
        bidWall = new DynamicBidWall(
            nativeToken,
            poolManagerAddr,
            protocolOwner,
            address(strategy)
        );
        
        // After both contracts are deployed, set the bidWall on the strategy
        strategy.setBidWall(address(bidWall));
        vm.stopPrank();
        
        // Initialize poolKey for tests
        address token0 = address(nativeToken) < address(memecoin) ? address(nativeToken) : address(memecoin);
        address token1 = address(nativeToken) < address(memecoin) ? address(memecoin) : address(nativeToken);
        
        poolKey = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 3000, // 0.3% fee tier
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        
        poolId = poolKey.toId();
        
        // Add any other necessary mocks for functions called in tests
        vm.mockCall(
            poolManagerAddr,
            abi.encodeWithSelector(bytes4(keccak256("getSlot0(bytes32)")), poolId),
            abi.encode(uint160(1 << 96), int24(0), uint24(0), uint24(3000)) // Example values
        );
    }
    
    function testStrategyDefaultBehavior() public {
        // Test default strategy (1 tick wide position)
        vm.startPrank(memecoin.creator());
        strategy.setPoolStrategy(poolKey, DynamicBidWallStrategy.StrategyType.DEFAULT);
        vm.stopPrank();
        
        vm.startPrank(address(bidWall));
        (int24 tickLower, int24 tickUpper) = strategy.calculateTickRange(
            poolKey,
            0, // current tick at 0
            true // native is zero
        );
        vm.stopPrank();
        
        // Should be 1 tick below and at tick boundary
        assertEq(tickLower, -60);
        assertEq(tickUpper, 0);
    }
    
    function testBalancedStrategy() public {
        // Test balanced strategy (moderate dynamic range)
        vm.startPrank(memecoin.creator());
        strategy.setPoolStrategy(poolKey, DynamicBidWallStrategy.StrategyType.BALANCED);
        vm.stopPrank();
        
        // Simulate some volatility by setting price changes
        vm.startPrank(address(bidWall));
        strategy.calculateTickRange(
            poolKey,
            0, // current tick at 0
            true // native is zero
        );
        
        // Price change to add volatility data point
        int24 newCurrentTick = 200;
        (int24 newTickLower, int24 newTickUpper) = strategy.calculateTickRange(
            poolKey,
            newCurrentTick,
            true
        );
        vm.stopPrank();
        
        // Range should be wider than default due to volatility
        int24 defaultWidth = 60; // 1 tick spacing
        int24 newWidth = newTickUpper - newTickLower;
        assertGt(newWidth, defaultWidth);
    }
    
    function testCustomStrategy() public {
        // Test custom strategy
        vm.startPrank(memecoin.creator());
        strategy.setCustomPoolStrategy(
            poolKey,
            20, // base width of 20 ticks
            5000 // 50% volatility factor
        );
        vm.stopPrank();
        
        vm.startPrank(address(bidWall));
        (int24 tickLower, int24 tickUpper) = strategy.calculateTickRange(
            poolKey,
            0, // current tick at 0
            true // native is zero
        );
        vm.stopPrank();
        
        // Should have wider range due to custom settings
        assertEq(tickUpper - tickLower, 1200); // 20 * 60 tick spacing
    }
    
    function testDynamicThresholds() public {
        // Test dynamic thresholds
        vm.startPrank(protocolOwner);
        bidWall.configureThresholds(
            true, // enable dynamic thresholds
            0.05 ether, // min threshold
            0.5 ether // max threshold
        );
        vm.stopPrank();
        
        // Mock cumulative swap fees
        // Test that threshold increases with higher fees
        uint lowFeesThreshold = bidWall.exposedGetSwapFeeThreshold(1 ether);
        uint highFeesThreshold = bidWall.exposedGetSwapFeeThreshold(50 ether);
        
        assertGt(highFeesThreshold, lowFeesThreshold);
    }

    function testBidWallDeposit() public {
        // Test dynamic thresholds
        vm.startPrank(protocolOwner);
        bidWall.configureThresholds(
            true, // enable dynamic thresholds
            0.05 ether, // min threshold
            0.5 ether // max threshold
        );
        vm.stopPrank();
        
        // First deposit below threshold
        uint256 preBidWallEthBalance = address(bidWall).balance;
        positionManager.depositFeesToBidWall(poolKey, 0.04 ether, true);
        uint256 postFirstDepositBalance = address(bidWall).balance;
        
        // Verify first deposit didn't trigger repositioning
        assertEq(postFirstDepositBalance - preBidWallEthBalance, 0.04 ether);
        
        // Second deposit - now we're above threshold
        positionManager.depositFeesToBidWall(poolKey, 0.02 ether, true);
        
        // Check if repositioning occurred by examining events or state changes
        // This would depend on your MockPositionManager implementation
        // assertEq(mockPositionManager.lastRepositionedPool(), poolId);
    }
}