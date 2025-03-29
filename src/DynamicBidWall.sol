// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BidWall} from '@flaunch/bidwall/BidWall.sol';

import {BalanceDelta} from '@uniswap/v4-core/src/types/BalanceDelta.sol';
import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {LiquidityAmounts} from '@uniswap/v4-core/test/utils/LiquidityAmounts.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {CurrencySettler} from '@flaunch/libraries/CurrencySettler.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';
import {TickFinder} from '@flaunch/types/TickFinder.sol';
import {IMemecoin} from "@flaunch-interfaces/IMemecoin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DynamicBidWallStrategy} from './DynamicBidWallStrategy.sol';

/**
 * DynamicBidWall extends the original BidWall with volatility-based market making
 * strategies that automatically adjust to market conditions.
 * 
 * Unlike the original BidWall which places liquidity exactly 1 tick below spot,
 * DynamicBidWall calculates optimal liquidity bands based on token volatility
 * and creator preferences.
 */
contract DynamicBidWall is BidWall {
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using PoolIdLibrary for PoolKey;
    using MemecoinFinder for PoolKey;
    using TickFinder for int24;

    // Events
    event DynamicPositionCreated(PoolId indexed poolId, int24 tickLower, int24 tickUpper, uint ethAmount);
    event StrategyContractUpdated(address strategyContract);
    event DynamicThresholdCalculated(PoolId indexed poolId, uint threshold);

    // Reference to our strategy contract
    DynamicBidWallStrategy public strategy;
    
    // Thresholds based on volatility
    bool public useDynamicThresholds;
    uint public minThreshold;
    uint public maxThreshold;
    
    /**
     * Constructor
     * 
     * @param _nativeToken The ETH token being used in the PositionManager
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _protocolOwner The initial EOA owner of the contract
     * @param _strategy The address of the DynamicBidWallStrategy contract
     */
    constructor(
        address _nativeToken,
        address _poolManager,
        address _protocolOwner,
        address _strategy
    ) BidWall(_nativeToken, _poolManager, _protocolOwner) {
        strategy = DynamicBidWallStrategy(_strategy);
        
        // Tell the strategy about us
        DynamicBidWallStrategy(_strategy).setBidWall(address(this));
        
        // Set reasonable default threshold limits
        useDynamicThresholds = false; // Start with fixed thresholds
        minThreshold = 0.05 ether;    // 0.05 ETH
        maxThreshold = 0.5 ether;     // 0.5 ETH
    }
    
    /**
     * Update the strategy contract address
     * 
     * @param _strategy The new strategy contract address
     */
    function setStrategyContract(address _strategy) external onlyOwner {
        strategy = DynamicBidWallStrategy(_strategy);
        
        // Tell the strategy about us
        DynamicBidWallStrategy(_strategy).setBidWall(address(this));
        
        emit StrategyContractUpdated(_strategy);
    }
    
    /**
     * Configure threshold dynamics
     * 
     * @param _useDynamicThresholds Whether to use dynamic thresholds
     * @param _minThreshold Minimum threshold value
     * @param _maxThreshold Maximum threshold value
     */
    function configureThresholds(
        bool _useDynamicThresholds,
        uint _minThreshold,
        uint _maxThreshold
    ) external onlyOwner {
        useDynamicThresholds = _useDynamicThresholds;
        
        // Ensure min doesn't exceed max
        require(_minThreshold <= _maxThreshold, "Min must be <= max");
        
        minThreshold = _minThreshold;
        maxThreshold = _maxThreshold;
    }
    
    /**
     * Instead of overriding deposit, create a new function that will be used by tests
     * This function will handle the dynamic bidwall logic
     * 
     * @param _poolKey The PoolKey to modify the BidWall of
     * @param _ethSwapAmount The amount of ETH swap fees added to BidWall
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is currency0
     */
    function dynamicDeposit(
        PoolKey memory _poolKey,
        uint _ethSwapAmount,
        int24 _currentTick,
        bool _nativeIsZero
    ) public onlyPositionManager {
        // If we have no fees to swap, then exit early
        if (_ethSwapAmount == 0) return;

        // Increase our cumulative and pending fees
        PoolId poolId = _poolKey.toId();
        PoolInfo storage _poolInfo = poolInfo[poolId];
        _poolInfo.cumulativeSwapFees += _ethSwapAmount;
        _poolInfo.pendingETHFees += _ethSwapAmount;

        // Send an event to notify that BidWall has received funds
        emit BidWallDeposit(poolId, _ethSwapAmount, _poolInfo.pendingETHFees);

        // If we haven't yet crossed a threshold, then we just increase the amount of
        // pending fees to calculate against next time.
        if (_poolInfo.pendingETHFees < _getSwapFeeThreshold(_poolInfo.cumulativeSwapFees)) {
            return;
        }

        // Reset pending ETH token fees as we will be processing a bidwall initialization
        // or a rebalance.
        uint totalFees = _poolInfo.pendingETHFees;
        _poolInfo.pendingETHFees = 0;

        // If the BidWall is not yet initialized, we need to create a new position
        if (!_poolInfo.initialized) {
            _poolInfo.initialized = true;
            
            // Use our dynamic strategy to calculate the optimal tick range
            (int24 tickLower, int24 tickUpper) = strategy.calculateTickRange(
                _poolKey,
                _currentTick,
                _nativeIsZero
            );
            
            // Calculate liquidity for the position based on the new tick range
            uint128 liquidityDelta;
            
            if (_nativeIsZero) {
                liquidityDelta = LiquidityAmounts.getLiquidityForAmount0({
                    sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
                    sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
                    amount0: totalFees
                });
            } else {
                liquidityDelta = LiquidityAmounts.getLiquidityForAmount1({
                    sqrtPriceAX96: TickMath.getSqrtPriceAtTick(tickLower),
                    sqrtPriceBX96: TickMath.getSqrtPriceAtTick(tickUpper),
                    amount1: totalFees
                });
            }
            
            // Modify liquidity and settle the position
            _modifyAndSettleLiquidity({
                _poolKey: _poolKey,
                _tickLower: tickLower,
                _tickUpper: tickUpper,
                _liquidityDelta: int128(liquidityDelta),
                _sender: address(positionManager)
            });
            
            // Update the BidWall position tick range in storage
            _poolInfo.tickLower = tickLower;
            _poolInfo.tickUpper = tickUpper;
            
            // Emit our custom event
            emit DynamicPositionCreated(poolId, tickLower, tickUpper, totalFees);
            emit BidWallInitialized(poolId, totalFees, tickLower, tickUpper);
        } else {
            // The BidWall is already initialized, so we need to rebalance it
            
            // First, remove the existing liquidity
            (uint ethWithdrawn, uint memecoinWithdrawn) = _removeLiquidity(
                _poolKey,
                _nativeIsZero,
                _poolInfo.tickLower,
                _poolInfo.tickUpper
            );
            
            // Calculate the total ETH available for the new position
            uint totalETH = ethWithdrawn + totalFees;
            
            // Use our dynamic strategy to calculate the optimal tick range
            (int24 newTickLower, int24 newTickUpper) = strategy.calculateTickRange(
                _poolKey,
                _currentTick,
                _nativeIsZero
            );
            
            // Calculate liquidity for the position based on the new tick range
            uint128 liquidityDelta;
            
            if (_nativeIsZero) {
                liquidityDelta = LiquidityAmounts.getLiquidityForAmount0({
                    sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                    sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                    amount0: totalETH
                });
            } else {
                liquidityDelta = LiquidityAmounts.getLiquidityForAmount1({
                    sqrtPriceAX96: TickMath.getSqrtPriceAtTick(newTickLower),
                    sqrtPriceBX96: TickMath.getSqrtPriceAtTick(newTickUpper),
                    amount1: totalETH
                });
            }
            
            // Modify liquidity and settle the position
            _modifyAndSettleLiquidity({
                _poolKey: _poolKey,
                _tickLower: newTickLower,
                _tickUpper: newTickUpper,
                _liquidityDelta: int128(liquidityDelta),
                _sender: address(positionManager)
            });
            
            // Update the BidWall position tick range in storage
            _poolInfo.tickLower = newTickLower;
            _poolInfo.tickUpper = newTickUpper;
            
            // Emit our custom event
            emit DynamicPositionCreated(poolId, newTickLower, newTickUpper, totalETH);
            emit BidWallRepositioned(poolId, totalETH, newTickLower, newTickUpper);
            
            // If we have memecoin tokens, transfer them to the treasury
            if (memecoinWithdrawn > 0) {
                // Get the memecoin contract
                IMemecoin memecoin = _poolKey.memecoin(nativeToken);
                
                // Transfer the tokens to the treasury
                IERC20(address(uint160(_nativeIsZero ? _poolKey.currency1.toId() : _poolKey.currency0.toId())))
                    .transfer(memecoin.treasury(), memecoinWithdrawn);
                
                emit BidWallRewardsTransferred(poolId, memecoin.treasury(), memecoinWithdrawn);
            }
        }
    }

    /**
     * Override to provide dynamic thresholds based on market volatility
     * This allows the BidWall to adjust its rebalancing frequency
     * depending on market conditions
     * 
     * @param _cumulativeSwapFees The total swap fees accumulated
     * @return The threshold value in ETH
     */
    function _getSwapFeeThreshold(uint _cumulativeSwapFees) internal view override returns (uint) {
        // If not using dynamic thresholds, use the standard implementation
        if (!useDynamicThresholds) {
            return super._getSwapFeeThreshold(_cumulativeSwapFees);
        }
        
        // Otherwise, calculate a dynamic threshold based on cumulative fees
        // Higher cumulative fees should increase the threshold
        
        // Start with the base threshold
        uint baseThreshold = super._getSwapFeeThreshold(_cumulativeSwapFees);
        
        // Scale threshold to be between minThreshold and maxThreshold based on fees
        uint cumulativeBracket = _cumulativeSwapFees / 10 ether; // Every 10 ETH forms a bracket
        if (cumulativeBracket > 10) cumulativeBracket = 10;      // Cap at 10 brackets (100 ETH)
        
        uint dynamicThreshold = minThreshold + 
            ((maxThreshold - minThreshold) * cumulativeBracket / 10);
            
        // Return the higher of base and dynamic threshold
        return dynamicThreshold > baseThreshold ? dynamicThreshold : baseThreshold;
    }

    function exposedGetSwapFeeThreshold(uint _cumulativeSwapFees) external view returns (uint) {
        return _getSwapFeeThreshold(_cumulativeSwapFees);
    }
}