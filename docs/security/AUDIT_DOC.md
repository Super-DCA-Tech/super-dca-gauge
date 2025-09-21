## 1. Summary (What, Who, How)
- **What the system does:** Super DCA Gauge is a Uniswap v4 hook plus companion staking and listing modules that mint and route newly issued DCA tokens to eligible pools and the developer treasury during liquidity events while enforcing token listing, staking accounting, and dynamic swap fees.
- **Who uses it:** Liquidity providers (LPs), DCA stakers, keeper candidates, swap traders, protocol developer/treasury admins, and listing operators.
- **How at a high level:** A listing contract holds full-range Uniswap v4 positions to whitelist partner tokens. Stakers deposit DCA into per-token buckets tracked by `SuperDCAStaking`. When LPs modify liquidity, the `SuperDCAGauge` hook accrues staking rewards, mints DCA via the token owner privilege, donates community rewards to the pool, and transfers the developer share. The hook also enforces dynamic swap fees (internal, keeper, external) and owns keeper deposits. Access is mediated via `AccessControl` (gauge) and `Ownable2Step` (staking/listing).
- **Audit scope freeze:** Repository `super-dca-gauge` at commit `908dd2204e9edd6ab430f3683084145a8d73e039`, tagged `audit-freeze-20250921` on the `main` branch.

## 2. Architecture Overview
- **Module map:**

Contract | Responsibility | Key external funcs | Critical invariants
-- | -- | -- | --
`SuperDCAGauge` | Uniswap v4 hook distributing rewards, enforcing pool eligibility, dynamic fees, keeper deposits, and admin fee controls. | `setStaking`, `setListing`, `becomeKeeper`, `setFee`, `setInternalAddress`, `returnSuperDCATokenOwnership`, hook callbacks. | Only pools containing DCA and dynamic fee flag initialize; reward accrual cannot revert; donation splits stay 50/50 when mint succeeds; fee overrides respect role checks.【F:src/SuperDCAGauge.sol†L47-L362】【F:test/SuperDCAGauge.t.sol†L311-L433】【F:test/SuperDCAGauge.t.sol†L824-L1018】
`SuperDCAStaking` | Tracks per-token staking buckets and global reward index used by the gauge. | `stake`, `unstake`, `accrueReward`, `setGauge`, `setMintRate`. | Reward index monotonic; staking totals updated atomically; only configured gauge can accrue rewards.【F:src/SuperDCAStaking.sol†L12-L184】【F:test/SuperDCAStaking.t.sol†L19-L132】
`SuperDCAListing` | Custodies full-range Uniswap v4 NFT positions, validates hook usage, and marks partner tokens listed. | `list`, `setMinimumLiquidity`, `setHookAddress`, `collectFees`. | Listed token must pair with DCA, use expected hook, and meet liquidity threshold; duplicates prevented.【F:src/SuperDCAListing.sol†L20-L184】【F:test/SuperDCAListing.t.sol†L84-L205】【F:test/SuperDCAListing.t.sol†L274-L356】
`SuperDCAToken` | Minimal ERC20 + permit minted by owner (gauge during operations). | `mint`. | Ownership restricted to one account; decimals=18.【F:src/SuperDCAToken.sol†L1-L22】

- **Entry points:**
  - Gauge hook callbacks: `_beforeInitialize`, `_afterInitialize`, `_beforeAddLiquidity`, `_beforeRemoveLiquidity`, `_beforeSwap` drive reward eligibility, dynamic fees, and minting.【F:src/SuperDCAGauge.sol†L134-L259】【F:src/SuperDCAGauge.sol†L292-L362】
  - Gauge admin: `setStaking`, `setListing`, `updateManager`, `setFee`, `setInternalAddress`, `returnSuperDCATokenOwnership`, `becomeKeeper`, `getKeeperInfo`.【F:src/SuperDCAGauge.sol†L80-L132】【F:src/SuperDCAGauge.sol†L312-L362】
  - Staking user actions: `stake`, `unstake`; gauge integration: `accrueReward`; admin: `setGauge`, `setMintRate`.【F:src/SuperDCAStaking.sol†L63-L165】
  - Listing ops: `list`, `setMinimumLiquidity`, `setHookAddress`, `collectFees`.【F:src/SuperDCAListing.sol†L72-L183】【F:src/SuperDCAListing.sol†L200-L242】

