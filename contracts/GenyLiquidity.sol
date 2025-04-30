// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.29;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";

/// @title GenyLiquidity
/// @author compez.eth
/// @notice Creates and manages liquidity pools for GENY tokens in Uniswap V3 with direct allocation.
/// @dev Allocates 16M free GENY tokens and 16M vested tokens (over 24 months) for liquidity pools in DEXs (e.g., Uniswap V3).
///      Supports paired tokens (e.g., ETH, USDC).
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
    address public positionManager; // Uniswap V3 NonfungiblePositionManager
    uint256 public constant FREE_LIQUIDITY = 16_000_000 * 1e18; // 16M free tokens
    uint256 public constant VESTED_LIQUIDITY = 16_000_000 * 1e18; // 16M vested tokens
    uint48 public constant VESTING_DURATION = 24 * 30 days; // 24 months
    uint48 public vestingStartTime; // Vesting start timestamp
    uint96 public vestedReleased; // Total vested tokens released
    uint256 public poolCount; // Total number of liquidity pools created

    /// @dev Stores liquidity pool details
    struct LiquidityPool {
        uint96 genyAmount; // Amount of GENY tokens
        address pairedToken; // Paired token (e.g., ETH, USDC)
        uint96 pairedAmount; // Amount of paired token
        uint24 fee; // Pool fee (e.g., 3000 for 0.3%)
        int24 tickLower; // Lower price tick
        int24 tickUpper; // Upper price tick
        bool executed; // Whether pool is created
    }

    mapping(uint256 => LiquidityPool) public pools; // Pool ID to details

    /// @notice Emitted when a new liquidity pool is created
    /// @param poolId Unique ID of the pool
    /// @param genyAmount Amount of GENY tokens
    /// @param pairedToken Address of the paired token
    /// @param pairedAmount Amount of paired token
    /// @param fee Pool fee (in basis points)
    event LiquidityPoolCreated(uint256 indexed poolId, uint96 genyAmount, address pairedToken, uint96 pairedAmount, uint24 fee);
    /// @notice Emitted when a liquidity pool is executed
    /// @param poolId Unique ID of the pool
    /// @param executor Address that executed the pool creation
    event LiquidityPoolExecuted(uint256 indexed poolId, address indexed executor);
    /// @notice Emitted when vested tokens are released
    /// @param amount Amount of vested tokens released
    event VestedTokensReleased(uint96 amount);

    constructor() { _disableInitializers(); }

    /// @notice Initializes the liquidity contract
    /// @param _token Address of the GENY token contract
    /// @param _allocationManager Address of the GenyAllocation contract
    /// @param _positionManager Address of the Uniswap V3 NonfungiblePositionManager
    /// @param _owner Address of the initial owner (e.g., multisig)
    function initialize(
        address _token,
        address _allocationManager,
        address _positionManager,
        address _owner
    ) external initializer {
        require(_token != address(0) && _allocationManager != address(0) && _positionManager != address(0) && _owner != address(0), "Invalid address");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        allocationManager = _allocationManager;
        positionManager = _positionManager;
        vestingStartTime = uint48(block.timestamp);
        poolCount = 1;
    }

    /// @notice Creates a new liquidity pool with free or vested tokens
    /// @param genyAmount Amount of GENY tokens
    /// @param pairedToken Address of the paired token (e.g., ETH, USDC)
    /// @param pairedAmount Amount of paired token
    /// @param fee Uniswap V3 pool fee (e.g., 3000 for 0.3%)
    /// @param tickLower Lower price tick for Uniswap V3 range
    /// @param tickUpper Upper price tick for Uniswap V3 range
    function createPool(
        uint96 genyAmount,
        address pairedToken,
        uint96 pairedAmount,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper
    ) external onlyOwner whenNotPaused {
        require(genyAmount > 0 && pairedAmount > 0, "Invalid amounts");
        require(pairedToken != address(0), "Invalid paired token");
        require(fee > 0 && tickLower < tickUpper, "Invalid pool parameters");

        uint256 totalAvailable = FREE_LIQUIDITY + getReleasableVested();
        require(totalAvailable <= type(uint96).max, "Available tokens exceed uint96");
        uint96 availableTokens = uint96(totalAvailable);
        require(token.balanceOf(allocationManager) >= genyAmount && availableTokens >= genyAmount, "Insufficient GENY balance");

        pools[poolCount] = LiquidityPool({
            genyAmount: genyAmount,
            pairedToken: pairedToken,
            pairedAmount: pairedAmount,
            fee: fee,
            tickLower: tickLower,
            tickUpper: tickUpper,
            executed: false
        });

        emit LiquidityPoolCreated(poolCount++, genyAmount, pairedToken, pairedAmount, fee);
    }

    /// @notice Executes a liquidity pool creation in Uniswap V3
    /// @param poolId ID of the pool to execute
    /// @dev Transfers GENY and paired token to positionManager for Uniswap V3 liquidity
    function executePool(uint256 poolId) external onlyOwner nonReentrant whenNotPaused {
        LiquidityPool storage pool = pools[poolId];
        require(!pool.executed, "Pool already executed");
        require(pool.genyAmount > 0 && pool.pairedAmount > 0, "Invalid pool");

        pool.executed = true;

        // Approve tokens for positionManager
        token.safeApprove(positionManager, pool.genyAmount);
        IERC20Upgradeable(pool.pairedToken).safeApprove(positionManager, pool.pairedAmount);

        // Placeholder for Uniswap V3 mint call
        // Actual implementation would use NonfungiblePositionManager.mint
        token.safeTransferFrom(allocationManager, positionManager, pool.genyAmount);
        IERC20Upgradeable(pool.pairedToken).safeTransferFrom(allocationManager, positionManager, pool.pairedAmount);

        emit LiquidityPoolExecuted(poolId, msg.sender);
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

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}