// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Ownable} from '@solady/auth/Ownable.sol';

import {Currency, CurrencyLibrary} from '@uniswap/v4-core/src/types/Currency.sol';
import {IPoolManager} from '@uniswap/v4-core/src/interfaces/IPoolManager.sol';
import {PoolId, PoolIdLibrary} from '@uniswap/v4-core/src/types/PoolId.sol';
import {PoolKey} from '@uniswap/v4-core/src/types/PoolKey.sol';
import {StateLibrary} from '@uniswap/v4-core/src/libraries/StateLibrary.sol';
import {TickMath} from '@uniswap/v4-core/src/libraries/TickMath.sol';

import {TickFinder} from '@flaunch/types/TickFinder.sol';
import {MemecoinFinder} from '@flaunch/types/MemecoinFinder.sol';
import {IMemecoin} from '@flaunch-interfaces/IMemecoin.sol';

/**
 * DynamicBidWallStrategy provides advanced market making strategies for the BidWall
 * that adapt to market conditions and volatility.
 * 
 * This contract works alongside the DynamicBidWall to provide more sophisticated
 * liquidity positioning that can respond to market volatility.
 */
contract DynamicBidWallStrategy is Ownable {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using MemecoinFinder for PoolKey;
    using TickFinder for int24;

    // Error definitions
    error CallerIsNotCreator();
    error InvalidStrategyType();
    error InvalidStrategyParameters();
    error NotPositionManagerOrBidWall();

    // Strategy types
    enum StrategyType {
        DEFAULT,    // Original BidWall behavior (1 tick below spot)
        BALANCED,   // Moderate range that adapts to volatility
        AGGRESSIVE, // Wide range that adapts aggressively to volatility
        CUSTOM      // Custom configuration
    }
    
    // Strategy parameters
    struct Strategy {
        StrategyType strategyType;
        uint8 baseWidth;         // Base width of position in ticks
        uint16 volatilityFactor; // How much volatility affects position width (0-10000)
        bool enabled;            // If strategy is enabled
    }
    
    // Volatility tracking
    struct VolatilityData {
        uint32 timestamp;
        uint160 sqrtPriceX96;
        uint8 volatilityScore;   // 0-100 score representing recent volatility
    }
    
    // Events
    event StrategyUpdated(PoolId indexed poolId, StrategyType strategyType);
    event VolatilityCalculated(PoolId indexed poolId, uint8 volatilityScore);
    event TickRangeCalculated(PoolId indexed poolId, int24 tickLower, int24 tickUpper);
    
    // Constants
    uint constant internal _BASIS_POINTS = 10000;
    
    // Uniswap V4 PoolManager
    IPoolManager public immutable poolManager;
    
    // The native token used in the Flaunch protocol
    address public immutable nativeToken;
    
    // Allowed callers
    address public immutable positionManager;
    address public bidWall;

    // Maximum volatility history to keep per pool
    uint8 public constant MAX_VOLATILITY_HISTORY = 10;
    
    // Mappings
    mapping(PoolId => Strategy) public poolStrategies;
    mapping(PoolId => VolatilityData[]) private _volatilityHistory;
    mapping(PoolId => PoolKey) private _poolKeys;
    
    /**
     * Constructor
     * 
     * @param _nativeToken The ETH token being used in the PositionManager
     * @param _poolManager The Uniswap V4 PoolManager
     * @param _protocolOwner The initial EOA owner of the contract
     */
    constructor(
        address _nativeToken,
        address _poolManager,
        address _protocolOwner
    ) {
        nativeToken = _nativeToken;
        poolManager = IPoolManager(_poolManager);
        positionManager = msg.sender;
        
        _initializeOwner(_protocolOwner);
    }
    
    /**
     * Set the BidWall address that can call this contract
     * 
     * @param _bidWall The address of the DynamicBidWall contract
     */
    function setBidWall(address _bidWall) external onlyOwner {
        bidWall = _bidWall;
    }
    
    /**
     * Initialize the bidwall address - can only be called by position manager
     * This is used during initial setup and is separate from setBidWall
     * 
     * @param _bidWall The address of the DynamicBidWall contract
     */
    function initializeBidWall(address _bidWall) external {
        if (msg.sender != positionManager) revert NotPositionManagerOrBidWall();
        if (bidWall != address(0)) revert("BidWall already initialized");
        bidWall = _bidWall;
    }
    
    /**
     * Calculates optimal tick range based on strategy and volatility
     * 
     * @param _poolKey The PoolKey for the pool
     * @param _currentTick The current tick of the pool
     * @param _nativeIsZero If the native token is currency0
     * 
     * @return tickLower The calculated lower tick
     * @return tickUpper The calculated upper tick
     */
    function calculateTickRange(
        PoolKey memory _poolKey,
        int24 _currentTick,
        bool _nativeIsZero
    ) external onlyAllowedCallers returns (
        int24 tickLower,
        int24 tickUpper
    ) {
        PoolId poolId = _poolKey.toId();
        
        // Store the pool key for future reference
        _poolKeys[poolId] = _poolKey;
        
        // Get spot price from current tick
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(_currentTick);
        
        // Update volatility using current price
        _updateVolatility(poolId, sqrtPriceX96);
        
        // Get strategy (use default if not set)
        Strategy memory strategy = poolStrategies[poolId];
        if (!strategy.enabled) {
            strategy = _getDefaultStrategy();
        }
        
        // Get volatility score
        uint8 volatilityScore = _getVolatilityScore(poolId);
        
        // Calculate position width based on strategy and volatility
        uint16 positionWidth = _calculatePositionWidth(strategy, volatilityScore);
        
        // Calculate ticks for position
        if (_nativeIsZero) {
            // ETH is currency0, create range below current tick
            tickLower = (_currentTick - int24(int256(uint256(positionWidth)))).validTick(false);
            tickUpper = tickLower + TickFinder.TICK_SPACING;
        } else {
            // ETH is currency1, create range above current tick
            tickUpper = (_currentTick + int24(int256(uint256(positionWidth)))).validTick(true);
            tickLower = tickUpper - TickFinder.TICK_SPACING;
        }
        
        // Emit event for tracking
        emit TickRangeCalculated(poolId, tickLower, tickUpper);
        
        return (tickLower, tickUpper);
    }
    
    /**
     * Set predefined strategy for a pool
     * 
     * @param _poolKey The PoolKey for the pool
     * @param _strategyType The strategy type to set
     */
    function setPoolStrategy(
        PoolKey memory _poolKey,
        StrategyType _strategyType
    ) external {
        // Only the token creator can set the strategy
        IMemecoin memecoin = _poolKey.memecoin(nativeToken);
        if (msg.sender != memecoin.creator()) revert CallerIsNotCreator();
        
        PoolId poolId = _poolKey.toId();
        
        // Store the pool key for future reference
        _poolKeys[poolId] = _poolKey;
        
        Strategy memory strategy;
        
        if (_strategyType == StrategyType.DEFAULT) {
            strategy = Strategy({
                strategyType: StrategyType.DEFAULT,
                baseWidth: 1,
                volatilityFactor: 0,
                enabled: true
            });
        } else if (_strategyType == StrategyType.BALANCED) {
            strategy = Strategy({
                strategyType: StrategyType.BALANCED,
                baseWidth: 5,
                volatilityFactor: 5000, // 50% in basis points
                enabled: true
            });
        } else if (_strategyType == StrategyType.AGGRESSIVE) {
            strategy = Strategy({
                strategyType: StrategyType.AGGRESSIVE,
                baseWidth: 10,
                volatilityFactor: 10000, // 100% in basis points
                enabled: true
            });
        } else {
            revert InvalidStrategyType();
        }
        
        poolStrategies[poolId] = strategy;
        emit StrategyUpdated(poolId, _strategyType);
    }
    
    /**
     * Set custom strategy for a pool
     * 
     * @param _poolKey The PoolKey for the pool
     * @param _baseWidth Base width in ticks (1-100)
     * @param _volatilityFactor How much volatility affects width (0-10000)
     */
    function setCustomPoolStrategy(
        PoolKey memory _poolKey,
        uint8 _baseWidth,
        uint16 _volatilityFactor
    ) external {
        // Only the token creator can set the strategy
        IMemecoin memecoin = _poolKey.memecoin(nativeToken);
        if (msg.sender != memecoin.creator()) revert CallerIsNotCreator();
        
        // Validate parameters
        if (_baseWidth == 0 || _baseWidth > 100) revert InvalidStrategyParameters();
        if (_volatilityFactor > _BASIS_POINTS) revert InvalidStrategyParameters();
        
        PoolId poolId = _poolKey.toId();
        
        // Store the pool key for future reference
        _poolKeys[poolId] = _poolKey;
        
        Strategy memory strategy = Strategy({
            strategyType: StrategyType.CUSTOM,
            baseWidth: _baseWidth,
            volatilityFactor: _volatilityFactor,
            enabled: true
        });
        
        poolStrategies[poolId] = strategy;
        emit StrategyUpdated(poolId, StrategyType.CUSTOM);
    }
    
    /**
     * Get current strategy for a pool
     * 
     * @param _poolId The PoolId to get strategy for
     * @return The strategy for the pool
     */
    function getPoolStrategy(PoolId _poolId) external view returns (Strategy memory) {
        Strategy memory strategy = poolStrategies[_poolId];
        if (!strategy.enabled) {
            return _getDefaultStrategy();
        }
        return strategy;
    }
    
    /**
     * Get default strategy 
     * 
     * @return The default strategy
     */
    function _getDefaultStrategy() internal pure returns (Strategy memory) {
        return Strategy({
            strategyType: StrategyType.DEFAULT,
            baseWidth: 1,
            volatilityFactor: 0,
            enabled: true
        });
    }
    
    /**
     * Calculate position width based on strategy and volatility
     * 
     * @param _strategy The strategy to use
     * @param _volatilityScore The current volatility score (0-100)
     * @return The calculated position width in ticks
     */
    function _calculatePositionWidth(
        Strategy memory _strategy,
        uint8 _volatilityScore
    ) internal pure returns (uint16) {
        if (_strategy.strategyType == StrategyType.DEFAULT) {
            return 1; // Original behavior (1 tick)
        }
        
        // Base width from strategy
        uint16 baseWidth = _strategy.baseWidth;
        
        // If volatility factor is 0, just return base width
        if (_strategy.volatilityFactor == 0) {
            return baseWidth;
        }
        
        // Volatility adjustment (higher volatility = wider position)
        // Scale width by volatility and volatilityFactor
        uint16 adjustment = uint16(
            (_volatilityScore * _strategy.volatilityFactor) / _BASIS_POINTS
        );
        
        return baseWidth + adjustment;
    }
    
    /**
     * Get current volatility score for a pool (public version)
     * 
     * @param _poolId The PoolId to get volatility for
     * @return The volatility score (0-100)
     */
    function getPoolVolatility(PoolId _poolId) external view returns (uint8) {
        return _getVolatilityScore(_poolId);
    }
    
    /**
     * Get volatility score (0-100)
     * 
     * @param _poolId The PoolId to get volatility for 
     * @return The volatility score
     */
    function _getVolatilityScore(PoolId _poolId) internal view returns (uint8) {
        VolatilityData[] storage history = _volatilityHistory[_poolId];
        if (history.length < 2) {
            return 0; // Not enough data points
        }
        
        // Return the most recently calculated volatility score
        return history[history.length - 1].volatilityScore;
    }
    
    /**
     * Update volatility based on current price
     * 
     * @param _poolId The PoolId to update volatility for
     * @param _sqrtPriceX96 The current sqrt price
     */
    function _updateVolatility(
        PoolId _poolId,
        uint160 _sqrtPriceX96
    ) internal {
        VolatilityData[] storage history = _volatilityHistory[_poolId];
        
        // If no history, just add initial entry with zero volatility
        if (history.length == 0) {
            history.push(VolatilityData({
                timestamp: uint32(block.timestamp),
                sqrtPriceX96: _sqrtPriceX96,
                volatilityScore: 0
            }));
            return;
        }
        
        // Calculate price change percentage from last record
        VolatilityData storage lastRecord = history[history.length - 1];
        uint priceChangeBasisPoints;
        
        if (_sqrtPriceX96 > lastRecord.sqrtPriceX96) {
            // Price increased
            priceChangeBasisPoints = uint((_sqrtPriceX96 - lastRecord.sqrtPriceX96) * _BASIS_POINTS) / lastRecord.sqrtPriceX96;
        } else if (_sqrtPriceX96 < lastRecord.sqrtPriceX96) {
            // Price decreased
            priceChangeBasisPoints = uint((lastRecord.sqrtPriceX96 - _sqrtPriceX96) * _BASIS_POINTS) / lastRecord.sqrtPriceX96;
        } else {
            priceChangeBasisPoints = 0;
        }
        
        // Calculate volatility score based on price change
        uint8 volatilityScore;
        
        if (priceChangeBasisPoints <= 25) { // <= 0.25%
            volatilityScore = 10; // Very low volatility
        } else if (priceChangeBasisPoints <= 100) { // <= 1%
            volatilityScore = 25; // Low volatility
        } else if (priceChangeBasisPoints <= 300) { // <= 3%
            volatilityScore = 50; // Medium volatility
        } else if (priceChangeBasisPoints <= 700) { // <= 7%
            volatilityScore = 75; // High volatility
        } else {
            volatilityScore = 100; // Very high volatility
        }
        
        // Add new record (manage history size)
        if (history.length >= MAX_VOLATILITY_HISTORY) {
            // Shift array to remove oldest entry
            for (uint i = 0; i < MAX_VOLATILITY_HISTORY - 1; i++) {
                history[i] = history[i + 1];
            }
            history[MAX_VOLATILITY_HISTORY - 1] = VolatilityData({
                timestamp: uint32(block.timestamp),
                sqrtPriceX96: _sqrtPriceX96,
                volatilityScore: volatilityScore
            });
        } else {
            history.push(VolatilityData({
                timestamp: uint32(block.timestamp),
                sqrtPriceX96: _sqrtPriceX96,
                volatilityScore: volatilityScore
            }));
        }
        
        emit VolatilityCalculated(_poolId, volatilityScore);
    }
    
    /**
     * Override to return true to make `_initializeOwner` prevent double-initialization
     * 
     * @return True to prevent owner being reinitialized
     */
    function _guardInitializeOwner() internal pure override returns (bool) {
        return true;
    }
    
    /**
     * Ensures that only allowed callers can use specific functions
     */
    modifier onlyAllowedCallers() {
        if (msg.sender != positionManager && msg.sender != bidWall) {
            revert NotPositionManagerOrBidWall();
        }
        _;
    }
}