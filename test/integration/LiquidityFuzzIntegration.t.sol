// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {OptimismIntegrationBase} from "./OptimismIntegrationBase.t.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "lib/v4-periphery/src/libraries/Actions.sol";
import {Planner, Plan} from "lib/v4-periphery/test/shared/Planner.sol";

/// @notice Fuzz tests to reproduce issues with how sync/settle 
/// are called in "_handleDistributionAndSettlement" in SuperDCAGauge.sol
// 
/// @dev Test failures for known issues
/// Both these tests fail with issue "DeltaNotNegative(address currency)"
///
/// test_fuzz_addRemoveLiquidityWithRewards
/// test_fuzz_rapidAddRemoveWithLongDelays
///
/// Run them as:
/// forge test --match-test test_fuzz_addRemoveLiquidityWithRewards -vvv
/// forge test --match-test test_fuzz_rapidAddRemoveWithLongDelays -vvv

contract LiquidityFuzzIntegration is OptimismIntegrationBase {
    PoolKey public testKey;
    PoolId public testPoolId;
    address public listedToken;

    address public lp1;
    address public lp2;
    address public lp3;

    uint256[] public lpNftIds;

    uint256 constant MIN_TIME_DELAY = 12 hours;
    uint256 constant MAX_TIME_DELAY = 7 days;
    uint256 constant MIN_CYCLES = 3;
    uint256 constant MAX_CYCLES = 10;

    function setUp() public override {
        super.setUp();

        listedToken = WETH;

        lp1 = makeAddr("lp1");
        lp2 = makeAddr("lp2");
        lp3 = makeAddr("lp3");

        _setupTestPool();
        _setupLiquidityProviders();
    }

    function _setupTestPool() internal {
        uint160 sqrtPriceX96 = _getCurrentPrice();
        (testKey, testPoolId) = _createTestPool(listedToken, int24(60), sqrtPriceX96);

        uint256 initialNftId = _createFullRangePosition(testKey, POSITION_AMOUNT0, POSITION_AMOUNT1, address(this));

        IERC721(POSITION_MANAGER_V4).approve(address(listing), initialNftId);
        listing.list(initialNftId, testKey);

        deal(DCA_TOKEN, address(this), STAKE_AMOUNT);
        IERC20(DCA_TOKEN).approve(address(staking), STAKE_AMOUNT);
        staking.stake(listedToken, STAKE_AMOUNT);
    }

    function _setupLiquidityProviders() internal {
        deal(DCA_TOKEN, lp1, 100000e18);
        deal(DCA_TOKEN, lp2, 100000e18);
        deal(DCA_TOKEN, lp3, 100000e18);
        deal(listedToken, lp1, 10000e18);
        deal(listedToken, lp2, 10000e18);
        deal(listedToken, lp3, 10000e18);

        uint256 nftId1 = _createFullRangePosition(testKey, POSITION_AMOUNT0, POSITION_AMOUNT1, lp1);
        uint256 nftId2 = _createFullRangePosition(testKey, POSITION_AMOUNT0, POSITION_AMOUNT1, lp2);
        uint256 nftId3 = _createFullRangePosition(testKey, POSITION_AMOUNT0, POSITION_AMOUNT1, lp3);

        lpNftIds.push(nftId1);
        lpNftIds.push(nftId2);
        lpNftIds.push(nftId3);
    }

    function test_fuzz_addRemoveLiquidityWithRewards(uint256 numCycles, uint256 seed) public {
        numCycles = bound(numCycles, MIN_CYCLES, MAX_CYCLES);

        for (uint256 i = 0; i < numCycles; i++) {
            uint256 timeDelay = _boundTimeDelay(_deterministicRandom(seed, i * 2));
            _simulateTimePass(timeDelay);

            uint256 lpIndex = i % 3;
            address currentLP = _getLPAddress(lpIndex);
            uint256 nftId = lpNftIds[lpIndex];

            uint256 addAmount0 = _boundLiquidityAmount(_deterministicRandom(seed, i * 2 + 1));
            uint256 addAmount1 = addAmount0 * 1000;

            _addLiquidityForLP(currentLP, nftId, addAmount0, addAmount1);

            uint256 removeTimeDelay = _boundTimeDelay(_deterministicRandom(seed, i * 2 + 1000));
            _simulateTimePass(removeTimeDelay);

            _removeLiquidityForLP(currentLP, nftId);
        }
    }

    function test_fuzz_multipleLPsSimultaneousOperations(uint256 seed) public {
        uint256 numRounds = bound(_deterministicRandom(seed, 0), MIN_CYCLES, MAX_CYCLES);

        for (uint256 round = 0; round < numRounds; round++) {
            uint256 timeDelay = _boundTimeDelay(_deterministicRandom(seed, round));
            _simulateTimePass(timeDelay);

            for (uint256 lpIndex = 0; lpIndex < 3; lpIndex++) {
                address currentLP = _getLPAddress(lpIndex);
                uint256 nftId = lpNftIds[lpIndex];

                uint256 addAmount0 = _boundLiquidityAmount(_deterministicRandom(seed, round * 10 + lpIndex));
                uint256 addAmount1 = addAmount0 * 1000;

                _addLiquidityForLP(currentLP, nftId, addAmount0, addAmount1);
            }

            uint256 removeTimeDelay = _boundTimeDelay(_deterministicRandom(seed, round + 5000));
            _simulateTimePass(removeTimeDelay);

            for (uint256 lpIndex = 0; lpIndex < 3; lpIndex++) {
                address currentLP = _getLPAddress(lpIndex);
                uint256 nftId = lpNftIds[lpIndex];

                _removeLiquidityForLP(currentLP, nftId);
            }
        }
    }

    function test_fuzz_extremeTimeDelays(uint256 firstDelay, uint256 secondDelay, uint256 thirdDelay) public {
        firstDelay = bound(firstDelay, MIN_TIME_DELAY, 30 days);
        secondDelay = bound(secondDelay, MIN_TIME_DELAY, 30 days);
        thirdDelay = bound(thirdDelay, MIN_TIME_DELAY, 30 days);

        _simulateTimePass(firstDelay);
        uint256 addAmount0 = 5e18;
        uint256 addAmount1 = 5000e18;
        _addLiquidityForLP(lp1, lpNftIds[0], addAmount0, addAmount1);

        _simulateTimePass(secondDelay);
        _addLiquidityForLP(lp2, lpNftIds[1], addAmount0, addAmount1);

        _simulateTimePass(thirdDelay);
        _addLiquidityForLP(lp3, lpNftIds[2], addAmount0, addAmount1);

        _simulateTimePass(firstDelay);
        _removeLiquidityForLP(lp1, lpNftIds[0]);

        _simulateTimePass(secondDelay);
        _removeLiquidityForLP(lp2, lpNftIds[1]);

        _simulateTimePass(thirdDelay);
        _removeLiquidityForLP(lp3, lpNftIds[2]);
    }

    function test_fuzz_rapidAddRemoveWithLongDelays(uint256 longDelay, uint256 numOperations, uint256 seed) public {
        longDelay = bound(longDelay, 24 hours, 14 days);
        numOperations = bound(numOperations, 5, 15);

        for (uint256 i = 0; i < numOperations; i++) {
            _simulateTimePass(longDelay);

            uint256 lpIndex = i % 3;
            address currentLP = _getLPAddress(lpIndex);
            uint256 nftId = lpNftIds[lpIndex];

            uint256 amount0 = _boundLiquidityAmount(_deterministicRandom(seed, i));
            uint256 amount1 = amount0 * 1000;

            _addLiquidityForLP(currentLP, nftId, amount0, amount1);

            uint256 shortDelay = bound(_deterministicRandom(seed, i + 1000), 1 hours, 6 hours);
            _simulateTimePass(shortDelay);

            _removeLiquidityForLP(currentLP, nftId);
        }
    }

    function _addLiquidityForLP(address lp, uint256 nftId, uint256 amount0, uint256 amount1) internal {
        deal(Currency.unwrap(testKey.currency0), lp, amount0);
        deal(Currency.unwrap(testKey.currency1), lp, amount1);

        vm.startPrank(lp);

        IERC20(Currency.unwrap(testKey.currency0)).approve(PERMIT2, type(uint256).max);
        IERC20(Currency.unwrap(testKey.currency1)).approve(PERMIT2, type(uint256).max);

        IAllowanceTransfer(PERMIT2).approve(
            Currency.unwrap(testKey.currency0), POSITION_MANAGER_V4, type(uint160).max, type(uint48).max
        );
        IAllowanceTransfer(PERMIT2).approve(
            Currency.unwrap(testKey.currency1), POSITION_MANAGER_V4, type(uint160).max, type(uint48).max
        );

        PositionParams memory params = _calculatePositionParams(testKey, amount0, amount1);

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.INCREASE_LIQUIDITY,
            abi.encode(nftId, params.liquidity, amount0, amount1, bytes(""))
        );
        plan = plan.add(Actions.SETTLE_PAIR, abi.encode(testKey.currency0, testKey.currency1));

        bytes memory data = plan.encode();
        uint256 deadline = block.timestamp + 60;

        IPositionManager(POSITION_MANAGER_V4).modifyLiquidities(data, deadline);

        vm.stopPrank();
    }

    function _removeLiquidityForLP(address lp, uint256 nftId) internal {
        vm.startPrank(lp);

        uint128 positionLiquidity = IPositionManager(POSITION_MANAGER_V4).getPositionLiquidity(nftId);

        if (positionLiquidity == 0) {
            vm.stopPrank();
            return;
        }

        uint128 liquidityToRemove = positionLiquidity / 2;

        if (liquidityToRemove == 0) {
            vm.stopPrank();
            return;
        }

        Plan memory plan = Planner.init();
        plan = plan.add(
            Actions.DECREASE_LIQUIDITY,
            abi.encode(nftId, liquidityToRemove, 0, 0, bytes(""))
        );
        plan = plan.add(Actions.TAKE_PAIR, abi.encode(testKey.currency0, testKey.currency1, lp));

        bytes memory data = plan.encode();
        uint256 deadline = block.timestamp + 60;

        IPositionManager(POSITION_MANAGER_V4).modifyLiquidities(data, deadline);

        vm.stopPrank();
    }

    function _getLPAddress(uint256 index) internal view returns (address) {
        if (index == 0) return lp1;
        if (index == 1) return lp2;
        return lp3;
    }

    function _boundTimeDelay(uint256 value) internal pure returns (uint256) {
        return bound(value, MIN_TIME_DELAY, MAX_TIME_DELAY);
    }

    function _boundLiquidityAmount(uint256 value) internal pure returns (uint256) {
        return bound(value, 1e18, 10e18);
    }

    function _deterministicRandom(uint256 seed, uint256 nonce) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(seed, nonce)));
    }
}

