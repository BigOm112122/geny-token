// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity ^0.8.30;

/// @dev Interface for GenyGuard ultra-secure (used for recovery logic in GenyToken and other contracts)
interface IGenyGuard {
    /// @notice Checks if recovery mode is active for a user
    /// @param user The address of the user
    /// @return True if recovery mode is active
    function isRecoveryModeActive(address user) external view returns (bool);

    /// @notice Retrieves the recovery wallet for a user
    /// @param user The address of the user
    /// @return The address of the recovery wallet
    function getRecoveryWallet(address user) external view returns (address);
}
