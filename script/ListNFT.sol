// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {SuperDCAListing} from "../src/SuperDCAListing.sol";
import {SuperDCAGauge} from "../src/SuperDCAGauge.sol";
import {SuperDCAStaking} from "../src/SuperDCAStaking.sol";
import {IPositionManager} from "lib/v4-periphery/src/interfaces/IPositionManager.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {console2} from "forge-std/Test.sol";

contract ListNFT is Script {
    uint256 constant STAKE_AMOUNT = 10e18; // 10 DCA tokens
    uint256 deployerPrivateKey;
    address listingAddress;
    uint256 nftId;

    function setUp() public {
        deployerPrivateKey = vm.envOr(
            "DEPLOYER_PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80)
        );
        listingAddress = vm.envAddress("LISTING_ADDRESS");
        if (listingAddress == address(0)) {
            revert("LISTING_ADDRESS environment variable not set.");
        }

        nftId = vm.envUint("NFT_ID");
        if (nftId == 0) {
            revert("NFT_ID environment variable not set or is zero.");
        }
    }

    function run() public {
        vm.startBroadcast(deployerPrivateKey);

        SuperDCAListing listing = SuperDCAListing(listingAddress);
        address deployer = vm.addr(deployerPrivateKey);
        IPositionManager positionManager = listing.POSITION_MANAGER_V4();

        console2.log("Listing Address:", listingAddress);
        console2.log("Position Manager Address:", address(positionManager));
        console2.log("Deployer Address:", deployer);
        console2.log("NFT ID:", nftId);

        // Check NFT ownership
        address nftOwner = IERC721(address(positionManager)).ownerOf(nftId);
        console2.log("Current NFT Owner:", nftOwner);

        if (nftOwner != deployer) {
            console2.log("ERROR: Deployer does not own the NFT.");
            revert("Deployer does not own the NFT.");
        }

        // Check if the token is already listed
        address tokenOfNfp = listing.tokenOfNfp(nftId);
        if (tokenOfNfp != address(0)) {
            console2.log("WARNING: This NFT is already associated with token:", tokenOfNfp);
        }

        // Query the pool key from the position manager
        console2.log("Querying pool key from position...");
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(nftId);
        console2.log("Pool Currency0:", Currency.unwrap(key.currency0));
        console2.log("Pool Currency1:", Currency.unwrap(key.currency1));
        console2.log("Pool Fee:", key.fee);
        console2.log("Pool Tick Spacing:", uint256(int256(key.tickSpacing)));
        console2.log("Pool Hooks:", address(key.hooks));

        // Approve the listing contract to transfer the NFT
        console2.log("Approving NFT transfer to listing contract...");
        IERC721(address(positionManager)).approve(listingAddress, nftId);
        console2.log("NFT approved.");

        // List the NFT with the pool key
        console2.log("Listing NFT...");
        listing.list(nftId, key);
        console2.log("NFT listed successfully.");

        // Verify the listing
        address newOwner = IERC721(address(positionManager)).ownerOf(nftId);
        console2.log("New NFT Owner:", newOwner);

        address listedToken = listing.tokenOfNfp(nftId);
        console2.log("Listed Token:", listedToken);

        if (newOwner == listingAddress) {
            console2.log("Successfully listed NFT.");
            console2.log("Token", listedToken, "is now listed:", listing.isTokenListed(listedToken));
            
            // Now stake 10 DCA tokens to the newly listed token
            console2.log("");
            console2.log("=== Staking DCA tokens ===");
            
            // Get gauge and staking contracts
            address gaugeAddress = address(listing.expectedHooks());
            SuperDCAGauge gauge = SuperDCAGauge(payable(gaugeAddress));
            address stakingAddress = address(gauge.staking());
            SuperDCAStaking staking = SuperDCAStaking(payable(stakingAddress));
            address dcaToken = listing.SUPER_DCA_TOKEN();
            
            console2.log("Gauge Address:", gaugeAddress);
            console2.log("Staking Address:", stakingAddress);
            console2.log("DCA Token:", dcaToken);
            console2.log("Stake Amount:", STAKE_AMOUNT);
            
            // Check deployer's DCA token balance
            uint256 dcaBalance = IERC20(dcaToken).balanceOf(deployer);
            console2.log("Deployer DCA Balance:", dcaBalance);
            
            if (dcaBalance < STAKE_AMOUNT) {
                console2.log("WARNING: Insufficient DCA token balance. Skipping stake.");
            } else {
                // Approve staking contract to spend DCA tokens
                console2.log("Approving DCA tokens for staking...");
                IERC20(dcaToken).approve(stakingAddress, STAKE_AMOUNT);
                console2.log("DCA tokens approved.");
                
                // Stake to the newly listed token
                console2.log("Staking DCA tokens to listed token...");
                staking.stake(listedToken, STAKE_AMOUNT);
                console2.log("Successfully staked", STAKE_AMOUNT, "DCA tokens to", listedToken);
                
                // Verify the stake
                uint256 stakedAmount = staking.userStakes(deployer, listedToken);
                console2.log("Verified staked amount:", stakedAmount);
            }
        } else {
            console2.log("ERROR: NFT listing verification failed.");
        }

        vm.stopBroadcast();
    }
}

