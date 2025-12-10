// SPDX-License-Identifier: MIT
// Copyright (c) 2025 Genyleap

pragma solidity 0.8.30;

import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title GenyGuard (Recovery + Token Guard)
 * @author compez.eth
 * @notice Non-custodial recovery + token lock guard. Supports emergency withdrawal via recovery wallet.
 * @dev UUPS-upgradeable. Compatible with old recovery code init. Codes are 28 alphanumeric chars.
 */
contract GenyGuard is Initializable, Ownable2StepUpgradeable, UUPSUpgradeable {
    // --- Storage ---
    IERC20 public token;

    mapping(address => address) private _recoveryWallet;
    mapping(address => bool)    private _recoveryModeActivated;
    mapping(address => bool)    private _isCompromised;
    mapping(address => bytes32) private _recoveryKeyHash;
    mapping(address => uint256) private _lockedBalance;

    // --- Events ---
    event RecoveryWalletSet(address indexed user, address indexed recoveryWallet);
    event RecoveryModeActivated(address indexed user);
    event RecoveryModeDeactivated(address indexed user);
    event AddressCompromised(address indexed compromisedWallet);
    event RecoveryKeyRotated(address indexed user, bytes32 indexed newRecoveryKeyHash);
    event TokensLocked(address indexed user, uint256 amount);
    event TokensWithdrawn(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, address indexed to, uint256 amount);
    event AdminWithdraw(address indexed user, address indexed to, uint256 amount);

    // --- Errors ---
    error InvalidAddress();
    error InvalidCode();
    error InvalidCodeFormat();
    error RecoveryWalletAlreadySet();
    error RecoveryWalletNotSet();
    error RecoveryKeyAlreadySet();
    error RecoveryKeyNotSet();
    error RecoveryModeAlreadyActive();
    error NotInRecoveryMode();
    error InsufficientLockedBalance(uint256 requested, uint256 available);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IERC20 token_) {
        _disableInitializers();
        if (address(token_) == address(0)) revert InvalidAddress();
        token = token_;
    }

    /**
     * @notice Initialize (UUPS, old-style)
     * @param owner_ Contract owner (multisig/timelock)
     */
   function initialize(address owner_, IERC20 token_) external initializer {
     if (owner_ == address(0)) revert InvalidAddress();
     if (address(token_) == address(0)) revert InvalidAddress();
       __Ownable2Step_init();
       __UUPSUpgradeable_init();
       _transferOwnership(owner_);
       token = token_;
    }


    // ========= Recovery flows =========

    function setRecoveryKey(bytes32 recoveryKeyHash) external {
        if (recoveryKeyHash == bytes32(0)) revert InvalidCode();
        if (_recoveryKeyHash[msg.sender] != bytes32(0)) revert RecoveryKeyAlreadySet();
        _recoveryKeyHash[msg.sender] = recoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, recoveryKeyHash);
    }

    function setRecoveryWallet(address wallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (wallet == address(0)) revert InvalidAddress();
        if (_recoveryWallet[msg.sender] != address(0)) revert RecoveryWalletAlreadySet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = wallet;
        emit RecoveryWalletSet(msg.sender, wallet);
    }

    function activateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (_recoveryWallet[msg.sender] == address(0)) revert RecoveryWalletNotSet();
        if (_recoveryModeActivated[msg.sender]) revert RecoveryModeAlreadyActive();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = true;
        _isCompromised[msg.sender] = true;
        emit RecoveryModeActivated(msg.sender);
        emit AddressCompromised(msg.sender);
    }

    function changeRecoveryWallet(address newWallet, string calldata code, bytes32 newRecoveryKeyHash) external {
        if (newWallet == address(0)) revert InvalidAddress();
        if (_recoveryWallet[msg.sender] == address(0)) revert RecoveryWalletNotSet();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryWallet[msg.sender] = newWallet;
        emit RecoveryWalletSet(msg.sender, newWallet);
    }

    function deactivateRecoveryMode(string calldata code, bytes32 newRecoveryKeyHash) external {
        if (!_recoveryModeActivated[msg.sender]) revert NotInRecoveryMode();
        _rotateRecoveryKey(code, newRecoveryKeyHash);
        _recoveryModeActivated[msg.sender] = false;
        emit RecoveryModeDeactivated(msg.sender);
    }

    // ========= Internal recovery logic =========

    function _rotateRecoveryKey(string calldata code, bytes32 newRecoveryKeyHash) internal {
        bytes32 current = _recoveryKeyHash[msg.sender];
        if (current == bytes32(0)) revert RecoveryKeyNotSet();
        if (!_isValidRecoveryCode(code)) revert InvalidCodeFormat();
        if (keccak256(abi.encodePacked(_normalizeCode(code))) != current) revert InvalidCode();
        if (newRecoveryKeyHash == bytes32(0) || newRecoveryKeyHash == current) revert InvalidCode();
        _recoveryKeyHash[msg.sender] = newRecoveryKeyHash;
        emit RecoveryKeyRotated(msg.sender, newRecoveryKeyHash);
    }

    function _isValidRecoveryCode(string calldata code) internal pure returns (bool ok) {
        bytes calldata b = bytes(code);
        uint256 len = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "-") continue;
            bool isNum = (c >= 0x30 && c <= 0x39);
            bool isUp  = (c >= 0x41 && c <= 0x5A);
            bool isLo  = (c >= 0x61 && c <= 0x7A);
            if (!(isNum || isUp || isLo)) return false;
            unchecked { ++len; }
        }
        return len == 28;
    }

    function _normalizeCode(string calldata code) internal pure returns (string memory out) {
        bytes calldata b = bytes(code);
        bytes memory nrm = new bytes(28);
        uint256 n = 0;
        for (uint256 i = 0; i < b.length; ++i) {
            bytes1 c = b[i];
            if (c == "-") continue;
            if (c >= 0x61 && c <= 0x7A) c = bytes1(uint8(c) - 32);
            nrm[n++] = c;
            if (n == 28) break;
        }
        return string(nrm);
    }

    // ========= Token Lock/Unlock =========

    function lockTokens(uint256 amount) external {
        if (amount == 0) revert InvalidAddress();
        _lockedBalance[msg.sender] += amount;
        token.transferFrom(msg.sender, address(this), amount);
        emit TokensLocked(msg.sender, amount);
    }

    function withdrawWithCode(string calldata code, address to) external {
        bytes32 current = _recoveryKeyHash[msg.sender];
        if (current == bytes32(0)) revert RecoveryKeyNotSet();
        if (keccak256(abi.encodePacked(_normalizeCode(code))) != current) revert InvalidCode();

        uint256 amt = _lockedBalance[msg.sender];
        if (amt == 0) revert InsufficientLockedBalance(0, 0);
        _lockedBalance[msg.sender] = 0;
        token.transfer(to, amt);
        emit TokensWithdrawn(msg.sender, amt);
    }

    function guardedBalance(address user) external view returns (uint256) {
        return _lockedBalance[user];
    }

    // ========= Emergency/Admin Withdraw =========

    function emergencyWithdrawToRecovery(address user) external {
        address rec = _recoveryWallet[user];
        if (rec == address(0)) revert RecoveryWalletNotSet();
        uint256 amt = _lockedBalance[user];
        if (amt == 0) return;
        _lockedBalance[user] = 0;
        token.transfer(rec, amt);
        emit EmergencyWithdraw(user, rec, amt);
    }

    function adminWithdraw(address user, address to) external onlyOwner {
        uint256 amt = _lockedBalance[user];
        if (amt == 0) return;
        _lockedBalance[user] = 0;
        token.transfer(to, amt);
        emit AdminWithdraw(user, to, amt);
    }

    // ========= Views =========

    function getRecoveryWallet(address user) external view returns (address) { return _recoveryWallet[user]; }
    function isRecoveryModeActive(address user) external view returns (bool) { return _recoveryModeActivated[user]; }
    function isCompromised(address user) external view returns (bool) { return _isCompromised[user]; }
    function getRecoveryKeyHash(address user) external view returns (bytes32) { return _recoveryKeyHash[user]; }

    // ========= Upgrades =========
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /// @dev Storage gap for future variables (OZ pattern)
    uint256[50] private __gap;
}
