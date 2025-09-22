# Optimism Mainnet Fork Integration Tests

This directory contains comprehensive integration tests for the SuperDCA contracts that run against Optimism mainnet using Foundry's fork testing capabilities.

## Overview

The integration tests validate the complete SuperDCA ecosystem by testing against real Uniswap V4 infrastructure and live DCA token on Optimism mainnet. These tests ensure proper contract interaction, access controls, stake/gauge accounting, and environment compatibility.

## Test Structure

### Base Framework
- **OptimismIntegrationBase.t.sol**: Foundation test contract that provides:
  - Optimism mainnet fork setup with proper RPC configuration
  - Real Uniswap V4 contract addresses (PoolManager, PositionManager, etc.)
  - SuperDCA contract deployment using actual deployment scripts
  - Helper functions for pool creation and position management
  - Struct-based architecture to avoid stack-too-deep errors

### Contract-Specific Tests

#### 1. SuperDCAListing Integration (OptimismListingIntegration.t.sol)
Tests for token listing functionality:
- ✅ Successful token listing with valid full-range positions
- ✅ Failure cases: insufficient liquidity, incorrect hook, already listed tokens
- ✅ Administrative functions: minimum liquidity updates, hook address management
- ✅ Fee collection from listed positions
- ✅ Multiple token listing scenarios

#### 2. SuperDCAStaking Integration (OptimismStakingIntegration.t.sol)
Tests for staking mechanics:
- ✅ Successful DCA token staking for listed tokens
- ✅ Staking validation: unlisted tokens, zero amounts, missing gauge
- ✅ Unstaking functionality with balance tracking
- ✅ Reward index updates and time-based accrual
- ✅ Multi-user staking scenarios
- ✅ Administrative controls: mint rate updates, gauge management

#### 3. SuperDCAGauge Integration (OptimismGaugeIntegration.t.sol)
Tests for hook and gauge functionality:
- ✅ Pool initialization with proper DCA token validation
- ✅ Dynamic fee assignment for different user types (internal, keeper, external)
- ✅ Keeper mechanism with king-of-the-hill deposit system
- ✅ Fee configuration management
- ✅ Integration with listing contract for token validation
- ✅ Access control for admin and manager functions

## Key Features

### Real Uniswap V4 Integration
- Uses actual Optimism mainnet Uniswap V4 contracts
- Creates real full-range positions using PositionManager
- Proper Permit2 integration for token approvals
- Accurate liquidity calculations and tick management

### Comprehensive Test Coverage
- **Contract Deployment**: All three contracts properly deployed and configured
- **Token Listing**: Full-range position validation and custody transfer
- **Staking Mechanics**: DCA token staking with reward index tracking
- **Hook Integration**: Dynamic fee assignment and pool validation
- **Access Controls**: Owner, admin, and manager role enforcement
- **Error Handling**: Comprehensive failure case coverage

### Stack Optimization
- Struct-based architecture prevents stack-too-deep compilation errors
- Modular helper functions for complex operations
- Clean separation of concerns between setup, execution, and validation

## Configuration

### Environment Variables
```bash
OPTIMISM_RPC_URL=<your_optimism_rpc_url>
OPTIMISM_BLOCK_NUMBER=<optional_block_number_for_pinning>
```

### Contract Addresses (Optimism Mainnet)
- **PoolManager**: `0x9a13F98Cb987694C9F086b1F5eB990EeA8264Ec3`
- **PositionManager**: `0x3C3Ea4B57a46241e54610e5f022E5c45859A1017`
- **Quoter**: `0x1f3131A13296FB91C90870043742C3CDBFF1A8d7`
- **Universal Router**: `0x851116D9223fabED8E56C0E6b8Ad0c31d98B3507`
- **Permit2**: `0x000000000022D473030F116dDEE9F6B43aC78BA3`
- **DCA Token**: `0xb1599CDE32181f48f89683d3C5Db5C5D2C7C93cc`
- **WETH**: `0x4200000000000000000000000000000000000006`

## Running the Tests

### Prerequisites
1. Set up your `.env` file with the required variables
2. Ensure you have access to an Optimism mainnet RPC endpoint

### Execution
```bash
# Run all integration tests
forge test --match-path "test/integration/*" --fork-url optimism

# Run specific test contract
forge test --match-contract OptimismListingIntegration --fork-url optimism

# Run with verbose output
forge test --match-path "test/integration/*" --fork-url optimism -vvv
```

### Block Pinning
For consistent test results, pin to a specific block:
```bash
export OPTIMISM_BLOCK_NUMBER=128000000
forge test --match-path "test/integration/*" --fork-url optimism
```

## Test Scenarios

### Core Functionality
1. **Token Listing Flow**: Create pool → Add liquidity → List token → Verify custody
2. **Staking Flow**: List token → Stake DCA tokens → Verify accounting → Unstake
3. **Gauge Integration**: Initialize pool → Trigger hooks → Verify reward distribution
4. **Fee Management**: Set different user types → Verify fee assignment → Update rates

### Edge Cases
- Insufficient liquidity for listing
- Staking in unlisted tokens
- Hook validation failures
- Access control violations
- King-of-the-hill keeper displacement

### Multi-Contract Scenarios
- End-to-end flows involving all three contracts
- Cross-contract state consistency
- Time-based reward accrual and distribution

## Architecture Benefits

### Real Environment Testing
- Validates against actual Optimism infrastructure
- Ensures contract compatibility with live Uniswap V4
- Tests with real DCA token economics
- Uses actual deployment scripts to ensure test deployment matches production

### Comprehensive Coverage
- Tests both success and failure paths
- Validates all major contract interactions
- Ensures proper access control enforcement

### Maintainable Design
- Modular structure allows easy test addition
- Clear separation between setup and test logic
- Struct-based approach scales well with complexity

## Future Enhancements

- Add gas usage profiling for operations
- Implement more complex multi-pool scenarios
- Add integration with external DeFi protocols
- Create performance benchmarks for large-scale operations