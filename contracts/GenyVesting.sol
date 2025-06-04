// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GenyVesting
/// @author compez.eth
/// @notice Manages linear vesting with cliff for Genyleap token allocations (e.g., team, investors).
/// @dev Integrates with GenyAllocation for token supply. Uses nonReentrant and UUPS upgradeability.
///      Uses block.timestamp for vesting calculations, safe for long-term vesting (e.g., months) as miner manipulation is negligible.
/// @custom:security-contact security@genyleap.com
contract GenyVesting is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Math for uint256;

    IERC20Upgradeable public token; // GENY token contract
    address public beneficiary; // Address to receive vested tokens
    uint48 public startTime; // Vesting start time
    uint48 public cliffSeconds; // Cliff period in seconds
    uint48 public durationSeconds; // Total vesting duration in seconds
    uint48 public intervalSeconds; // Release interval in seconds (e.g., monthly)
    uint96 public totalAmount; // Total tokens to vest
    uint96 public releasedAmount; // Tokens released so far

    /// @notice Emitted when vested tokens are released
    /// @param beneficiary Address receiving tokens
    /// @param amount Amount of tokens released
    event TokensReleased(address indexed beneficiary, uint96 amount);
    /// @notice Emitted when vesting is initialized
    /// @param beneficiary Address to receive tokens
    /// @param amount Total tokens to vest
    /// @param startTime Vesting start time
    /// @param cliff Cliff period in seconds
    /// @param duration Total vesting duration in seconds
    event VestingInitialized(address indexed beneficiary, uint96 amount, uint48 startTime, uint48 cliff, uint48 duration);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the vesting contract
    /// @param tokenAddress Address of the GENY token contract
    /// @param newOwner Address of the contract owner
    /// @param beneficiaryAddress Address to receive vested tokens
    /// @param amount Total tokens to vest
    /// @param cliffDuration Cliff period in seconds
    /// @param vestingDuration Total vesting duration in seconds
    /// @param releaseInterval Release interval in seconds
    function initialize(
        address tokenAddress,
        address newOwner,
        address beneficiaryAddress,
        uint96 amount,
        uint48 cliffDuration,
        uint48 vestingDuration,
        uint48 releaseInterval
    ) external initializer {
        require(tokenAddress != address(0) && newOwner != address(0) && beneficiaryAddress != address(0), "Invalid address");
        require(amount > 0, "Amount must be greater than zero");
        require(vestingDuration >= cliffDuration, "Duration must be >= cliff");
        require(releaseInterval > 0, "Interval must be greater than zero");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(tokenAddress);
        beneficiary = beneficiaryAddress;
        startTime = uint48(block.timestamp); // Safe for long-term vesting
        cliffSeconds = cliffDuration;
        durationSeconds = vestingDuration;
        intervalSeconds = releaseInterval;
        totalAmount = amount;

        emit VestingInitialized(beneficiaryAddress, amount, startTime, cliffDuration, vestingDuration);
    }

    /// @notice Releases vested tokens to the beneficiary
    function release() external nonReentrant {
        require(block.timestamp >= startTime + cliffSeconds, "Cliff period not reached"); // Safe for long-term vesting
        uint96 releasable = getReleasableAmount();
        require(releasable > 0, "No tokens to release");

        releasedAmount += releasable;
        token.safeTransfer(beneficiary, releasable);
        emit TokensReleased(beneficiary, releasable);
    }

    /// @notice Calculates the releasable amount
    /// @return amount Amount of tokens that can be released
    function getReleasableAmount() public view returns (uint96 amount) {
        if (block.timestamp < startTime + cliffSeconds) return 0;

        uint48 elapsedTime = uint48(block.timestamp) - startTime; // Safe for long-term vesting
        if (elapsedTime >= durationSeconds) {
            amount = totalAmount - releasedAmount;
        } else {
            // Use Math.mulDiv for precise calculations to avoid precision loss
            amount = uint96(Math.mulDiv(
                totalAmount,
                elapsedTime,
                durationSeconds,
                Math.Rounding.Floor
            )) - releasedAmount;
        }
    }

    /// @notice Gets the remaining vested amount
    /// @return amount Remaining tokens to be vested
    function getRemainingAmount() external view returns (uint96 amount) {
        amount = totalAmount - releasedAmount;
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}