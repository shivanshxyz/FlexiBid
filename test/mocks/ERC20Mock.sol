// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';


contract ERC20Mock is ERC20 {

    uint8 internal _decimals = 18;

    constructor(string memory _name, string memory _symbol) ERC20(_name, _symbol) {}

    function mint(address account, uint amount) external {
        _mint(account, amount);
    }

    function burn(address account, uint amount) external {
        _burn(account, amount);
    }

    function burnFrom(address account, uint amount) external {
        _burn(account, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    /**
     * Allows the decimal accuracy of the token to be set. This should only be
     * done straight after the token is created, and not after any further use.
     */
    function setDecimals(uint8 newDecimals) public {
        _decimals = newDecimals;
    }
}
