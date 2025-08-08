// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity ^0.8.30;

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}