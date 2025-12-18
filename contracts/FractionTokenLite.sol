// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import "@openzeppelin/contracts/utils/Nonces.sol";

contract FractionTokenLite is ERC20, ERC20Permit, ERC20Votes, Ownable {
    address public distributor;

    constructor(
        string memory name_,
        string memory symbol_,
        address admin_,
        address initialHolder_,
        uint256 initialSupply_
    )
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        Ownable(admin_)            // ✅ هذا هو الإصلاح
    {
        _mint(initialHolder_, initialSupply_);
    }

    function setDistributor(address distributor_) external onlyOwner {
        distributor = distributor_;
    }

    // OZ v5 overrides
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, value);
    }

    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
