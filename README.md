# Super DCA Token & Gauge

![Super DCA Token & Gauge](./images/UniswapHookEmitterBanner.jpg)

### a.k.a. Uniswap Token Emitter Hook
_The system for developers looking to do a fair distribution of an inflationary token that is split 50/50 between Uniswap V4 Liquidity Providers and the developers._

## Super DCA uses Uniswap V4 Hooks for Token Distribution
The `SuperDCAGauge` contract is a specialized Uniswap V4 pool hook designed to implement a staking and reward distribution system for `SuperDCAToken` tokens. It integrates with Uniswap V4 pools to distribute rewards during liquidity events. The primary functions of the `SuperDCAGauge` are:

- **Before Liquidity Addition**: When liquidity is added to the pool, the hook:
  1. Updates the global reward index based on elapsed time and mint rate
  2. Calculates rewards for the pool based on staked amounts
  3. If rewards are available:
     - Splits rewards 50/50 between the pool (community) and developer
     - Donates the community share to the pool
     - Transfers the developer share to the developer address

- **Before Liquidity Removal**: The same distribution process occurs before liquidity is removed, following identical steps as the liquidity addition hook.

Key features:
- Only processes rewards for pools that include SuperDCAToken and have the correct fee (0.05%)
- Users can stake SuperDCATokens for specific token pools to participate in rewards
- Rewards for each pool are calculated based on staked amounts per pool, the total staked amount, the mint rate, and time elapsed


### Distribution Process Diagram
```mermaid
stateDiagram-v2
    direction LR

    state "Liquidity Provider" as LP_ETH
    state "ETH‑DCA Pool" as Pool_ETH
    state "SuperDCAGauge (ETH‑DCA)" as Hook_ETH
    state "SuperDCAToken" as Token
    state "Developer" as Developer
    

    %% ETH‑DCA Pool Flow
    LP_ETH --> Pool_ETH: 1.mint/burn()
    Pool_ETH --> Hook_ETH: 2.beforeAdd/RemoveLiquidity()
    Hook_ETH --> Token: 3.mint()
    Token --> Hook_ETH: 4.transfer()
    Hook_ETH --> Pool_ETH: 5.donate()
    Hook_ETH --> Developer: 6.transfer()
```
1. The `Liquidity Provider` adds/removes liquidity to the `ETH‑DCA Pool`
2. The `ETH‑DCA Pool` calls the `SuperDCAGauge` hook's beforeModifyLiquidity function
3. The `SuperDCAGauge` calculates rewards based on elapsed time and staked amounts
4. The `SuperDCAToken` mints new tokens to the `SuperDCAGauge` based on the mint rate

The `SuperDCAGauge` splits rewards 50/50 between:

   5. Pool (community share): Donated via Uniswap v4's donate function
   6. Developer: Transferred directly to developer address

### Super DCA Gauge Distribution System Specifications

The `SuperDCAGauge` contract implements a gauge-style staking and reward distribution system for Uniswap V4 pools. When users add or remove liquidity from eligible pools (e.g., 0.05% fee tier pools containing DCA token), rewards are distributed to the members of the pool using Uniswap v4 `donate` functionality. 


DCA token holders `stake` their tokens in the `SuperDCAGauge` contract for a specific `token` pool (e.g., USDC, WETH). The magnitude of the stake amount relative to the total staked amount for all tokens determines the reward amount for each token's pool (e.g., USDC-DCA, WETH-DCA). The reward amount for each pool is calculated based on tracking an index that increases over time according to the mint rate. The following are the key formulas for the reward calculation:
```
# Minted Tokens
mintedTokens = mintRate * timeElapsed

# Reward Index
rewardIndex += mintedTokens / totalStaked

# Reward per token
reward = token.stakedAmount * (currentRewardIndex - token.lastRewardIndex)
```
where the reward index increases over time according to the mint rate. All rewards are split 50/50 between the pool (community) and developer. The `rewardIndex` in the contract closely mirrors the `incomeIndex`-method used by Aave for interest accrual. 

#### Example
In this example, we show how the `rewardIndex` is updated to accrue rewards for all pools. Consider two pools with 1000 total DCA staked:
```
USDC-DCA pool: 600 DCA staked (60%)
WETH-DCA pool: 400 DCA staked (40%)
Total Staked = 1000 DCA
```
Consider the emission rate of 100 DCA/s (in wei). After 20 seconds, _2000 DCA_  rewards are generated. Which means that the community share is **1000 DCA**.
```
Current Reward Index = 0 
Reward Amount    = 1000 DCA
Total Staked     = 1000 DCA
Reward per Token = Reward / Total Staked
                 = 1000 DCA / 1000 DCA
                 = 1 DCA
Next Reward Index += Rewards per Token
                  = 0 + 1 DCA
                  = 1 DCA
```
This indicates all pools have been credited with 1 units of reward _per token staked_ to the token's pool. And the math for recovering the current amount of rewards for each pool is as follows:
```
Pool Reward = stakedAmount * (currentIndex - lastClaimIndex)
USDC-DCA Reward = 600 DCA * (1 - 0) = 600 DCA
WETH-DCA Reward = 400 DCA * (1 - 0) = 400 DCA
```
When a pool triggers a reward distribution, the `rewardIndex` is updated to the current index and that pool's share of the rewards is minted and distributed to the pool and the developer. The other pools that did not trigger a reward distribution are not affected.

## Deployment Addresses

### Unichain Sepolia

| Contract | Address |
| --- | --- |
| `SuperDCAToken` | [0xFddB9180Dfa8c572A10ba939F901Abce15923Bc4](https://unichain-sepolia.blockscout.com/address/0xFddB9180Dfa8c572A10ba939F901Abce15923Bc4) |
| `SuperDCAGauge` | [0x5cdcf75823620d1D93cf90BD4f768982fdecca00](https://unichain-sepolia.blockscout.com/address/0x5cdcf75823620d1D93cf90BD4f768982fdecca00) |

