// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract PNPToken is ERC20 {
    // inherit ERC20, change token name and token symbol
    constructor(uint256 initialSupply_) ERC20("PNP Token", "PNPT") {
        _mint(msg.sender, initialSupply_);
    }
}