- **Data flows (high level):**
  1. Listing owner deposits full-range NFP → Listing contract marks partner token eligible for staking/gauge donations.【F:src/SuperDCAListing.sol†L96-L182】
  2. Staker transfers DCA → Staking contract updates bucket share and global reward index.【F:src/SuperDCAStaking.sol†L90-L141】
  3. LP modifies liquidity → PoolManager triggers gauge hook → gauge accrues reward from staking and mints DCA split between pool donation and developer.【F:src/SuperDCAGauge.sol†L187-L259】
  4. Keeper candidate deposits DCA via `becomeKeeper` → gauge enforces higher deposit and refunds prior keeper, then applies keeper fee tier on swaps.【F:src/SuperDCAGauge.sol†L264-L312】
  5. Admin updates parameters (mintRate, fees, minLiquidity) under role controls, impacting staking growth and swap pricing.【F:src/SuperDCAStaking.sol†L72-L83】【F:src/SuperDCAGauge.sol†L320-L347】【F:src/SuperDCAListing.sol†L120-L151】

## 3. Actors, Roles & Privileges
- **Roles:**

Role | Capabilities
-- | --
Default admin (developer multisig) | Holds `DEFAULT_ADMIN_ROLE` on gauge, can set staking/listing modules, rotate managers, reclaim token ownership, pause integrations off-chain via config changes.【F:src/SuperDCAGauge.sol†L71-L112】
Gauge manager | Accounts with `MANAGER_ROLE` on gauge can adjust dynamic fees and mark internal addresses.【F:src/SuperDCAGauge.sol†L320-L347】
Listing owner | `Ownable2Step` owner can set expected hook, min liquidity, and collect fees for listed positions.【F:src/SuperDCAListing.sol†L58-L151】【F:src/SuperDCAListing.sol†L200-L242】
Staking owner | `Ownable2Step` owner can set authorized gauge and adjust mint rate; gauge can also change mint rate.【F:src/SuperDCAStaking.sol†L24-L83】
Keeper | Highest-deposit account receiving reduced swap fee tier; deposit held by gauge until replaced.【F:src/SuperDCAGauge.sol†L264-L312】
Liquidity provider | Adds/removes liquidity, triggering donations and reward minting via hook.【F:src/SuperDCAGauge.sol†L187-L259】
Staker | Deposits DCA into staking buckets to earn proportional rewards.【F:src/SuperDCAStaking.sol†L90-L141】
Trader | Swaps through pools; actual msg.sender determined via `IMsgSender` for fee tiering.【F:src/SuperDCAGauge.sol†L292-L311】

- **Access control design:**
  - Gauge uses OpenZeppelin `AccessControl` with `DEFAULT_ADMIN_ROLE` and `MANAGER_ROLE`. Only the staking contract address set by admin can be called for reward accrual. Keeper deposits are open, but fee edits and internal address management require manager role.【F:src/SuperDCAGauge.sol†L57-L112】【F:src/SuperDCAGauge.sol†L187-L347】
  - Staking and listing rely on `Ownable2Step`; owner must call `acceptOwnership`. Only owner (and gauge for mintRate) may update parameters.【F:src/SuperDCAStaking.sol†L24-L83】【F:src/SuperDCAListing.sol†L50-L151】
  - Token ownership typically resides with gauge so it can mint; admin can reclaim via `returnSuperDCATokenOwnership`.【F:src/SuperDCAGauge.sol†L334-L347】

- **Emergency controls:**
  - No explicit pause. Mitigations rely on revoking staking/listing addresses, resetting mintRate to zero, or reclaiming token ownership to halt minting. Keeper deposits can be reclaimed by surpassing deposit threshold. No timelocks present, so admin actions execute immediately.【F:src/SuperDCAGauge.sol†L80-L132】【F:src/SuperDCAStaking.sol†L72-L101】

## 4. User Flows (Primary Workflows)
### Flow 1: Token listing onboarding
- **User story:** As the listing owner, I custody full-range Uniswap v4 positions so that a partner asset becomes eligible for gauge rewards.
- **Preconditions:** Listing contract deployed with expected hook address; owner holds full-range NFP minted with Super DCA token on one side and meets `minLiquidity`; approvals granted for NFT transfer.
- **Happy path steps:**
  1. Owner mints or acquires full-range NFP from Uniswap PositionManager.
  2. Owner calls `list(nftId, poolKey)` on `SuperDCAListing`.
  3. Contract pulls actual pool metadata, checks hook equals configured gauge, validates full-range ticks and minimum DCA liquidity.
  4. Contract marks partner token as listed, records NFP → token mapping, and transfers NFT custody to itself.
