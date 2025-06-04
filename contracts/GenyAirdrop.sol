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
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title GenyAirdrop
/// @author compez.eth
/// @notice Manages seasonal airdrop campaigns for GENY tokens with vesting and Merkle Proof verification.
/// @dev Supports seasonal distributions, 3-month withdrawal lock, and DAO governance via GIP. Integrates with GenyAllocation for token supply.
///      Uses nonReentrant, Pausable, and UUPS upgradeability with Ownable2Step for security.
///      Uses block.timestamp for season timing, safe for long-term schedules (e.g., days/months) as miner manipulation is negligible.
/// @custom:security-contact security@genyleap.com
contract GenyAirdrop is
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
    address public tippingContract; // GenyTipping contract
    address public timelock; // Timelock for DAO governance
    uint256 public constant TOTAL_AIRDROP = 16_000_000 * 1e18; // 16M GENY
    uint48 public constant WITHDRAWAL_PERIOD = 3 * 30 days; // 3 months

    /// @dev Stores seasonal airdrop details
    struct Season {
        string title; // Season title
        uint48 startTime; // Season start timestamp
        uint48 endTime; // Season end timestamp
        uint96 minHolding; // Minimum GENY holding required
        bytes32 merkleRoot; // Merkle root for eligibility
        uint96 seasonDistribution; // Total tokens for the season
        uint96 baseDailyQuota; // Base daily tipping quota
        uint96 seasonTotalDistributed; // Total tokens distributed in season
    }

    /// @dev Stores tipping quota for users per season
    struct TippingQuota {
        uint96 totalQuota; // Total available quota
        uint96 usedQuota; // Used quota
        uint48 lastReset; // Last reset timestamp
        uint96 totalTipped; // Total tipped amount
    }

    mapping(uint32 => Season) public seasons; // Season ID to details
    mapping(address => mapping(uint32 => TippingQuota)) public tippingQuotas; // User to season tipping quotas
    uint32 public currentSeasonId; // Current active season
    uint256 public totalDistributed; // Total tokens distributed across seasons

    /// @notice Emitted when a new season is added
    event SeasonAdded(uint32 indexed seasonId, string title, uint48 startTime, uint48 endTime, uint96 minHolding, uint96 seasonDistribution, uint96 baseDailyQuota);
    /// @notice Emitted when tipping quota is used
    event TippingQuotaUsed(address indexed user, uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when unclaimed tokens are withdrawn
    event UnclaimedTokensWithdrawn(address indexed dao, uint32 indexed seasonId, uint96 amount);
    /// @notice Emitted when Merkle root is updated
    event MerkleRootUpdated(uint32 indexed seasonId, bytes32 merkleRoot);
    /// @notice Emitted when base daily quota is updated
    event BaseDailyQuotaUpdated(uint32 indexed seasonId, uint96 newQuota);
    /// @notice Emitted when minimum holding is updated
    event MinHoldingUpdated(uint32 indexed seasonId, uint96 newMinHolding);
    /// @notice Emitted when tipping contract is updated
    event TippingContractUpdated(address indexed newTippingContract);
    /// @notice Emitted for debugging paused state
    event DebugPaused(bool paused);
    /// @notice Emitted for debugging tipping contract caller
    event DebugTippingContract(address caller, address tippingContract);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the airdrop contract
    /// @param tokenAddress Address of the GENY token contract
    /// @param daoAddress Address of the GenyDAO contract
    /// @param allocationManagerAddress Address of the GenyAllocation contract
    /// @param timelockAddress Address of the TimelockController contract
    /// @param newOwner Address of the initial owner (e.g., multisig)
    function initialize(
        address tokenAddress,
        address daoAddress,
        address allocationManagerAddress,
        address timelockAddress,
        address newOwner
    ) external initializer {
        require(tokenAddress != address(0), "Invalid token address");
        require(daoAddress != address(0), "Invalid DAO address");
        require(allocationManagerAddress != address(0), "Invalid allocation manager address");
        require(timelockAddress != address(0), "Invalid timelock address");
        require(newOwner != address(0), "Invalid owner address");

        __Ownable2Step_init();
        _transferOwnership(newOwner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20Upgradeable(tokenAddress);
        dao = daoAddress;
        allocationManager = allocationManagerAddress;
        timelock = timelockAddress;
        currentSeasonId = 0;
        totalDistributed = 0;
    }

    /// @notice Pauses the contract, preventing certain actions
    function pause() external onlyOwner {
        _pause();
    }

    /// @notice Unpauses the contract, allowing actions to resume
    function unpause() external onlyOwner {
        _unpause();
    }

    /// @dev Validates season ID
    function _validateSeason(uint32 seasonId) private view {
        require(seasonId > 0 && seasonId <= currentSeasonId, "Invalid season ID");
    }

    /// @notice Sets the tipping contract address
    /// @param newTippingContract Address of the GenyTipping contract
    function setTippingContract(address newTippingContract) external onlyOwner {
        require(newTippingContract != address(0), "Invalid tipping contract");
        tippingContract = newTippingContract;
        emit TippingContractUpdated(newTippingContract);
    }

    /// @notice Adds a new airdrop season
    /// @param title Season title
    /// @param startTime Season start timestamp
    /// @param endTime Season end timestamp
    /// @param minHolding Minimum GENY holding required
    /// @param seasonDistribution Total tokens for the season
    /// @param baseDailyQuota Base daily tipping quota
    /// @param merkleRoot Merkle root for eligibility verification
    function addSeason(
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        bytes32 merkleRoot
    ) external onlyOwner whenNotPaused {
        require(startTime >= block.timestamp, "Start time must be future"); // Safe for season scheduling
        require(endTime > startTime, "End time must be after start");
        require(seasonDistribution > 0 && totalDistributed + seasonDistribution <= TOTAL_AIRDROP, "Invalid distribution");
        require(baseDailyQuota > 0, "Invalid quota");
        if (currentSeasonId > 0) {
            require(block.timestamp > seasons[currentSeasonId].endTime, "Current season not ended");
        }

        seasons[++currentSeasonId] = Season({
            title: title,
            startTime: startTime,
            endTime: endTime,
            minHolding: minHolding,
            merkleRoot: merkleRoot,
            seasonDistribution: seasonDistribution,
            baseDailyQuota: baseDailyQuota,
            seasonTotalDistributed: 0
        });

        emit SeasonAdded(currentSeasonId, title, startTime, endTime, minHolding, seasonDistribution, baseDailyQuota);
    }

    /// @notice Updates the minimum holding for a season
    /// @param seasonId Season ID
    /// @param newMinHolding New minimum holding
    function updateSeasonMinHolding(uint32 seasonId, uint96 newMinHolding) external onlyOwner {
        _validateSeason(seasonId);
        require(newMinHolding > 0, "Invalid min holding");
        seasons[seasonId].minHolding = newMinHolding;
        emit MinHoldingUpdated(seasonId, newMinHolding);
    }

    /// @notice Updates the base daily quota for a season
    /// @param seasonId Season ID
    /// @param newQuota New base daily quota
    function updateBaseDailyQuota(uint32 seasonId, uint96 newQuota) external onlyOwner {
        _validateSeason(seasonId);
        require(newQuota > 0, "Invalid quota");
        seasons[seasonId].baseDailyQuota = newQuota;
        emit BaseDailyQuotaUpdated(seasonId, newQuota);
    }

    /// @notice Updates the Merkle root for a season
    /// @param seasonId Season ID
    /// @param merkleRoot New Merkle root
    function updateMerkleRoot(uint32 seasonId, bytes32 merkleRoot) external onlyOwner {
        _validateSeason(seasonId);
        seasons[seasonId].merkleRoot = merkleRoot;
        emit MerkleRootUpdated(seasonId, merkleRoot);
    }

    /// @notice Retrieves the tipping quota for a user in a season
    /// @param user User address
    /// @param seasonId Season ID
    /// @param multiplier Multiplier for quota calculation
    /// @return quota Available tipping quota
    function getTippingQuota(address user, uint32 seasonId, uint32 multiplier) external view returns (uint256 quota) {
        _validateSeason(seasonId);
        require(token.balanceOf(user) >= seasons[seasonId].minHolding, "Insufficient holding");

        TippingQuota storage quotaStruct = tippingQuotas[user][seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days); // Safe for daily quota resets
        uint48 lastResetDay = uint48(quotaStruct.lastReset / 1 days);

        quota = (currentDay > lastResetDay || quotaStruct.totalQuota == 0)
            ? seasons[seasonId].baseDailyQuota * multiplier
            : quotaStruct.totalQuota > quotaStruct.usedQuota ? quotaStruct.totalQuota - quotaStruct.usedQuota : 0;
    }

    /// @notice Uses tipping quota for a user
    /// @param user User address
    /// @param seasonId Season ID
    /// @param amount Amount to use
    /// @param multiplier Multiplier for quota
    /// @param maxTippingAmount Maximum allowed tipping amount
    /// @param merkleProof Merkle proof for eligibility
    function useTippingQuota(
        address user,
        uint32 seasonId,
        uint96 amount,
        uint32 multiplier,
        uint256 maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        emit DebugPaused(paused());
        emit DebugTippingContract(msg.sender, tippingContract);
        require(msg.sender == tippingContract, "Only tipping contract");
        require(tippingContract != address(0), "Tipping contract not set");
        _validateSeason(seasonId);
        require(block.timestamp <= seasons[seasonId].endTime, "Season ended"); // Safe for season timing
        require(token.balanceOf(user) >= seasons[seasonId].minHolding, "Insufficient holding");

        bytes32 leaf = keccak256(abi.encodePacked(user, maxTippingAmount));
        require(MerkleProof.verify(merkleProof, seasons[seasonId].merkleRoot, leaf), "Invalid Merkle proof");

        TippingQuota storage quota = tippingQuotas[user][seasonId];
        uint48 currentDay = uint48(block.timestamp / 1 days); // Safe for daily quota resets
        if (currentDay > uint48(quota.lastReset / 1 days)) {
            quota.totalQuota = seasons[seasonId].baseDailyQuota * multiplier;
            quota.usedQuota = 0;
            quota.lastReset = uint48(block.timestamp);
        }

        require(quota.totalQuota >= quota.usedQuota + amount, "Insufficient quota");
        require(quota.totalTipped + amount <= maxTippingAmount, "Exceeds max tipping");

        quota.usedQuota += amount;
        quota.totalTipped += amount;

        Season storage season = seasons[seasonId];
        require(season.seasonTotalDistributed + amount <= season.seasonDistribution, "Exceeds season distribution");
        season.seasonTotalDistributed += amount;
        totalDistributed += amount;

        // Ensure allocationManager has sufficient balance
        require(token.balanceOf(allocationManager) >= amount, "Insufficient allocation manager balance");
        token.safeTransferFrom(allocationManager, user, amount);
        emit TippingQuotaUsed(user, seasonId, amount);
    }

    /// @notice Withdraws unclaimed tokens after withdrawal period
    /// @param seasonId Season ID
    function withdrawUnclaimed(uint32 seasonId) external onlyOwner nonReentrant {
        _validateSeason(seasonId);
        require(block.timestamp > seasons[seasonId].endTime + WITHDRAWAL_PERIOD, "Withdrawal period not reached"); // Safe for withdrawal timing
        require(dao != address(0), "DAO address not set");

        uint96 unclaimed = seasons[seasonId].seasonDistribution - seasons[seasonId].seasonTotalDistributed;
        require(unclaimed > 0, "No unclaimed tokens");

        // Ensure allocationManager has sufficient balance
        require(token.balanceOf(allocationManager) >= unclaimed, "Insufficient allocation manager balance");
        token.safeTransferFrom(allocationManager, dao, unclaimed);
        emit UnclaimedTokensWithdrawn(dao, seasonId, unclaimed);
    }

    /// @notice Checks if a season has ended
    /// @param seasonId Season ID
    /// @return ended True if the season has ended
    function isSeasonEnded(uint32 seasonId) public view returns (bool ended) {
        _validateSeason(seasonId);
        ended = block.timestamp > seasons[seasonId].endTime; // Safe for season timing
    }

    /// @notice Returns the remaining airdrop tokens
    /// @return remainingAirdrop Remaining airdrop amount
    function getRemainingAirdrop() external view returns (uint256 remainingAirdrop) {
        remainingAirdrop = TOTAL_AIRDROP - totalDistributed;
    }

    /// @notice Returns season details
    /// @param seasonId Season ID
    /// @return title Season title
    /// @return startTime Season start timestamp
    /// @return endTime Season end timestamp
    /// @return minHolding Minimum GENY holding required
    /// @return merkleRoot Merkle root for eligibility
    /// @return seasonDistribution Total tokens for the season
    /// @return baseDailyQuota Base daily tipping quota
    /// @return seasonTotalDistributed Total tokens distributed in season
    function getSeasonDetails(uint32 seasonId) external view returns (
        string memory title,
        uint48 startTime,
        uint48 endTime,
        uint96 minHolding,
        bytes32 merkleRoot,
        uint96 seasonDistribution,
        uint96 baseDailyQuota,
        uint96 seasonTotalDistributed
    ) {
        _validateSeason(seasonId);
        Season storage season = seasons[seasonId];
        return (
            season.title,
            season.startTime,
            season.endTime,
            season.minHolding,
            season.merkleRoot,
            season.seasonDistribution,
            season.baseDailyQuota,
            season.seasonTotalDistributed
        );
    }

    /// @dev Validates initialization addresses
    function _validateAddresses(address tokenAddress, address daoAddress, address allocationManagerAddress, address timelockAddress, address newOwner) private pure {
        require(tokenAddress != address(0) && daoAddress != address(0) && allocationManagerAddress != address(0) && timelockAddress != address(0) && newOwner != address(0), "Invalid address");
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Restricts functions to DAO (via Timelock)
    modifier onlyDAO() {
        require(msg.sender == timelock, "Caller is not DAO");
        _;
    }
}

interface IGenyAllocation {
    function getTotalReleasedTokens() external view returns (uint256);
}