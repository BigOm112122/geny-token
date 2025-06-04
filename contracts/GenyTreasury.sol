// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title GenyTreasury
/// @author compez.eth
/// @notice Manages treasury funds for the Genyleap ecosystem, holding and distributing GENY tokens.
/// @dev Uses OpenZeppelin upgradeable contracts with Ownable2Step for enhanced security.
///      The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
/// @custom:security-contact security@genyleap.com
contract GenyTreasury is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable {
    using SafeERC20 for IERC20;

    IERC20 public token; // GENY token contract
    address public allocation; // GenyAllocation contract address

    /// @notice Emitted when tokens are withdrawn from the treasury
    event TokensWithdrawn(address indexed to, uint256 amount);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the treasury contract
    /// @dev The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
    /// @param _token Address of the GENY token contract
    /// @param _allocation Address of the GenyAllocation contract
    /// @param _owner Address of the contract owner (multisig)
    function initialize(address _token, address _allocation, address _owner) external initializer {
        require(_token != address(0), "Invalid token");
        require(_allocation != address(0), "Invalid allocation");
        require(_owner != address(0), "Invalid owner");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        token = IERC20(_token);
        allocation = _allocation;
    }

    /// @notice Withdraws tokens from the treasury
    /// @dev Only callable by the owner (multisig)
    /// @param _to Address to receive the tokens
    /// @param _amount Amount of tokens to withdraw
    function withdraw(address _to, uint256 _amount) external onlyOwner nonReentrant whenNotPaused {
        require(_to != address(0), "Invalid recipient");
        require(_amount > 0, "Invalid amount");
        require(token.balanceOf(address(this)) >= _amount, "Insufficient balance");

        token.safeTransfer(_to, _amount);
        emit TokensWithdrawn(_to, _amount);
    }

    /// @notice Gets the total token balance of the treasury
    /// @return Total token balance
    function getBalance() external view returns (uint256) {
        return token.balanceOf(address(this));
    }

    /// @notice Pauses the contract
    /// @dev Only callable by the owner (multisig)
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by the owner (multisig)
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @dev Only callable by the owner (multisig)
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}