- **Alternates / edge cases:** Reverts if hook mismatch, liquidity below threshold, token already listed, or pool key mismatched; zero `nftId` or zero addresses revert; only owner can adjust hook/min liquidity. No automatic delisting; manual governance required.【F:src/SuperDCAListing.sol†L96-L182】
- **On-chain ↔ off-chain interactions:** Off-chain process to prepare NFP; all validations on-chain using Uniswap managers.
- **Linked diagram:** `./diagrams/token-listing.md`
- **Linked tests:** `test_EmitsTokenListedAndRegistersToken_When_ValidFullRangeAndLiquidity` and associated revert cases in `test/SuperDCAListing.t.sol` cover happy path and failure modes.【F:test/SuperDCAListing.t.sol†L313-L356】【F:test/SuperDCAListing.t.sol†L357-L451】

### Flow 2: Staking and reward distribution on liquidity events
- **User story:** As a DCA staker, I deposit tokens into the staking contract so that when LPs interact with pools the gauge mints proportional rewards for the pool and developer.
- **Preconditions:** Gauge configured as staking contract’s authorized caller; staking token approvals granted; target token is listed; pool initialized with gauge hook; gauge owns mint rights on DCA token.
- **Happy path steps:**
  1. Staker approves and calls `stake(listedToken, amount)` on `SuperDCAStaking`, which updates totals and global reward index.
  2. LP adds or removes liquidity on the pool; PoolManager calls gauge’s hook.
  3. Gauge syncs DCA balance, calls `accrueReward(listedToken)`; staking updates reward index and returns owed amount.
  4. Gauge mints DCA (splitting 50/50) via `_tryMint`; community share is donated to the pool (if liquidity > 0) and developer share transferred.
  5. PoolManager settles donation; rewards accounted in staking via updated indexes.
- **Alternates / edge cases:** If pool has zero liquidity, all rewards go to developer; if mint fails, function continues without reverting and timestamp advances; if staking contract unset or token not listed, staking/ accrual reverts; paused or removed staking can halt accrual by setting mintRate=0 or revoking gauge authority.【F:src/SuperDCAGauge.sol†L187-L259】【F:src/SuperDCAStaking.sol†L90-L165】
- **On-chain ↔ off-chain interactions:** Entire flow on-chain; developer wallet receives transfer; donation accrues as pool fees.
- **Linked diagram:** `./diagrams/stake-reward-distribution.md`
- **Linked tests:** `test_distribution_on_addLiquidity`, `test_distribution_on_removeLiquidity`, and mint failure scenarios in `test/SuperDCAGauge.t.sol`; staking state updates validated in `testFuzz_UpdatesState` suites.【F:test/SuperDCAGauge.t.sol†L333-L413】【F:test/SuperDCAGauge.t.sol†L433-L520】【F:test/SuperDCAGauge.t.sol†L520-L605】【F:test/SuperDCAStaking.t.sol†L94-L153】

### Flow 3: Keeper rotation and dynamic fee enforcement
- **User story:** As a keeper candidate, I post a higher DCA deposit to gain the keeper fee tier so that my swaps incur reduced fees while other users pay external fees.
- **Preconditions:** Gauge deployed with DCA ownership and manager-set fees; candidate holds DCA tokens and approval for gauge; optional internal address list managed by managers.
- **Happy path steps:**
  1. Candidate approves DCA and calls `becomeKeeper(amount)`; gauge ensures `amount > keeperDeposit`, transfers deposit in, and refunds prior keeper if present.
  2. Gauge updates `keeper` and `keeperDeposit` state and emits `KeeperChanged`.
  3. When swaps occur, hook queries `IMsgSender(sender).msgSender()`; if address is marked internal, 0% fee; else if matches keeper, apply `keeperFee`; otherwise apply `externalFee` with override flag.
