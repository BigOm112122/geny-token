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
import "@openzeppelin/contracts/utils/math/Math.sol";

/// @title GenyStaking
/// @author compez.eth
/// @notice Allows users to stake GENY tokens and earn rewards (6-10% annually) in the Genyleap ecosystem.
/// @dev Uses OpenZeppelin upgradeable contracts with SafeERC20 for secure token interactions. Rewards are funded from GenyAllocation or GenyTreasury.
///      The owner must be a multisig contract (e.g., Gnosis Safe) for secure governance.
/// @custom:security-contact security@genyleap.com
contract GenyStaking is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using Math for uint256;

    IERC20Upgradeable public token; // GENY token contract
    address public allocation; // GenyAllocation for funding rewards
    uint32 public rewardRate; // Reward rate (e.g., 800 for 8%)
    uint32 public constant REWARD_DENOMINATOR = 10_000; // For percentage calculations
    uint48 public constant SECONDS_PER_YEAR = 365 * 24 * 60 * 60; // Seconds in a year

    struct Stake {
        uint96 amount; // Staked amount
        uint48 startTime; // Stake start time
        uint96 rewardDebt; // Accumulated rewards
    }

    mapping(address => Stake) public stakes; // User stakes
    mapping(address => uint48) public lastClaimed; // Last reward claim time
    uint96 public totalStaked; // Total tokens staked

    /// @notice Emitted when tokens are staked
    event Staked(address indexed user, uint96 amount);
    /// @notice Emitted when tokens are unstaked
    event Unstaked(address indexed user, uint96 amount);
    /// @notice Emitted when rewards are claimed
    event RewardsClaimed(address indexed user, uint96 amount);
    /// @notice Emitted when reward rate is updated
    event RewardRateUpdated(uint32 oldRate, uint32 newRate);
    /// @notice Emitted when tokens are withdrawn by owner
    event TokensWithdrawn(address indexed owner, uint96 amount);
    /// @notice Emitted for debugging timeElapsed
    event DebugTimeElapsed(uint48 timeElapsed);
    /// @notice Emitted for debugging reward
    event DebugReward(uint96 reward);
    /// @notice Emitted for debugging lastClaimed
    event DebugLastClaimed(uint48 lastClaimed);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the staking contract
    /// @param _token Address of the GENY token contract
    /// @param _allocation Address of the GenyAllocation contract
    /// @param _owner Address of the contract owner (multisig)
    /// @param _rewardRate Reward rate (e.g., 800 for 8%)
    function initialize(
        address _token,
        address _allocation,
        address _owner,
        uint32 _rewardRate
    ) external initializer {
        require(_token != address(0) && _allocation != address(0) && _owner != address(0), "Invalid address");
        require(_allocation.code.length > 0, "Allocation not a contract");
        require(_rewardRate >= 600 && _rewardRate <= 1000, "Reward rate must be 6-10%");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(_token);
        allocation = _allocation;
        rewardRate = _rewardRate;
    }

    /// @notice Stakes tokens
    /// @param _amount Amount to stake
    function stake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than zero");
        require(token.balanceOf(msg.sender) >= _amount, "Insufficient balance");

        // Initialize lastClaimed for new stakers
        if (stakes[msg.sender].amount == 0 && lastClaimed[msg.sender] == 0) {
            lastClaimed[msg.sender] = uint48(block.timestamp);
        }

        _updateRewards(msg.sender);

        Stake storage userStake = stakes[msg.sender];
        userStake.amount += _amount;
        userStake.startTime = uint48(block.timestamp);
        totalStaked += _amount;

        token.safeTransferFrom(msg.sender, address(this), _amount);
        emit Staked(msg.sender, _amount);
    }

    /// @notice Unstakes tokens
    /// @param _amount Amount to unstake
    function unstake(uint96 _amount) external nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than zero");
        require(stakes[msg.sender].amount >= _amount, "Insufficient staked amount");

        _updateRewards(msg.sender);

        Stake storage userStake = stakes[msg.sender];
        userStake.amount -= _amount;
        totalStaked -= _amount;

        token.safeTransfer(msg.sender, _amount);
        emit Unstaked(msg.sender, _amount);
    }

    /// @notice Claims accumulated rewards
    /// @return reward Amount of rewards claimed
    function claimRewards() external nonReentrant whenNotPaused returns (uint96 reward) {
        _updateRewards(msg.sender);
        reward = stakes[msg.sender].rewardDebt;
        require(reward > 0, "No rewards to claim");
        require(token.balanceOf(address(this)) >= reward, "Insufficient contract balance");

        stakes[msg.sender].rewardDebt = 0;
        token.safeTransfer(msg.sender, reward);
        emit RewardsClaimed(msg.sender, reward);
    }

    /// @notice Withdraws tokens from the contract (only owner)
    /// @param _amount Amount to withdraw
    function withdrawTokens(uint96 _amount) external onlyOwner nonReentrant {
        require(_amount > 0, "Amount must be greater than zero");
        require(token.balanceOf(address(this)) >= _amount, "Insufficient contract balance");

        token.safeTransfer(msg.sender, _amount);
        emit TokensWithdrawn(msg.sender, _amount);
    }

    /// @notice Updates reward rate
    /// @param _newRate New reward rate (e.g., 800 for 8%)
    function updateRewardRate(uint32 _newRate) external onlyOwner {
        require(_newRate >= 600 && _newRate <= 1000, "Reward rate must be 6-10%");
        uint32 oldRate = rewardRate;
        rewardRate = _newRate;
        emit RewardRateUpdated(oldRate, _newRate);
    }

    /// @dev Updates user rewards
    /// @param _user User address
    function _updateRewards(address _user) private {
        Stake storage userStake = stakes[_user];
        if (userStake.amount == 0) return;

        uint48 timeElapsed = uint48(block.timestamp) - lastClaimed[_user];
        emit DebugTimeElapsed(timeElapsed);
        emit DebugLastClaimed(lastClaimed[_user]);
        uint96 reward = uint96(Math.mulDiv(userStake.amount, rewardRate * timeElapsed, REWARD_DENOMINATOR * SECONDS_PER_YEAR));
        emit DebugReward(reward);
        userStake.rewardDebt += reward;
        lastClaimed[_user] = uint48(block.timestamp);
    }

    /// @notice Gets claimable rewards for a user
    /// @param _user User address
    /// @return reward Claimable reward amount
    function getClaimableRewards(address _user) external view returns (uint96 reward) {
        Stake memory userStake = stakes[_user];
        if (userStake.amount == 0) return 0;

        uint48 timeElapsed = uint48(block.timestamp) - lastClaimed[_user];
        reward = uint96(Math.mulDiv(userStake.amount, rewardRate * timeElapsed, REWARD_DENOMINATOR * SECONDS_PER_YEAR));
        reward += userStake.rewardDebt;
    }

    /// @notice Gets total rewards distributed
    /// @return totalRewards Total rewards distributed
    function getTotalRewards() external view returns (uint96 totalRewards) {
        return totalStaked > 0 ? uint96(Math.mulDiv(totalStaked, rewardRate * uint48(block.timestamp - stakes[address(this)].startTime), REWARD_DENOMINATOR * SECONDS_PER_YEAR)) : 0;
    }

    /// @notice Pauses the contract
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @notice Authorizes contract upgrades
    /// @param newImplementation Address of the new implementation
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}