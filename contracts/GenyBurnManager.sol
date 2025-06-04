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

contract GenyBurnManager is Initializable, Ownable2StepUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    IERC20Upgradeable public token;
    address public dao;
    address public allocationManager;
    uint48 public lastBurnTimestamp;
    uint256 public burnCount;
    uint256 public totalBurned;
    uint256 public constant MAX_TOTAL_BURN = 25_600_000 * 1e18;

    uint48 public constant BURN_COOLDOWN = 1 days;
    uint32 public constant BURN_MAX_PERCENT = 10_00;

    event TokensBurned(uint256 indexed burnId, uint256 amount);

    function initialize(address _token, address _dao, address _allocationManager, address _owner) external initializer {
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

    function burnFromContract(uint256 amount) external onlyOwnerOrDAO nonReentrant whenNotPaused {
        require(block.timestamp >= lastBurnTimestamp + BURN_COOLDOWN, "Burn cooldown active");
        require(amount <= (token.balanceOf(allocationManager) * BURN_MAX_PERCENT) / 1e4, "Exceeds max burn limit");
        require(totalBurned + amount <= MAX_TOTAL_BURN, "Exceeds total burn cap");
        require(amount > 0, "Invalid amount");

        lastBurnTimestamp = uint48(block.timestamp);
        totalBurned += amount;
        IERC20Upgradeable(token).safeTransferFrom(allocationManager, address(0xdead), amount);

        emit TokensBurned(burnCount++, amount);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    modifier onlyOwnerOrDAO() {
        require(msg.sender == owner() || msg.sender == dao, "Not authorized");
        _;
    }
}