- **Alternates / edge cases:** Calls revert on zero amount or insufficient deposit; same keeper can increase deposit; manager role can retune fees or mark addresses; losing keeper obtains refund automatically; swapper classification depends on proxy contract implementing `IMsgSender`.
- **On-chain ↔ off-chain interactions:** Keeper deposit handled on-chain; off-chain monitoring needed to top up deposit or detect replacements.
- **Linked diagram:** `./diagrams/keeper-dynamic-fee.md`
- **Linked tests:** Keeper deposit, refund, and fee configuration verified in `BecomeKeeperTest` suite and manager access tests in `test/SuperDCAGauge.t.sol`; internal address role tests under `SetInternalAddressTest` validate privileged fee classification.【F:test/SuperDCAGauge.t.sol†L824-L1018】【F:test/SuperDCAGauge.t.sol†L1043-L1108】

## 5. State, Invariants & Properties
- **State variables that matter:**
  - Gauge: `keeper`, `keeperDeposit`, `internalFee`, `externalFee`, `keeperFee`, `isInternalAddress`, references to staking/listing modules.【F:src/SuperDCAGauge.sol†L59-L132】
  - Staking: `mintRate`, `rewardIndex`, `lastMinted`, `totalStakedAmount`, per-token `TokenRewardInfo` (staked amount, last index).【F:src/SuperDCAStaking.sol†L24-L72】
  - Listing: `minLiquidity`, `expectedHooks`, `isTokenListed`, `tokenOfNfp`.【F:src/SuperDCAListing.sol†L44-L93】

- **Invariants (must always hold):**

Invariant | Description | Enforcement / Tests
-- | -- | --
Pool eligibility | Only pools with Super DCA token and dynamic fee flag may initialize the hook. | `_beforeInitialize` / `_afterInitialize`; `test_beforeInitialize_revert_wrongToken`, `test_RevertWhen_InitializingWithStaticFee`.【F:src/SuperDCAGauge.sol†L134-L183】【F:test/SuperDCAGauge.t.sol†L216-L244】
Accrual monotonicity | `rewardIndex` increases with elapsed time when stake > 0; totals update on stake/unstake. | `_updateRewardIndex`; `testFuzz_UpdatesState`, `test_reward_calculation`.【F:src/SuperDCAStaking.sol†L102-L165】【F:test/SuperDCAStaking.t.sol†L94-L153】【F:test/SuperDCAGauge.t.sol†L467-L520】
Authorization | Only owner/manager/gauge may mutate sensitive parameters; unauthorized calls revert. | `AccessControl` & `Ownable2Step`; `test_RevertWhen_NonManagerSetsInternalFee/ExternalFee/KeeperFee`; `testFuzz_RevertIf_CallerIsNotOwnerOrGauge`.【F:src/SuperDCAGauge.sol†L71-L347】【F:src/SuperDCAStaking.sol†L63-L101】【F:test/SuperDCAGauge.t.sol†L1043-L1108】【F:test/SuperDCAStaking.t.sol†L64-L132】
Reward split | When donation occurs, minted rewards split 50/50 between developer and pool (±1 wei rounding). | `_handleDistributionAndSettlement`; `test_distribution_on_addLiquidity`, `test_distribution_on_removeLiquidity`.【F:src/SuperDCAGauge.sol†L187-L259】【F:test/SuperDCAGauge.t.sol†L333-L413】
Keeper supremacy | New keeper must deposit strictly more DCA; previous deposit refunded. | `becomeKeeper`; `test_becomeKeeper_replaceKeeper`, `test_becomeKeeper_revert_insufficientDeposit`.【F:src/SuperDCAGauge.sol†L264-L312】【F:test/SuperDCAGauge.t.sol†L852-L906】
Mint failure tolerance | Reward accrual proceeds even if token minting fails. | `_tryMint`; `test_whenMintFails_onAddLiquidity`, `test_whenMintFails_onRemoveLiquidity`.【F:src/SuperDCAGauge.sol†L349-L362】【F:test/SuperDCAGauge.t.sol†L413-L520】

- **Property checks / assertions:** Unit tests include fuzzing for staking stake/unstake operations and revert assertions for role checks. No dedicated invariant tests beyond test suites above.

