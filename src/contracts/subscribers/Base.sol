// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from '@uniswap/v4-core/src/types/PoolId.sol';


/**
 * Empty Subscriber contract that can be extended from.
 */
abstract contract BaseSubscriber {

    /// The Flaunch {PositionManager} contract that will make approved calls
    address public immutable positionManager;

    /**
     * Sets our {PositionManager} so that we can lock down all the calls.
     */
    constructor (address _positionManager) {
        positionManager = _positionManager;
    }

    /**
     * Called when the contract is subscribed to the PositionManager.
     *
     * @dev This must return `true` to be subscribed.
     */
    function subscribe(bytes memory /* _data */) public virtual isPositionManager returns (bool) {
        return false;
    }

    /**
     * Called when the contract is unsubscribed to the PositionManager.
     */
    function unsubscribe() public virtual isPositionManager {
        // ..
    }

    /**
     * Called when an action has been performed against a pool.
     */
    function notify(PoolId /* _poolId */) public virtual isPositionManager {
        // ..
    }

    /**
     * Ensure that the caller is the {PositionManager}.
     */
    modifier isPositionManager {
        require(msg.sender == positionManager);
        _;
    }

}
