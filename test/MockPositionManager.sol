// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {DynamicBidWall} from "../src/DynamicBidWall.sol";

/**
 * Mock of Flaunch's PositionManager for testing DynamicBidWall
 * 
 * This mock simulates the key interactions between PositionManager and BidWall
 * needed for testing our DynamicBidWall implementation.
 */
contract MockPositionManager {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    // Simulated token balances for testing
    mapping(address => uint256) public tokenBalances;
    
    // The BidWall address
    address public bidWall;
    
    // Reference to native token and pool manager
    address public nativeToken;
    IPoolManager public poolManager;
    
    // Pool key registry for testing
    mapping(PoolId => PoolKey) public poolKeys;
    
    // Pool tick tracking for testing
    mapping(PoolId => int24) public currentTicks;
    
    address public owner;
    PoolId public lastRepositionedPool;
    
    // Events to track operations
    event BidWallClosed(PoolId indexed poolId);
    event PoolInitialized(PoolId indexed poolId, PoolKey poolKey);
    event FeesDeposited(PoolId indexed poolId, uint256 amount);
    
    constructor(address _nativeToken, address _poolManager, address _owner) {
        nativeToken = _nativeToken;
        poolManager = IPoolManager(_poolManager);
        owner = _owner;
    }
    
    /**
     * Set the BidWall address - typically called after BidWall deployment
     */
    function setBidWall(address _bidWall) external {
        bidWall = _bidWall;
    }
    
    /**
     * Register a pool for testing
     */
    function registerPool(PoolKey memory _poolKey, int24 _initialTick) external {
        PoolId poolId = _poolKey.toId();
        poolKeys[poolId] = _poolKey;
        currentTicks[poolId] = _initialTick;
        
        emit PoolInitialized(poolId, _poolKey);
    }
    
    /**
     * Update current tick for testing
     */
    function updateTick(PoolId _poolId, int24 _newTick) external {
        currentTicks[_poolId] = _newTick;
    }
    
    /**
     * Mock implementation of closing BidWall
     * Simulates PositionManager's closeBidWall function
     */
    function closeBidWall(PoolKey memory _poolKey) external {
        // In a real implementation, this would open a lock on the PoolManager
        // and call back to the BidWall for closing operations
        
        // For testing, we just emit an event
        emit BidWallClosed(_poolKey.toId());
    }
    
    /**
     * Simulate depositing fees into the BidWall
     * Used for testing deposit behavior and thresholds
     */
    function depositFeesToBidWall(PoolKey calldata poolKey, uint256 amount, bool nativeIsZero) external payable {
        // Record that this pool was repositioned
        lastRepositionedPool = poolKey.toId();
        
        // Forward ETH to the caller (which should be the bidWall in your test)
        (bool success, ) = msg.sender.call{value: amount}("");
        require(success, "ETH transfer failed");
    }
    
    /**
     * Simulate token transfers for testing
     */
    function mockTransferFrom(address _token, address _from, address _to, uint256 _amount) external {
        // In testing scenarios we just update our internal balances
        tokenBalances[_from] -= _amount;
        tokenBalances[_to] += _amount;
    }
    
    /**
     * Simulate token transfers for testing
     */
    function mockTransfer(address _token, address _to, uint256 _amount) external {
        // In testing scenarios we just update our internal balances
        tokenBalances[address(this)] -= _amount;
        tokenBalances[_to] += _amount;
    }
    
    /**
     * Get the current tick for a pool
     */
    function getCurrentTick(PoolId _poolId) external view returns (int24) {
        return currentTicks[_poolId];
    }
    
    /**
     * Set token balance for an address (for testing)
     */
    function mockSetBalance(address _token, address _holder, uint256 _balance) external {
        tokenBalances[_holder] = _balance;
    }
    
    /**
     * Get token balance for an address (for testing)
     */
    function mockGetBalance(address _token, address _holder) external view returns (uint256) {
        return tokenBalances[_holder];
    }
    
    /**
     * Allows the contract to receive ETH
     */
    receive() external payable {}
}