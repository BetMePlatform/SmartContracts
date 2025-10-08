// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract BETMEToken is ERC20, Ownable, ERC20Permit {
    bool public tradingEnabled;
    mapping(address => bool) public isExcludedFromTradingRestriction;
    
    event AddressExcludedFromTrading(address indexed account, bool excluded);
    
    constructor() 
        ERC20("BetMe", "$BET") 
        Ownable(msg.sender)
        ERC20Permit("BetMe")
    {
        _mint(msg.sender, 1000000000 * 10**decimals());
        isExcludedFromTradingRestriction[msg.sender] = true;
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function enableTrading() external onlyOwner {
        require(!tradingEnabled, "Trading is already enabled");
        tradingEnabled = true;
    }

    function setExcluded(address account, bool excluded) external onlyOwner {
        require(account != address(0), "Cannot exclude zero address");
        require(isExcludedFromTradingRestriction[account] != excluded, "Account already has this status");
        isExcludedFromTradingRestriction[account] = excluded;
        emit AddressExcludedFromTrading(account, excluded);
    }

    function _update(
        address from,
        address to,
        uint256 amount
    ) internal virtual override {
        require(
            from == address(0) || // Allow minting
            to == address(0) || // Allow burning
            tradingEnabled || 
            isExcludedFromTradingRestriction[from] || 
            isExcludedFromTradingRestriction[to],
            "Trading is not enabled yet"
        );
        super._update(from, to, amount);
    }

    function renounceOwnership() public override onlyOwner {
        require(tradingEnabled, "Cannot renounce ownership before enabling trading");
        super.renounceOwnership();
    }
} 