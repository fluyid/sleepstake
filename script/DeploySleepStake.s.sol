// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {Script, console} from "forge-std/Script.sol";
import {SleepStake} from "../src/SleepStake.sol";

/**
 * @title DeploySleepStake
 * @notice Deployment script for SleepStake smart contract.
 * Reads the oracle wallet address from the ORACLE_ADDRESS environment variable,
 * deploys the contract using the transaction signer, and logs deployment details.
 */
contract DeploySleepStake is Script {
    function run() external returns (SleepStake sleepStake) {
        // Read the dedicated oracle address from the environment
        address oracle = vm.envAddress("ORACLE_ADDRESS");

        // Begin recording transactions to be signed and broadcast
        // The sender/signer is determined by Foundry flags (--account or --private-key)
        vm.startBroadcast();

        // Deploy the SleepStake contract; the deployer address automatically becomes the owner (treasury)
        sleepStake = new SleepStake(oracle);

        // Stop recording broadcast transactions
        vm.stopBroadcast();

        // Print deployment summary to console
        console.log("SleepStake deployed at:", address(sleepStake));
        console.log("Owner (treasury):", sleepStake.owner());
        console.log("Oracle:", sleepStake.oracle());
    }
}
