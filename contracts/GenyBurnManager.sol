// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title GenyBurnManager
/// @author compez.eth
/// @notice Manages burning of GENY tokens in the Genyleap ecosystem.
/// @dev Allows DAO or owner (multisig) to burn tokens with a 24-hour cooldown and 10% max per burn, up to a total of 25.6M tokens.
///      Integrates with GenyAllocation for token supply. Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// @custom:security-contact security@genyleap.com
contract GenyBurnManager is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token; // GENY token contract
    address public dao; // GenyDAO contract for governance
    address public allocationManager; // GenyAllocation for token supply
    uint48 public lastBurnTimestamp; // Last burn timestamp for cooldown
    uint256 public burnCount; // Total number of burns
    uint96 public totalBurned; // Total tokens burned
    uint96 public constant MAX_TOTAL_BURN = 25_600_000 * 1e18; // 10% of total supply (25.6M tokens)

    uint48 public constant BURN_COOLDOWN = 1 days; // 24-hour cooldown
    uint32 public constant BURN_MAX_PERCENT = 10_00; // 10% max per burn (1000 basis points)

    /// @notice Emitted when tokens are burned
    /// @param burnId Unique ID of the burn event
    /// @param amount Amount of tokens burned
    event TokensBurned(uint256 indexed burnId, uint96 amount);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the burn manager contract
    /// @param _token Address of the GENY token contract
    /// @param _dao Address of the GenyDAO contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _dao,
        address _allocationManager,
        address _owner
    ) external initializer {
        require(_token != address(0) && _dao != address(0) && _allocationManager != address(0) && _owner != address(0), "Invalid address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        dao = _dao;
        allocationManager = _allocationManager;
        burnCount = 1;
    }

    /// @notice Burns tokens from the allocation manager
    /// @param amount Amount of tokens to burn
    /// @dev Callable by DAO or owner (multisig). Enforces cooldown, max burn limit, and total burn cap.
    function burnFromContract(uint96 amount) external onlyOwnerOrDAO nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        require(amount <= (token.balanceOf(allocationManager) * BURN_MAX_PERCENT) / 1e4, "Exceeds max burn limit");
        require(amount > 0, "Invalid amount");
        require(totalBurned + amount <= MAX_TOTAL_BURN, "Exceeds total burn limit");

        lastBurnTimestamp = uint48(block.timestamp);
        totalBurned += amount;
        token.safeTransferFrom(allocationManager, address(0xdead), amount); // Burn by sending to dead address

        emit TokensBurned(burnCount++, amount);
    }

    /// @notice Pauses the contract
    /// @dev Only callable by owner
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    /// @dev Only callable by owner
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    /// @dev Only callable by owner
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts functions to DAO or owner
    modifier onlyOwnerOrDAO() {
        require(msg.sender == owner() || msg.sender == dao, "Not authorized");
        _;
    }
}