## 6. Economic & External Assumptions
- **Token assumptions:** DCA token is 18 decimals, non-rebasing, no fee-on-transfer; staking requires direct `transferFrom`, so fee-on-transfer partners incompatible without adapters.【F:src/SuperDCAToken.sol†L9-L22】【F:src/SuperDCAStaking.sol†L111-L150】
- **Oracle assumptions:** None; system does not consume price feeds.
- **Liquidity/MEV/DoS assumptions:**
  - LP-triggered rewards rely on sufficient keeper/LP activity; long idle periods delay minting but accrue in index.
  - Donations require pool liquidity; empty pools route rewards entirely to developer, which may be contentious.
  - `beforeSwap` executes every swap; gas overhead increases with dynamic fee logic and external `IMsgSender` call, assuming router implements interface.
  - Keeper deposit race conditions assume honest refunds; no timelock on replacements.

## 7. Upgradeability & Initialization
- **Pattern:** All contracts are non-upgradeable, deployed as regular Solidity contracts with constructor-set immutables. Ownership can be transferred manually.
- **Initialization path:**
  - Gauge constructor sets DCA token, developer admin, default fees, and grants roles; admin later calls `setStaking`/`setListing`.【F:src/SuperDCAGauge.sol†L71-L132】
  - Staking constructor fixes token, mint rate, owner; owner sets gauge address post-deploy.【F:src/SuperDCAStaking.sol†L51-L83】
  - Listing constructor wires Uniswap managers, expected hook; owner can update hook later. Pool-level initialization occurs via Uniswap `initialize` using hook flags.【F:src/SuperDCAListing.sol†L50-L120】
- **Migration & upgrade safety checks:** Manual process—revoke gauge role or transfer token ownership before deploying replacements; ensure new contracts respect same interfaces before switching addresses.

## 8. Parameters & Admin Procedures
- **Config surface:**

Parameter | Contract | Units / Range | Default | Who can change | Notes
-- | -- | -- | -- | -- | --
`mintRate` | Staking | DCA per second; expect ≤ token emission cap | Constructor arg | Owner or gauge | Setting to 0 halts new emissions.【F:src/SuperDCAStaking.sol†L51-L83】
`staking` address | Gauge | Contract address | unset | Gauge admin | Must be set before liquidity events or accrual reverts.【F:src/SuperDCAGauge.sol†L80-L92】
`listing` address | Gauge | Contract address | unset | Gauge admin | If unset, `isTokenListed` returns false, blocking staking.【F:src/SuperDCAGauge.sol†L94-L112】
`internalFee` | Gauge | Uniswap fee (ppm) | 0 | Manager role | Applied to allowlisted traders.【F:src/SuperDCAGauge.sol†L318-L347】
`externalFee` | Gauge | ppm | 5000 (0.50%) | Manager role | Default fallback fee.【F:src/SuperDCAGauge.sol†L318-L347】
`keeperFee` | Gauge | ppm | 1000 (0.10%) | Manager role | Used when swapper == keeper.【F:src/SuperDCAGauge.sol†L318-L347】
`isInternalAddress` | Gauge | bool map | false | Manager role | Grants 0% fee tier.【F:src/SuperDCAGauge.sol†L334-L343】
`expectedHooks` | Listing | address | constructor | Listing owner | Must match gauge hook flags.【F:src/SuperDCAListing.sol†L58-L120】
`minLiquidity` | Listing | DCA wei | 1000e18 | Listing owner | Adjust to control listing quality.【F:src/SuperDCAListing.sol†L120-L151】

- **Runbooks:**
  - **Pause emissions:** Owner sets staking `mintRate=0` or removes gauge rights; optionally transfer token ownership away from gauge.
  - **Rotate manager:** Admin calls `updateManager(old,new)` on gauge; ensure new manager accepts responsibilities.【F:src/SuperDCAGauge.sol†L312-L320】
  - **Keeper replacement:** Encourage trusted actor to call `becomeKeeper` with higher deposit; previous deposit auto-refunded.【F:src/SuperDCAGauge.sol†L264-L312】
  - **Recover token ownership:** Admin calls `returnSuperDCATokenOwnership` to move ERC20 owner from gauge to admin wallet.【F:src/SuperDCAGauge.sol†L334-L347】

