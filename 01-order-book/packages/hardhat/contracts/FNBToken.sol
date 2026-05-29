// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract FNBToken is ERC20 {
    // inherit ERC20, change token name and token symbol
    constructor(uint256 initialSupply_) ERC20("FNB Token", "FNBT") {
        _mint(msg.sender, initialSupply_);
    }
}
