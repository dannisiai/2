// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract FixedSupplyToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;

    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(
        string memory name_,
        string memory symbol_,
        uint256 initialSupply_,
        address receiver_
    ) {
        require(receiver_ != address(0), "Receiver zero");

        name = name_;
        symbol = symbol_;
        totalSupply = initialSupply_;
        balanceOf[receiver_] = initialSupply_;

        emit Transfer(address(0), receiver_, initialSupply_);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 currentAllowance = allowance[from][msg.sender];
        require(currentAllowance >= amount, "Allowance exceeded");

        unchecked {
            allowance[from][msg.sender] = currentAllowance - amount;
        }

        _transfer(from, to, amount);
        emit Approval(from, msg.sender, allowance[from][msg.sender]);
        return true;
    }

    function increaseAllowance(address spender, uint256 addedValue) external returns (bool) {
        uint256 newAllowance = allowance[msg.sender][spender] + addedValue;
        allowance[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    function decreaseAllowance(address spender, uint256 subtractedValue) external returns (bool) {
        uint256 currentAllowance = allowance[msg.sender][spender];
        require(currentAllowance >= subtractedValue, "Allowance below zero");

        uint256 newAllowance;
        unchecked {
            newAllowance = currentAllowance - subtractedValue;
        }

        allowance[msg.sender][spender] = newAllowance;
        emit Approval(msg.sender, spender, newAllowance);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(to != address(0), "Transfer to zero");

        uint256 fromBalance = balanceOf[from];
        require(fromBalance >= amount, "Balance too low");

        unchecked {
            balanceOf[from] = fromBalance - amount;
            balanceOf[to] += amount;
        }

        emit Transfer(from, to, amount);
    }
}
