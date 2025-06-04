# Genyleap Token (GENY)
A Token for Empowering Everyone, Fueling Boundless Innovation. Powered by /genyleap ecosystem.

## Overview

The **Genyleap Token (GENY)** is an ERC20 token designed to empower creators and foster innovation within the Genyleap ecosystem. With a fixed supply of **256 million tokens**, GENY supports decentralized governance, incentivizes community participation, and drives the platform's mission of creativity and collaboration. Built with secure, upgradeable smart contracts, GENY ensures transparency, flexibility, and long-term sustainability.

For more details, visit [genyleap.com/token](https://genyleap.com/token).

## Features

- **Fixed Supply**: 256 million tokens with 18 decimals for predictable tokenomics.
- **Gasless Approvals**: ERC20 Permit enables gas-efficient, signature-based approvals.
- **Decentralized Governance**: Voting mechanisms for community-driven decisions.
- **Flexible Allocations**: Customizable vesting and unlocked token distributions.
- **Upgradeable Contracts**: UUPS proxy pattern for secure, future-proof upgrades.
- **Metadata Compliance**: Supports ERC-7572 for rich token metadata.
- **Robust Security**: Leverages OpenZeppelin libraries and multisig governance.

## Contracts

### Genyleap Token (GENY)
- **Purpose**: Core ERC20 token with a fixed supply of 256 million tokens.
- **Functionality**:
  - Implements ERC20 standards with permit (gasless approvals) and voting capabilities.
  - Mints the entire supply to an allocation contract upon deployment.
  - Supports ERC-7572 for contract metadata.
  - Emits events for transfers, metadata updates, and initialization.
- **Security**: Includes zero-address checks, custom errors, and non-payable constructor to prevent ETH locking.

### Allocation Contract
- **Purpose**: Manages vested and unlocked token distributions for beneficiaries.
- **Functionality**:
  - Supports multiple beneficiaries with customizable vesting schedules (cliff, duration, intervals).
  - Tracks released and withdrawn tokens, ensuring transparency.
  - Allows the owner (multisig) to create, cancel, or update allocations.
  - Provides view functions for releasable and remaining token amounts.
- **Security**: Uses OpenZeppelin's upgradeable contracts (Ownable2Step, ReentrancyGuard, Pausable) and SafeERC20 for safe token transfers.

### UUPS Proxy
- **Purpose**: Enables upgradeability for the allocation contract.
- **Functionality**:
  - Follows ERC1967 standard for proxy storage.
  - Delegates calls to the implementation contract.
  - Allows the admin (multisig) to upgrade the implementation or change the admin.
- **Security**: Validates contract addresses, restricts upgrades to the admin, and uses assembly for efficient storage management.

## Tokenomics

The GENY token has a total supply of **256 million tokens**, minted to the allocation contract upon deployment. The allocation contract manages:
- **Vested Distributions**: Customizable vesting schedules for stakeholders (e.g., team, partners).
- **Unlocked Distributions**: Immediate token releases for specific use cases (e.g., liquidity pools).
- **Transparent Tracking**: All allocations and releases are auditable on-chain.

## Security

- **Multisig Governance**: Key operations are controlled by a multisig wallet (e.g., Gnosis Safe).
- **Pausable & Non-Reentrant**: Built-in safeguards for critical operations.
- **Audited Libraries**: Uses OpenZeppelin's battle-tested contracts.
- **Security Contact**: Report issues to [security@genyleap.com](mailto:security@genyleap.com).

## License

This project is licensed under the MIT License. See the SPDX-License-Identifier in the source code for details.

## Contact

- **Website**: [genyleap.com](https://genyleap.com)
- **GitHub**: [github.com/genyleap](https://github.com/genyleap)
- **Security**: [security@genyleap.com](mailto:security@genyleap.com)

## Disclaimer

This project is provided as-is. Users should conduct their own due diligence before interacting with the token or contracts. Always verify contract addresses and follow secure practices.