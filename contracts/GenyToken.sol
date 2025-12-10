// SPDX-License-Identifier: MIT
// © 2025 Genyleap — All rights reserved.

pragma solidity 0.8.30;

import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice A fixed-supply ERC20 token (256 million GENY) designed to power creators, communities, and governance across the Genyleap ecosystem.
/// @dev Implements ERC20 with permit (EIP-2612), ERC20Votes, and Ownable for controlled metadata updates.  
///      Fully non-upgradeable and roleless by design, ensuring long-term decentralization and predictable token behavior.
/// @custom:security-contact security@genyleap.com
contract GenyToken is
    ERC20,
    ERC20Permit,
    ERC20Votes,
    Ownable
{
    /// @dev Fixed total token supply (256 million tokens with 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 256_000_000 * 1e18;

    /// @notice ERC-7572 metadata URI
    string private _contractURI;

    /// @notice Emitted once upon successful token deployment and initial allocation
    event Initialized(address indexed initialHolder, uint256 amount);
    /// @notice Emitted when the contract metadata URI is set or updated
    event ContractURISet(string indexed uri);

    /// errors
    error ZeroAddressNotAllowed();
    error URIMustBeSet();
    error CannotReceiveEther();

    // Prevent contract from receiving ETH
    receive() external payable { revert CannotReceiveEther(); }
    fallback() external payable { revert CannotReceiveEther(); }

    /// @param initialHolder Address to receive the entire supply
    /// @param contractURI_ URI for contract-level metadata
    constructor(address initialHolder, string memory contractURI_)
        ERC20("Genyleap", "GENY")
        ERC20Permit("GENY")
        Ownable(msg.sender)
    {
        if (initialHolder == address(0)) revert ZeroAddressNotAllowed();
        if (bytes(contractURI_).length == 0) revert URIMustBeSet();

        _contractURI = contractURI_;
        emit ContractURISet(contractURI_);

        _mint(initialHolder, TOTAL_SUPPLY);
        emit Initialized(initialHolder, TOTAL_SUPPLY);
    }

    /// @notice Returns ERC-7572 contract-level metadata
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Update the contract metadata URI (only owner)
    function setContractURI(string memory newURI) external onlyOwner {
        if (bytes(newURI).length == 0) revert URIMustBeSet();
        _contractURI = newURI;
        emit ContractURISet(newURI);
    }

    /// @notice Exposes constant total supply (mirror)
    function totalSupplyConstant() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// Internal hook overrides required by Solidity
    function _update(address from, address to, uint256 amount)
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    /// @notice Multiple inheritance fix for shared nonces (permit/votes)
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
