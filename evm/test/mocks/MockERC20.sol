// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import { ERC20 } from "solady/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    string internal _name;
    string internal _symbol;
    uint8 internal _decimals;
    bytes32 internal immutable _nameHash;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        _name = name_;
        _symbol = symbol_;
        _decimals = decimals_;
        _nameHash = keccak256(bytes(name_));
    }

    function _constantNameHash() internal view virtual override returns (bytes32) {
        return _nameHash;
    }

    function name() public view virtual override returns (string memory) {
        return _name;
    }

    function symbol() public view virtual override returns (string memory) {
        return _symbol;
    }

    function decimals() public view virtual override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 value) public virtual {
        _mint(to, value);
    }

    function burn(address from, uint256 value) public virtual {
        _burn(from, value);
    }

    function directTransfer(address from, address to, uint256 amount) public virtual {
        _transfer(from, to, amount);
    }

    function directSpendAllowance(address owner, address spender, uint256 amount) public virtual {
        _spendAllowance(owner, spender, amount);
    }

    function transfer(address to, uint256 amount) public virtual override returns (bool) {
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public virtual override returns (bool) {
        return super.transferFrom(from, to, amount);
    }
}
