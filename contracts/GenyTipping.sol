// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";

/// @title GenyTipping
/// @author compez.eth
/// @notice Label-based tipping that consumes Merkle-gated airdrop quotas and transfers GENY directly to recipients.
/// @dev Upgradable via UUPS; does not custody tokens; integrates with GenyAirdrop.useTippingQuotaTo(...)
contract GenyTipping is
    Initializable,
    Ownable2StepUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    // --- Core external contracts ---
    IERC20 public token;               // GENY token (used for local minHolding guard)
    address public airdropContract;    // GenyAirdrop implementation (must support useTippingQuotaTo)

    // --- Local policy ---
    uint96  public minHolding;         // minimal sender balance to be eligible to tip (soft local guard)
    bool    public usePrecheck;        // if true, pre-check available quota before consuming on airdrop (UX-oriented)

    // --- Labels & profiles ---
    struct Label {
        uint32 multiplier;             // quota multiplier
        bool   active;                 // is label active
        string name;                   // human-readable name (for frontends/events)
    }

    // labelId => Label
    mapping(bytes32 => Label) public labels;

    // tipper profile
    struct Profile {
        bytes32 labelId;               // assigned label id for tipper
        bool    isActive;              // allowed to tip
    }

    // tipper => Profile
    mapping(address => Profile) public profiles;

    // optional recipient blacklist
    mapping(address => bool) public isRecipientBlacklisted;

    // --- Events ---
    event AirdropContractUpdated(address indexed newAirdrop);
    event MinHoldingUpdated(uint96 newMinHolding);
    event UsePrecheckUpdated(bool enabled);

    event LabelUpserted(bytes32 indexed labelId, string name, uint32 multiplier, bool active);
    event ProfileUpdated(address indexed user, bytes32 indexed labelId, bool isActive);
    event RecipientBlacklistUpdated(address indexed recipient, bool blacklisted);

    event TipSubmitted(
        address indexed sender,
        address indexed recipient,
        uint32 indexed seasonId,
        uint96 amount,
        bytes32 labelId
    );

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // --- Init ---

    function initialize(
        address _token,
        address _airdropContract,
        address _owner
    ) external initializer {
        require(_token != address(0) && _airdropContract != address(0) && _owner != address(0), "Invalid address");
        require(_airdropContract.code.length > 0, "Airdrop is not a contract");

        __Ownable2Step_init();
        _transferOwnership(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        token = IERC20(_token);
        airdropContract = _airdropContract;

        // defaults
        minHolding = 500 * 1e18;
        usePrecheck = false;

        // seed labels (ids are deterministic by keccak256(name))
        _upsertLabel(_id("Supporter"),   "Supporter",   2,   true);
        _upsertLabel(_id("Contributor"), "Contributor", 8,   true);
        _upsertLabel(_id("Influencer"),  "Influencer",  16,  true);
        _upsertLabel(_id("Champion"),    "Champion",    32,  true);
        _upsertLabel(_id("Trailblazer"), "Trailblazer", 64,  true);
        _upsertLabel(_id("Icon"),        "Icon",        128, true);
        _upsertLabel(_id("Legend"),      "Legend",      256, true);
    }

    // --- Admin: config ---

    function updateAirdropContract(address _airdrop) external onlyOwner {
        require(_airdrop != address(0), "Invalid address");
        require(_airdrop.code.length > 0, "Airdrop is not a contract");
        airdropContract = _airdrop;
        emit AirdropContractUpdated(_airdrop);
    }

    function updateMinHolding(uint96 _newMinHolding) external onlyOwner {
        require(_newMinHolding > 0, "Invalid min holding");
        minHolding = _newMinHolding;
        emit MinHoldingUpdated(_newMinHolding);
    }

    function setUsePrecheck(bool enabled) external onlyOwner {
        usePrecheck = enabled;
        emit UsePrecheckUpdated(enabled);
    }

    // --- Admin: labels & profiles ---

    /// @notice Create or update a label by id.
    /// @param labelId keccak256(name) or any app-chosen id
    function upsertLabel(bytes32 labelId, string calldata name, uint32 multiplier, bool active) external onlyOwner {
        _upsertLabel(labelId, name, multiplier, active);
    }

    /// @notice Assign a profile to a tipper (sets label and active flag).
    function setUserProfile(address user, bytes32 labelId, bool isActive) external onlyOwner {
        require(user != address(0), "Invalid user");
        Label memory l = labels[labelId];
        require(l.active, "Label not active");
        profiles[user] = Profile({labelId: labelId, isActive: isActive});
        emit ProfileUpdated(user, labelId, isActive);
    }

    /// @notice Blacklist or un-blacklist a recipient address.
    function setRecipientBlacklist(address recipient, bool blacklisted) external onlyOwner {
        require(recipient != address(0), "Invalid recipient");
        isRecipientBlacklisted[recipient] = blacklisted;
        emit RecipientBlacklistUpdated(recipient, blacklisted);
    }

    // --- Core ---

    /// @notice Submit a single tip; consumes sender's quota on GenyAirdrop and transfers GENY to `_recipient`.
    function submitTip(
        address _recipient,
        uint96  _amount,
        uint32  _seasonId,
        uint256 _maxTippingAmount,
        bytes32[] calldata _merkleProof
    ) external nonReentrant whenNotPaused {
        _tipInternal(_recipient, _amount, _seasonId, _maxTippingAmount, _merkleProof);
    }

    /// @notice Batch tips for the same season/proof; useful for multiple recipients in one go.
    /// @dev Uses the same proof and maxTippingAmount since leaf is bound to (sender, maxTippingAmount).
    function submitTipsBatch(
        address[] calldata recipients,
        uint96[]  calldata amounts,
        uint32    seasonId,
        uint256   maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external nonReentrant whenNotPaused {
        require(recipients.length == amounts.length, "Length mismatch");
        require(recipients.length > 0, "Empty batch");

        // Optional UX precheck (sum)
        if (usePrecheck) {
            uint256 sum;
            for (uint256 i = 0; i < amounts.length; ++i) {
                sum += amounts[i];
            }
            uint32 mult = _effectiveMultiplier(msg.sender);
            uint256 available = IGenyAirdrop(airdropContract).getTippingQuota(msg.sender, seasonId, mult);
            require(available >= sum, "Insufficient tipping quota");
        }

        for (uint256 i = 0; i < recipients.length; ++i) {
            _tipInternal(recipients[i], amounts[i], seasonId, maxTippingAmount, merkleProof);
        }
    }

    // --- Views ---

    function getUserProfile(address user)
        external
        view
        returns (bytes32 labelId, string memory labelName, uint32 multiplier, bool isActive)
    {
        Profile memory p = profiles[user];
        Label memory l = labels[p.labelId];
        return (p.labelId, l.name, l.multiplier, p.isActive);
    }

    function getLabel(bytes32 labelId)
        external
        view
        returns (string memory name, uint32 multiplier, bool active)
    {
        Label memory l = labels[labelId];
        return (l.name, l.multiplier, l.active);
    }

    /// @notice Helper to derive labelId from name (keccak256).
    function labelIdFromName(string calldata name) external pure returns (bytes32) {
        return _id(name);
    }

    // --- Pause / Upgrade ---

    function pause() external onlyOwner { _pause(); }
    function unpause() external onlyOwner { _unpause(); }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // --- Internals ---

    function _tipInternal(
        address _recipient,
        uint96  _amount,
        uint32  _seasonId,
        uint256 _maxTippingAmount,
        bytes32[] calldata _merkleProof
    ) internal {
        require(_recipient != address(0) && _amount > 0, "Invalid tip");
        require(!isRecipientBlacklisted[_recipient], "Recipient blacklisted");
        require(token.balanceOf(msg.sender) >= minHolding, "Insufficient holding");

        Profile memory p = profiles[msg.sender];
        require(p.isActive, "User not eligible");
        Label memory l = labels[p.labelId];
        require(l.active, "Label not active");

        uint32 multiplier = l.multiplier;

        if (usePrecheck) {
            uint256 available = IGenyAirdrop(airdropContract).getTippingQuota(msg.sender, _seasonId, multiplier);
            require(available >= _amount, "Insufficient tipping quota");
        }

        // Consume quota & transfer tokens to recipient (executed/enforced by Airdrop)
        IGenyAirdrop(airdropContract).useTippingQuotaTo(
            msg.sender,
            _recipient,
            _seasonId,
            _amount,
            multiplier,
            _maxTippingAmount,
            _merkleProof
        );

        emit TipSubmitted(msg.sender, _recipient, _seasonId, _amount, p.labelId);
    }

    function _upsertLabel(bytes32 labelId, string memory name, uint32 multiplier, bool active) internal {
        require(labelId != bytes32(0), "Invalid labelId");
        require(bytes(name).length != 0, "Empty name");
        require(multiplier > 0, "Invalid multiplier");
        labels[labelId] = Label({multiplier: multiplier, active: active, name: name});
        emit LabelUpserted(labelId, name, multiplier, active);
    }

    function _id(string memory name) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(name));
    }

    /// @dev Returns the multiplier for msg.sender's current label (>=1).
    function _effectiveMultiplier(address user) internal view returns (uint32) {
        Label memory l = labels[profiles[user].labelId];
        return l.active ? l.multiplier : uint32(1);
    }

    /// @dev Storage gap for future upgrades.
    uint256[45] private __gap;
}

interface IGenyAirdrop {
    function getTippingQuota(address user, uint32 seasonId, uint32 multiplier) external view returns (uint256);
    function useTippingQuotaTo(
        address sender,
        address to,
        uint32 seasonId,
        uint96 amount,
        uint32 multiplier,
        uint256 maxTippingAmount,
        bytes32[] calldata merkleProof
    ) external;
}
