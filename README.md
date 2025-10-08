# BETME Smart Contracts

## Overview

BETME is a decentralized peer-to-peer betting platform deployed on **Binance Smart Chain (BSC)**. The platform enables users to create and participate in bets with transparent, blockchain-based resolution and reward distribution.

## Deployed Contracts

**Network**: Binance Smart Chain (BSC Mainnet)


## Smart Contracts

### 1. BETMEToken.sol

The native platform token with the following specifications:

- **Symbol**: BET
- **Decimals**: 9
- **Total Supply**: 1,000,000,000 (1 billion)
- **Standard**: ERC20 with trading controls
- **Features**:
  - Tradable flag to control token transfers before official launch
  - Owner-controlled trading restrictions
  - Standard ERC20 functionality

### 2. BETMECore.sol

The main betting contract that handles all bet operations:

- **Bet Creation**: Users create bets by depositing BNB
- **Bet Acceptance**: Counterparties accept bets by matching the stake
- **Judge Resolution**: Designated judges determine bet outcomes
- **Fee Distribution**:
  - 60% of platform fees go to stakers
  - Remaining 40% goes to platform treasury
- **Security**: ReentrancyGuard protection on all critical functions

### 3. BETMEStaking.sol

Staking contract with weekly BNB reward distribution:

- **Stake BETME Tokens**: Users lock BET tokens to earn BNB rewards
- **Weekly Rewards**: Platform fees are distributed weekly to stakers
- **Weighted System**: Rewards calculated based on stake amount and duration
- **Flexible Unstaking**: Users can unstake anytime
- **Automated Distribution**: Weekly reward periods that require finalization

## How It Works

1. **Create a Bet**: Users deposit BNB and set bet parameters (counterparty, judge, terms)
2. **Accept Bet**: Counterparty reviews and accepts by matching the stake
3. **Judge Decision**: Designated judge resolves the bet
4. **Distribution**: Winner receives payout, platform fee goes to stakers
5. **Staking Rewards**: BETME holders stake tokens to earn BNB from platform fees

## Security Features

- OpenZeppelin battle-tested libraries
- ReentrancyGuard on all state-changing functions
- Owner access controls
- No proxy/upgradeable contracts (immutable logic)

## Network Details

- **Chain**: Binance Smart Chain (BSC)
- **Chain ID**: 56 (Mainnet)
- **Native Currency**: BNB
- **Block Explorer**: [BSCScan](https://bscscan.com)

