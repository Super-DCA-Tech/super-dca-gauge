# Super DCA Gauge Security Audit Documentation

## Table of Contents
- [Summary (What, Who, How)](#summary-what-who-how)
- [Architecture Overview](#architecture-overview)
- [Actors, Roles & Privileges](#actors-roles-privileges)
- [User Flows (Primary Workflows)](#user-flows-primary-workflows)
- [State, Invariants & Properties](#state-invariants-properties)
- [Economic & External Assumptions](#economic-external-assumptions)
- [Upgradeability & Initialization](#upgradeability-initialization)
- [Parameters & Admin Procedures](#parameters-admin-procedures)
- [External Integrations](#external-integrations)
- [Build, Test & Reproduction](#build-test-reproduction)
- [Known Issues & Areas of Concern](#known-issues-areas-of-concern)
- [Appendix](#appendix)

## Summary (What, Who, How)
- **What the system does:** Super DCA Gauge is a Uniswap v4 hook plus companion staking and listing modules that mint and route newly issued DCA tokens to eligible pools and the developer treasury during liquidity events while enforcing token listing, staking accounting, and dynamic swap fees. 
  - The staking system works like Curve's Gauge system, where emissions are redirected to the various pools (e.g., USDC-DCA, ETH-DCA) based on their stake weighting.
  - The listing system controls which tokens are eligible to receive emissions and requires someone "lists" a token by permanently transferring it to the listing system. To list a token, it must meet a minimum DCA token liquidity requirement (1000 DCA) and be a full range position to avoid competing against active/concentrated Liquidity providers. Fees earned can be collected by the listing systems owner.
- **Who uses it:** Liquidity providers (LPs), DCA stakers, keeper candidates, swap traders, protocol developer/treasury admins, and listing operators. 
  - The hook is primary purpose is to offer Super DCA Pools that perform DCA 0% AMM fees. Super DCA Pool contracts will be set as "internal" addresses manually as they are deployed.
  - Additionally, all other users of these liquidity pools are charged a higher fee to make up for the 0% fee charged to the Super DCA pool contracts.
- **How at a high level:** A listing contract holds full-range Uniswap v4 positions to whitelist partner tokens to earn DCA token rewards. Stakers deposit DCA into per-token buckets tracked by `SuperDCAStaking` to adjust the allocations of a fixed reward flow (10K DCA/month default). When LPs modify liquidity, the `SuperDCAGauge` hook accrues staking rewards, mints DCA via the token owner privilege, donates community rewards to the pool, and transfers the developer share. The hook also enforces dynamic swap fees (internal, keeper, external) and holds the keeper's DCA deposits. Anyone can become the keeper to receive a reduced fee if they stake the most DCA tokens to the `SuperDCAGauge` (i.e., king of the hill staking) Access is mediated via `AccessControl` (gauge) and `Ownable2Step` (staking/listing).
- **Audit scope freeze:** Repository `super-dca-gauge` tagged `audit-freeze-20250922` on the `master` branch.

## Architecture Overview
### Module map

Contract | Responsibility | Key external funcs | Critical invariants
-- | -- | -- | --
`SuperDCAGauge` | Uniswap v4 hook distributing rewards, enforcing pool eligibility, dynamic fees, keeper deposits, and admin fee controls. | `setStaking`, `setListing`, `becomeKeeper`, `setFee`, `setInternalAddress`, `returnSuperDCATokenOwnership`, hook callbacks. | Only pools containing DCA and dynamic fee flag initialize; reward accrual cannot revert; donation splits stay 50/50 when mint succeeds; fee overrides respect role checks.
`SuperDCAStaking` | Tracks per-token staking buckets and global reward index used by the gauge. Works like Curve's Gauge in how it distributes rewards to different liquidity pools. | `stake`, `unstake`, `accrueReward`, `setGauge`, `setMintRate`. | Reward index monotonic; staking totals updated atomically; only configured gauge can accrue rewards.
`SuperDCAListing` | Custodies full-range Uniswap v4 NFT positions (NFPs), validates hook usage, and marks partner tokens listed. Allows the owner to collect fees earned by these permenantly locked NFPs | `list`, `setMinimumLiquidity`, `setHookAddress`, `collectFees`. | Listed token must pair with DCA, use expected hook, and meet liquidity threshold; duplicates prevented.
`SuperDCAToken` | Minimal ERC20 + permit minted by owner (gauge during operations). Added in this repository for reference only. Previously deployed to `0xb1599cde32181f48f89683d3c5db5c5d2c7c93cc` on OP, Base, Unichain and Arbitrum. Some liquidity existing for this token in Uniswap V3 and V4 pools. | `mint`. | Ownership restricted to one account; decimals=18; mintable by the owner (gauge).

### Entry points
  - Gauge hook callbacks: 
    - `_beforeInitialize` - verifies DCA is one of the tokens.
    - `_afterInitialize` - verifies pool uses dynamic fees.
    - `_beforeAddLiquidity`, `_beforeRemoveLiquidity` - performs reward math and DCA token mints.
    - `_beforeSwap` - adjusts fees based on the msg sender, one of: internal, external, keeper.
  - Gauge admin: `setStaking`, `setListing`, `updateManager`, `setFee`, `setInternalAddress`, `returnSuperDCATokenOwnership`, `becomeKeeper`, `getKeeperInfo`.
  - Staking user actions: `stake`, `unstake`; gauge integration: `accrueReward`; admin: `setGauge`, `setMintRate`.
  - Listing ops: `list`, `setMinimumLiquidity`, `setHookAddress`, `collectFees`.

### Data flows (high level)
  1. Listing owner deposits full-range NFP → Listing contract marks partner token eligible for staking/gauge donations.
  2. Staker transfers DCA → Staking contract updates bucket share and global reward index.
  3. LP modifies liquidity → PoolManager triggers gauge hook → gauge accrues reward from staking and mints DCA split between pool donation and developer.
  4. Traders use liquidity in the pools → `_beforeSwap` hook adjusts fees dynamically, no fee for internal, low fee for keeper, high fee for external.
  5. Keeper candidate deposits DCA via `becomeKeeper` → gauge enforces higher deposit and refunds prior keeper, keeper gets lower fees when performing swaps.
  6. Admin updates parameters (e.g., mintRate, fees, minLiquidity) under role controls, given wide latitude to make parameter adjustments. 

## Actors, Roles & Privileges
### Roles

Role | Capabilities
-- | --
Default admin (developer multisig) | Holds `DEFAULT_ADMIN_ROLE` on gauge, can set staking/listing modules, rotate managers, reclaim token ownership, pause integrations off-chain via config changes.
Gauge manager | Accounts with `MANAGER_ROLE` on gauge can adjust dynamic fees and mark internal addresses.
Listing owner | `Ownable2Step` owner can set expected hook, min liquidity, and collect fees for listed positions.
Staking owner | `Ownable2Step` owner can set authorized gauge and adjust mint rate; gauge can also change mint rate.
Liquidity provider | Adds/removes liquidity, triggering donations and reward minting via hook.
Staker | Deposits DCA into staking buckets to earn proportional rewards.
External Trader | Swaps through Uniswap V4 pools with the `SuperDCAGauge` hook; receive the highest fee for using the liquidity for external purposes.
Internal Trader | Designed to be Super DCA Pool contracts; receive 0% fee by default since they are using the liquidity for long-term orderflow.
Keeper | Highest-deposit account receiving reduced swap fee tier; deposit held by gauge until replaced.

### Access control design
  - Gauge uses OpenZeppelin `AccessControl` with `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE`. Only the staking contract address set by admin can be called for reward accrual. Keeper deposits are open, but fee edits and internal address management require manager role.
  - Staking and listing rely on `Ownable2Step`; owner must call `acceptOwnership`. Only owner (and gauge for mintRate) may update parameters. Limits on parameter changes are liberal to allow maximum flexibilty.
  - DCA Token ownership typically resides with gauge so it can mint; admin can reclaim via `returnSuperDCATokenOwnership`.

### Emergency controls
  - No explicit pause. Mitigations rely on revoking staking/listing addresses, resetting mintRate to zero, or reclaiming token ownership to halt minting. Keeper deposits can be reclaimed by surpassing deposit threshold (up only system). No timelocks present, so admin actions execute immediately.

## User Flows (Primary Workflows)
### Flow 1: Token listing onboarding
- **User story:** As the token owner/deployer, I want to list my token on Super DCA so it become available to traders and LPs earn DCA token rewards.
- **Preconditions:** Listing contract deployed with expected hook address; `list` caller holds full-range NFP minted with Super DCA token on one side and meets `minLiquidity`; approvals granted for NFT transfer.
- **Happy path steps:**
  1. Owner mints or acquires full-range NFP from Uniswap PositionManager.
  2. Owner calls `list(nftId, poolKey)` on `SuperDCAListing`.
  3. Contract pulls actual pool metadata, checks hook equals configured gauge, validates full-range ticks and minimum DCA liquidity.
  4. Contract marks partner token as listed, records NFP → token mapping, and transfers NFT custody to itself.
  5. Pair token from the NFP is now eligible to earn DCA token rewards, proportional to the amount of DCA staked to it on the staking system.
- **Alternates / edge cases:** Reverts if hook mismatch, liquidity below threshold, token already listed, or pool key mismatched; zero `nftId` or zero addresses revert; only owner can adjust hook/min liquidity. No automatic delisting; liquidity becomes permanently locked in the listing contract.
- **On-chain ↔ off-chain interactions:** Off-chain process to prepare NFP; all validations on-chain using Uniswap managers; Owner can collect fees on this position using `collectFees`.
- **Linked diagram:** [Token listing onboarding](./diagrams/token-listing.md)
- **Linked tests:** `test/SuperDCAListing.t.sol` 

### Flow 2: Staking and reward distribution on liquidity events
- **User story:** As a DCA staker, I want to redirect DCA token rewards to the liquidity pools that I provide liquidity to so I can earn more DCA token rewards.
- **Preconditions:** Gauge configured as staking contract's authorized caller; staking token approvals granted; target token is listed; pool initialized with gauge hook; gauge owns mint rights on DCA token.
- **Happy path steps:**
  1. Staker approves and calls `stake(listedToken, amount)` on `SuperDCAStaking`, which updates totals and global reward index.
  2. LP adds or removes liquidity on the pool; PoolManager calls gauge's hook.
  3. Gauge syncs DCA balance, calls `accrueReward(listedToken)`; staking updates reward index and returns owed amount.
  4. Gauge mints DCA (splitting 50/50) via `_tryMint`; community share is donated to the pool (if liquidity > 0) and developer share transferred.
  5. PoolManager settles donation; rewards accounted in staking via updated indexes.
- **Alternates / edge cases:** If pool has zero liquidity, all rewards go to developer; if mint fails, function continues without reverting and timestamp advances; if staking contract unset or token not listed, staking/ accrual reverts; paused or removed staking can halt accrual by setting mintRate=0 or revoking gauge authority.
- **On-chain ↔ off-chain interactions:** Entire flow on-chain; developer wallet receives transfer; donation accrues as pool fees.
- **Linked diagram:** [Staking and reward distribution on liquidity events](./diagrams/stake-reward-distribution.md)
- **Linked tests:** `test/SuperDCAGauge.t.sol`

### Flow 3: Keeper rotation and dynamic fee enforcement
- **User story:** As a keeper candidate, I want priority to execute arbitrage trades using the Super DCA Network's liquidity so I can make revenue. 
- **Preconditions:** Gauge deployed with DCA ownership and manager-set fees; candidate holds DCA tokens and approval for gauge; optional internal address list managed by managers.
- **Happy path steps:**
  1. Candidate approves DCA and calls `becomeKeeper(amount)`; gauge ensures `amount > keeperDeposit`, transfers deposit in, and refunds prior keeper if present.
  2. Gauge updates `keeper` and `keeperDeposit` state and emits `KeeperChanged`.
  3. When swaps occur, hook queries `IMsgSender(sender).msgSender()`; if address is marked internal, 0% fee; else if matches keeper, apply `keeperFee`; otherwise apply `externalFee` with override flag.
- **Alternates / edge cases:** Calls revert on zero amount or insufficient deposit; same keeper can increase deposit; manager role can retune fees or mark addresses; losing keeper obtains refund automatically; swapper classification depends on proxy contract implementing `IMsgSender`.
- **On-chain ↔ off-chain interactions:** Keeper deposit handled on-chain; off-chain monitoring needed to top up deposit or detect replacements.
- **Linked diagram:** [Keeper rotation and dynamic fee enforcement](./diagrams/keeper-dynamic-fee.md)
- **Linked tests:** Keeper deposit, refund, and fee configuration verified in `BecomeKeeperTest` suite and manager access tests in `test/SuperDCAGauge.t.sol`.

## State, Invariants & Properties
### State variables that matter
  - Gauge: `keeper`, `keeperDeposit`, `internalFee`, `externalFee`, `keeperFee`, `isInternalAddress`, references to staking/listing modules.
  - Staking: `mintRate`, `rewardIndex`, `lastMinted`, `totalStakedAmount`, per-token `TokenRewardInfo` (staked amount, last index).
  - Listing: `minLiquidity`, `expectedHooks`, `isTokenListed`, `tokenOfNfp`.

### Invariants (must always hold)

Invariant | Description | Enforcement / Tests
-- | -- | --
Pool eligibility | Only pools with Super DCA token and dynamic fee flag may initialize the hook. | `_beforeInitialize` / `_afterInitialize`; `test_beforeInitialize_revert_wrongToken`, `test_RevertWhen_InitializingWithStaticFee`.
Accrual monotonicity | `rewardIndex` increases with elapsed time when stake > 0; totals update on stake/unstake. | `_updateRewardIndex`; `testFuzz_UpdatesState`, `test_reward_calculation`.
Authorization | Only owner/manager/gauge may mutate sensitive parameters; unauthorized calls revert. | `AccessControl` & `Ownable2Step`; `test_RevertWhen_NonManagerSetsInternalFee/ExternalFee/KeeperFee`; `testFuzz_RevertIf_CallerIsNotOwnerOrGauge`.
Reward split | When donation occurs, minted rewards split 50/50 between developer and pool (±1 wei rounding). | `_handleDistributionAndSettlement`; `test_distribution_on_addLiquidity`, `test_distribution_on_removeLiquidity`.
Keeper supremacy | New keeper must deposit strictly more DCA; previous deposit refunded. | `becomeKeeper`; `test_becomeKeeper_replaceKeeper`, `test_becomeKeeper_revert_insufficientDeposit`.
Mint failure tolerance | Reward accrual proceeds even if token minting fails. | `_tryMint`; `test_whenMintFails_onAddLiquidity`, `test_whenMintFails_onRemoveLiquidity`.

### Property checks / assertions
Unit tests include limited fuzzing for staking stake/unstake operations and revert assertions for role checks. No dedicated invariant tests beyond test suites above. Integration tests verify core functionality against OP mainnet using real Uniswap V4 contracts.

## Economic & External Assumptions
### Token assumptions
DCA token is 18 decimals, non-rebasing, no fee-on-transfer; staking requires direct `transferFrom`, so fee-on-transfer partners incompatible without adapters.
### Listable Tokens
Any token listable through Uniswap V4 is eligible to earn DCA token rewards and can be listed through the Super DCA Listing contract.
### Oracle assumptions
None; system does not consume price feeds.
### Liquidity/MEV/DoS assumptions
  - LP-triggered rewards rely on sufficient LP adds and removes; long idle periods delay minting but accrue in index.
  - Donations require pool liquidity; empty pools route rewards entirely to developer.
  - `beforeSwap` executes every swap; gas overhead increases with dynamic fee logic and external. Logic here kept simple as possible to avoid adding overhead for swaps.
  - `IMsgSender` call, assuming router implements interface. Verified in integration tests.
  - Keeper deposit is a up-only system; king of the hill won't be able to withdraw their deposit. Replacing the keeper is the only way to recover the keeper deposit.

## Upgradeability & Initialization
### Pattern
All contracts are non-upgradeable, deployed as regular Solidity contracts with constructor-set immutables. Ownership can be transferred manually.
### Predeployed DCA Token
The DCA token is already deployed; its code is included in this repository for reference. This token is owned by `superdca.eth` currently but in practice its ownership is transferred to the gauge contract. Ownership can be recovered by the admin via `returnSuperDCATokenOwnership`.
### Initialization path
  - Gauge constructor sets DCA token, developer admin, default fees, and grants roles; admin later calls `setStaking`/`setListing`.
  - Staking constructor fixes token, mint rate, owner; owner sets gauge address post-deploy.
  - Listing constructor wires Uniswap managers, expected hook; owner can update hook later. Pool-level initialization occurs via Uniswap `initialize` using hook flags.
  - DCA Token ownership is transferred to the gauge contract. 
### Migration & upgrade safety checks
Manual process—revoke gauge role or transfer token ownership before deploying replacements; ensure new contracts respect same interfaces before switching addresses. In practice, LPs will have to withdraw and move their liquidity if a new staking or gauge contract is deployed. Listed NFPs will remain forever locked in the listing contract as part of the protocol's permanently locked liquidity. Fees on these positions will be collectable by the listing owner.

## Parameters & Admin Procedures
### Config surface

Parameter | Contract | Units / Range | Default | Who can change | Notes
-- | -- | -- | -- | -- | --
`mintRate` | Staking | DCA per second; expect ≤ token emission cap | Constructor arg | Owner or gauge | Setting to 0 halts new emissions.
`staking` address | Gauge | Contract address | unset | Gauge admin | Must be set before liquidity events or accrual reverts.
`listing` address | Gauge | Contract address | unset | Gauge admin | If unset, `isTokenListed` returns false, blocking staking.
`internalFee` | Gauge | basis points * 100 | 0 | Manager role | Applied to allowlisted traders (i.e. Super DCA contracts).
`externalFee` | Gauge | basis points * 100 | 5000 (0.50%) | Manager role | Default fallback fee for external traders (e.g., arbitrage/MEV traders).
`keeperFee` | Gauge | basis points * 100 | 1000 (0.10%) | Manager role | Used when swapper == keeper.
`isInternalAddress` | Gauge | bool map | false | Manager role | Grants 0% fee tier.
`expectedHooks` | Listing | address | constructor | Listing owner | Must match gauge hook flags.
`minLiquidity` | Listing | DCA wei | 1000e18 | Listing owner | Adjust to control listing quality.

### Runbooks
  - **Pause emissions:** Owner sets staking `mintRate=0` or removes gauge rights; optionally transfer token ownership away from gauge.
  - **Rotate manager:** Admin calls `updateManager(old,new)` on gauge; ensure new manager accepts responsibilities.
  - **Keeper replacement:** Encourage trusted actor to call `becomeKeeper` with higher deposit; previous deposit auto-refunded.
  - **Recover token ownership:** Admin calls `returnSuperDCATokenOwnership` to move ERC20 owner from gauge to admin wallet.

## External Integrations
### Addresses / versions
  - Uses local copies of Uniswap v4 core (`lib/v4-core`) and periphery (`lib/v4-periphery`) contracts for hooks, routers, and `IPositionManager`.
  - OpenZeppelin v5 libraries for ERC20, AccessControl, Ownable2Step; Permit2 interface for testing mocks.
  - README documents live deployments: Base `SuperDCAGauge` 0xBc5F..., Optimism 0xb4f4..., Super DCA token 0xb159..., Base Sepolia test deployment 0x7418....

### Failure assumptions & mitigations
  - **Uniswap PositionManager / PoolManager**: assumed honest; listing relies on returned pool data. Compromise could bypass listing checks.
  - **SuperDCAToken**: gauge must remain owner to mint; if ownership transferred inadvertently, reward minting fails but hooks continue without revert (developer share lost). Tests cover tolerance but system enters degraded mode until ownership restored.
  - **Permit2 / IMsgSender**: For dynamic fees to work behind routers, router must implement `IMsgSender`. Absent that, swapper may misclassify and pay external fee.

## Build, Test & Reproduction
### Environment prerequisites
Unix-like OS, Git, curl, Foundry toolchain (`forge`, `cast`, `anvil`) ≥ 1.0.0; Solidity compiler pinned to 0.8.26; Node optional for scripts; Python optional for utilities.

The exact foundry version used by the developer:
```bash
% forge --version
forge Version: 1.1.0-stable
Commit SHA: d484a00089d789a19e2e43e63bbb3f1500eb2cbf
Build Timestamp: 2025-04-30T13:50:49.971365000Z (1746021049)
```

### Clean-machine setup
  ```bash
  # 1) Install Foundry
  curl -L https://foundry.paradigm.xyz | bash
  source "$HOME/.foundry/bin/foundryup"  # or run foundryup after installation
  foundryup --version

  # 2) Clone repository
  git clone https://github.com/Super-DCA-Tech/super-dca-gauge.git
  cd super-dca-gauge
  git checkout
  git tag -l 'audit-freeze-20250922'

  # 3) (Optional) copy environment file for RPC endpoints
  cp .env.example .env  # populate OPTIMISM_RPC_URL etc. when running scripts
  ```
### Build
  ```bash
  forge build
  ```
### Tests
  ```bash
  # Prerequisite for integration tests
  export OPTIMISM_RPC_URL=<your_optimism_rpc_url>

  # Full suite with integration tests
  forge test -vv

  # Without integration tests
  forge test -vv --no-match-path "test/integration/*"

  # Single test example
  forge test --match-test test_distribution_on_addLiquidity -vv
  ```
### Coverage / fuzzing
No dedicated coverage artifacts committed; fuzz tests very limited in staking suite; full coverage is only achieved by running the integration tests. To run coverage locally: `forge coverage --report lcov`. `.github/workflows/ci.yml` contains the coverage commands that could be used to run coverage locally.

## Known Issues & Areas of Concern
- Donation/reward accounting where rounding is observed, possibly due to mechanics inside Uniswap V4.
- Gauge lacks explicit pause or timelock; admin compromises allow immediate fee or staking address changes. See `docs/GOV_SPEC.md` for planned governance implementation to address this. 
- `SuperDCAStaking.stake` relies on `gauge.isTokenListed`; if `listing` not set or listing contract compromised, staking eligibility checks may fail-open/closed accordingly.
- Dynamic fee logic trusts external `IMsgSender` implementations; malicious routers could spoof trader identity to obtain 0% fees.
- Concerned with the open permission of `becomeKeeper`; anyone can become a keeper and receive the lowest fee tier.
- Concerned about the ability to list any DCA/TOK pair permissionlessly; worried about exotic tokens potentially causing issues. 
- The gauge contract holding the Keeper deposit and also distributing DCA token rewards; could the rewards be stolen by the keeper or could the keeper deposit be stolen by the gauge contract?

## Appendix
### Glossary
  - **DCA Token:** ERC20 minted as protocol emissions.
  - **Gauge:** Uniswap v4 hook controlling liquidity event reward flows.
  - **Internal Users:** The Super DCA Pool contracts (not included in this repo) that will be allowlisted as internal users, pay 0% fees by default.
  - **Keeper:** Highest-deposit participant receiving reduced swap fees, pays 0.10% by default.
  - **External Users:** Anyone who is not an internal user or keeper (i.e. arbitrage/MEV traders) that uses LPs with this hook, pay 0.50% fee by default.
  - **Listing NFP:** Uniswap v4 NFT proving liquidity commitment for partner token.
  - **Reward Index:** Global accumulator scaling minted rewards per staked token.

### Diagrams
  - [Token listing onboarding](./diagrams/token-listing.md)
  - [Staking and reward distribution](./diagrams/stake-reward-distribution.md)
  - [Keeper rotation and dynamic fee enforcement](./diagrams/keeper-dynamic-fee.md)

### Test matrix
Generated using `scopelint spec`. Last generated 2025-09-21.
```
Contract Specification: SuperDCAListing
├── constructor
│   ├──  Sets Configuration Parameters
│   ├──  Revert When: Invalid Super D C A Token
│   └──  Revert When: Invalid Admin
├── setHookAddress
│   ├──  Sets Hook Address: When Called By Admin
│   └──  Revert When: Set Hook Address Called By Non Admin
├── setMinimumLiquidity
│   ├──  Sets Minimum Liquidity: When Called By Admin
│   └──  Revert When: Set Minimum Liquidity Called By Non Admin
├── list
│   ├──  Emits Token Listed And Registers Token: When: Valid Full Range And Liquidity
│   ├──  Revert When: Incorrect Hook Address
│   ├──  Revert When: Nft Id Is Zero
│   ├──  Revert When: Position Is Not Full Range
│   ├──  Revert When: Partial Range: Lower Wrong
│   ├──  Revert When: Partial Range: Upper Wrong
│   ├──  Revert When: Liquidity Below Minimum
│   ├──  Revert When: Token Already Listed
│   ├──  Revert When: Mismatched Pool Key Provided
│   ├──  Registers Token And Transfers Nfp: When: Dca Token Is Currency0
│   └──  Registers Token And Transfers Nfp: When: Dca Token Is Currency1
├── _getAmountsForKey
└── collectFees
    ├──  Collect Fees: Increases Recipient Balances: When: Called By Admin
    ├──  Emits Fees Collected: When: Called By Admin
    ├──  Revert When: Collect Fees Called By Non Admin
    ├──  Revert When: Collect Fees With Zero Nfp Id
    └──  Revert When: Collect Fees With Zero Recipient

Contract Specification: SuperDCAToken
├── constructor
│   └──  Sets Name Symbol And Owner And Initial Supply
└── mint
    ├──  Mints When Called By Owner
    └──  Revert If: Caller Is Not Owner

Contract Specification: SuperDCAStaking
├── onlyGauge
├── constructor
│   ├──  Sets Configuration Parameters
│   ├──  Revert If: Super Dca Token Is Zero
│   └──  Sets Arbitrary Values
├── setGauge
│   ├──  Sets Gauge When Called By Owner
│   ├──  Revert If: Zero Address
│   └──  Revert If: Caller Is Not Owner
├── setMintRate
│   ├──  Updates Mint Rate When Called By Owner
│   ├──  Updates Mint Rate When Called By Gauge
│   └──  Revert If: Caller Is Not Owner Or Gauge
├── _updateRewardIndex
├── stake
│   ├──  Updates State
│   ├──  Emits Staked Event
│   └──  Revert If: Zero Amount Stake
├── unstake
│   ├──  Updates State
│   ├──  Emits Unstaked Event
│   ├──  Revert If: Zero Amount Unstake
│   ├──  Revert If: Unstake Exceeds Token Bucket
│   └──  Revert If: Unstake Exceeds User Stake
├── accrueReward
│   ├──  Computes Accrued And Updates Index
│   ├──  Emits Reward Index Updated On Accrual
│   └──  Revert If: Caller Is Not Gauge
├── previewPending
│   ├──  Computes Pending
│   ├──  Returns Zero When: No Stake
│   └──  Returns Zero When: No Time Elapsed
├── getUserStake
│   ├──  Returns Amount After Stake
│   └──  Returns Zero When: No Stake
├── getUserStakedTokens
│   ├──  Returns Tokens After Stake
│   └──  Returns Empty When: No Stake
└── tokenRewardInfos
    ├──  Returns Zero Struct Initially
    └──  Returns Updated Struct After Stake

Contract Specification: SuperDCAGauge
├── constructor
├── setStaking
├── setListing
├── isTokenListed
├── getHookPermissions
├── _beforeInitialize
├── _afterInitialize
├── _handleDistributionAndSettlement
├── _beforeAddLiquidity
├── _beforeRemoveLiquidity
├── _beforeSwap
├── becomeKeeper
├── getKeeperInfo
├── updateManager
├── setFee
├── setInternalAddress
├── returnSuperDCATokenOwnership
└── _tryMint
```
