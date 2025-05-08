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

/// @title GenyLiquidity
/// @author compez.eth
/// @notice Manages liquidity allocation for GENY tokens with simple transfer to liquidity pools.
/// @dev Allocates 16M free and 16M vested GENY tokens (over 24 months) for liquidity pools (e.g., Uniswap V3).
///      Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
/// @custom:security-contact security@genyleap.com
contract GenyLiquidity is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token; // GENY token contract
    address public allocationManager; // GenyAllocation for token supply
    uint256 public constant FREE_LIQUIDITY = 16_000_000 * 1e18; // 16M free tokens
    uint256 public constant VESTED_LIQUIDITY = 16_000_000 * 1e18; // 16M vested tokens
    uint48 public constant VESTING_DURATION = 24 * 30 days; // 24 months
    uint48 public vestingStartTime; // Vesting start timestamp
    uint96 public vestedReleased; // Total vested tokens released
    uint96 public totalTransferred; // Total tokens transferred to pools

    /// @notice Emitted when liquidity is added to a pool
    /// @param poolAddress Address of the liquidity pool
    /// @param genyAmount Amount of GENY tokens transferred
    /// @param pairedToken Address of the paired token
    /// @param pairedAmount Amount of paired token transferred
    event LiquidityAdded(address indexed poolAddress, uint96 genyAmount, address indexed pairedToken, uint96 pairedAmount);

    /// @notice Emitted when vested tokens are released
    /// @param amount Amount of vested tokens released
    event VestedTokensReleased(uint96 amount);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the liquidity contract
    /// @param _token Address of the GENY token contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _allocationManager,
        address _owner
    ) external initializer {
        require(_token != address(0) && _allocationManager != address(0) && _owner != address(0), "Invalid address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        allocationManager = _allocationManager;
        vestingStartTime = uint48(block.timestamp);
    }

    /// @notice Adds liquidity by transferring GENY and paired tokens to a pool
    /// @param poolAddress Address of the liquidity pool (e.g., Uniswap V3 pool)
    /// @param genyAmount Amount of GENY tokens to transfer
    /// @param pairedToken Address of the paired token (e.g., ETH, USDC)
    /// @param pairedAmount Amount of paired token to transfer
    function addLiquidity(
        address poolAddress,
        uint96 genyAmount,
        address pairedToken,
        uint96 pairedAmount
    ) external onlyOwner nonReentrant whenNotPaused {
        require(poolAddress != address(0) && genyAmount > 0 && pairedAmount > 0, "Invalid parameters");
        require(pairedToken != address(0), "Invalid paired token");

        uint256 totalAvailable = FREE_LIQUIDITY + getReleasableVested();
        require(totalAvailable >= genyAmount, "Insufficient GENY balance");
        require(token.balanceOf(allocationManager) >= genyAmount, "Insufficient GENY in allocation");
        require(IERC20Upgradeable(pairedToken).balanceOf(allocationManager) >= pairedAmount, "Insufficient paired token");

        totalTransferred += genyAmount;
        token.safeTransferFrom(allocationManager, poolAddress, genyAmount);
        IERC20Upgradeable(pairedToken).safeTransferFrom(allocationManager, poolAddress, pairedAmount);

        emit LiquidityAdded(poolAddress, genyAmount, pairedToken, pairedAmount);
    }

    /// @notice Releases vested liquidity tokens
    /// @return amount Amount of tokens released
    function releaseVested() external onlyOwner nonReentrant whenNotPaused returns (uint96 amount) {
        amount = getReleasableVested();
        require(amount > 0, "No tokens to release");

        vestedReleased += amount;
        token.safeTransferFrom(allocationManager, address(this), amount);
        emit VestedTokensReleased(amount);
    }

    /// @notice Calculates releasable vested tokens
    /// @return amount Amount of vested tokens releasable
    function getReleasableVested() public view returns (uint96 amount) {
        if (block.timestamp < vestingStartTime) return 0;

        uint48 elapsed = uint48(block.timestamp) - vestingStartTime;
        if (elapsed >= VESTING_DURATION) {
            amount = uint96(VESTED_LIQUIDITY - vestedReleased);
        } else {
            amount = uint96((VESTED_LIQUIDITY * elapsed) / VESTING_DURATION - vestedReleased);
        }
    }

    /// @notice Gets the total available liquidity (free + releasable vested)
    /// @return totalAvailable Total available tokens
    function getTotalAvailable() external view returns (uint256 totalAvailable) {
        totalAvailable = FREE_LIQUIDITY + getReleasableVested() - totalTransferred;
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
}