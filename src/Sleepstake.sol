// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract Sleepstake {
    mapping(address => uint256) public balances;
    mapping(address => uint256) public stakeTimestamp;

    event Staked(address indexed user, uint256 amount);
    event Unstaked(address indexed user, uint256 amount);

    // Stake MON
    function stake() external payable {
        require(msg.value > 0, "Cannot stake 0");
        
        // Effects
        balances[msg.sender] += msg.value;
        stakeTimestamp[msg.sender] = block.timestamp;
        
        emit Staked(msg.sender, msg.value);
    }

    // Unstake MON
    function unstake(uint256 amount) external {
        // Checks
        require(balances[msg.sender] >= amount, "Insufficient staked balance");
        
        // Effects (Update state & emit event BEFORE external call)
        balances[msg.sender] -= amount;
        emit Unstaked(msg.sender, amount);

        // Interactions (External call last)
        (bool success, ) = payable(msg.sender).call{value: amount}("");
        require(success, "Transfer failed");
    }

    // View user balance
    function getBalance(address account) external view returns (uint256) {
        return balances[account];
    }
}