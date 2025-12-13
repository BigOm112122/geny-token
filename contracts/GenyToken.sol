// SPDX-License-Identifier: MIT
// © 2025 Genyleap — All rights reserved.

pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import {ERC20Votes} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title GenyToken
/// @author compez.eth
/// @notice A fixed-supply ERC20 token (256 million GENY) designed to power creators, communities, and governance across the Genyleap ecosystem.
/// @dev Fully non-upgradeable and permissionless.
///      No ownership, no roles, no post-deploy configuration.
///      Designed for long-term decentralization and predictable behavior.
/// @custom:security-contact security@genyleap.com
contract GenyToken is
    ERC20,
    ERC20Permit,
    ERC20Votes
{
    /// @dev Fixed total token supply (256 million tokens, 18 decimals)
    uint256 public constant TOTAL_SUPPLY = 256_000_000 * 1e18;

    /// @notice ERC-7572 contract-level metadata URI (set once)
    string private _contractURI;

    /// @notice Emitted once upon successful token deployment and initial mint
    event Initialized(address indexed initialHolder, uint256 amount);

    /// @notice Emitted once when contract metadata URI is set
    event ContractURISet(string uri);

    /// Errors
    error ZeroAddressNotAllowed();
    error URIMustBeSet();
    error CannotReceiveEther();

    /// @dev Prevent receiving ETH
    receive() external payable { revert CannotReceiveEther(); }
    fallback() external payable { revert CannotReceiveEther(); }

    /// @param initialHolder Address receiving the entire token supply (Allocation Proxy)
    /// @param contractURI_  ERC-7572 contract-level metadata URI
    constructor(
        address initialHolder,
        string memory contractURI_
    )
        ERC20("Genyleap", "GENY")
        ERC20Permit("GENY")
    {
        if (initialHolder == address(0)) revert ZeroAddressNotAllowed();
        if (bytes(contractURI_).length == 0) revert URIMustBeSet();

        _contractURI = contractURI_;
        emit ContractURISet(contractURI_);

        _mint(initialHolder, TOTAL_SUPPLY);
        emit Initialized(initialHolder, TOTAL_SUPPLY);
    }

    /// @notice Returns ERC-7572 contract-level metadata URI
    function contractURI() external view returns (string memory) {
        return _contractURI;
    }

    /// @notice Exposes constant total supply (mirror helper)
    function totalSupplyConstant() external pure returns (uint256) {
        return TOTAL_SUPPLY;
    }

    /// @dev Required override for ERC20Votes
    function _update(
        address from,
        address to,
        uint256 amount
    )
        internal
        override(ERC20, ERC20Votes)
    {
        super._update(from, to, amount);
    }

    /// @dev Resolve multiple inheritance for permit/votes nonces
    function nonces(address owner)
        public
        view
        override(ERC20Permit, Nonces)
        returns (uint256)
    {
        return super.nonces(owner);
    }
}