## 9. External Integrations
- **Addresses / versions:**
  - Uses local copies of Uniswap v4 core (`lib/v4-core`) and periphery (`lib/v4-periphery`) contracts for hooks, routers, and `IPositionManager`.【F:src/SuperDCAGauge.sol†L4-L23】【F:src/SuperDCAListing.sol†L9-L38】
  - OpenZeppelin v5 libraries for ERC20, AccessControl, Ownable2Step; Permit2 interface for testing mocks.【F:src/SuperDCAToken.sol†L4-L21】【F:src/SuperDCAGauge.sol†L11-L23】【F:src/SuperDCAListing.sol†L4-L22】
  - README documents live deployments: Base `SuperDCAGauge` 0xBc5F..., Optimism 0xb4f4..., Super DCA token 0xb159..., Base Sepolia test deployment 0x7418....【F:README.md†L94-L107】

- **Failure assumptions & mitigations:**
  - **Uniswap PositionManager / PoolManager**: assumed honest; listing relies on returned pool data. Compromise could bypass listing checks.
  - **SuperDCAToken**: gauge must remain owner to mint; if ownership transferred inadvertently, reward minting fails but hooks continue without revert (developer share lost). Tests cover tolerance but system enters degraded mode until ownership restored.【F:src/SuperDCAGauge.sol†L334-L347】【F:test/SuperDCAGauge.t.sol†L388-L520】
  - **Permit2 / IMsgSender**: For dynamic fees to work behind routers, router must implement `IMsgSender`. Absent that, swapper may misclassify and pay external fee.【F:src/SuperDCAGauge.sol†L292-L311】

## 10. Build, Test & Reproduction
- **Environment prerequisites:** Unix-like OS, Git, curl, Foundry toolchain (`forge`, `cast`, `anvil`) ≥ 1.0.0; Solidity compiler pinned to 0.8.26; Node optional for scripts; Python optional for utilities.
- **Clean-machine setup:**
  ```bash
  # 1) Install Foundry
  curl -L https://foundry.paradigm.xyz | bash
  source "$HOME/.foundry/bin/foundryup"  # or run foundryup after installation
  foundryup --version

  # 2) Clone repository
  git clone https://github.com/Super-DCA-Tech/super-dca-gauge.git
  cd super-dca-gauge
  git checkout 908dd2204e9edd6ab430f3683084145a8d73e039
  git tag -l 'audit-freeze-20250921'

  # 3) (Optional) copy environment file for RPC endpoints
  cp .env.example .env  # populate BASE_RPC_URL etc. when running scripts
  ```
- **Build:**
  ```bash
  forge build
  ```
- **Tests:**
  ```bash
  # Full suite
  forge test -vv

  # Single test example
  forge test --match-test test_distribution_on_addLiquidity -vv
  ```
- **Coverage / fuzzing:** No dedicated coverage artifacts committed; fuzz tests embedded in staking suite. To run coverage locally: `forge coverage --report lcov` (requires Foundry nightly).

## 11. Known Issues & Areas of Concern
- Donation accounting in tests is marked TODO; pool donation success is not fully asserted, so auditors should validate via integration or simulation.【F:test/SuperDCAGauge.t.sol†L359-L377】【F:test/SuperDCAGauge.t.sol†L455-L475】
- Gauge lacks explicit pause or timelock; admin compromises allow immediate fee or staking address changes.
- `SuperDCAStaking.stake` relies on `gauge.isTokenListed`; if `listing` not set or listing contract compromised, staking eligibility checks may fail-open/closed accordingly.【F:src/SuperDCAStaking.sol†L111-L125】【F:src/SuperDCAGauge.sol†L94-L132】
- Dynamic fee logic trusts external `IMsgSender` implementations; malicious routers could spoof trader identity to obtain 0% fees.【F:src/SuperDCAGauge.sol†L292-L311】

## 13. Appendix
- **Glossary:**
  - **DCA Token:** ERC20 minted as protocol emissions.
  - **Gauge:** Uniswap v4 hook controlling liquidity event reward flows.
  - **Keeper:** Highest-deposit participant receiving reduced swap fees.
  - **Listing NFP:** Uniswap v4 NFT proving liquidity commitment for partner token.
  - **Reward Index:** Global accumulator scaling minted rewards per staked token.

- **Diagrams:**
  - [Token listing onboarding](./diagrams/token-listing.md)
  - [Staking and reward distribution](./diagrams/stake-reward-distribution.md)
  - [Keeper rotation and dynamic fee enforcement](./diagrams/keeper-dynamic-fee.md)

- **Test matrix:** See `./test-matrix.csv` for mapping between flows, invariants, and tests.
