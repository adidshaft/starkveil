/**
 * deploy_contract.mjs — Deploy PrivacyPool to Starknet Sepolia
 * 
 * Uses starknet.js v9 with the funded deployer account.
 * Private key: 0x01c0b584b3f377f7d712797ef79f97dc43de9a19da06585071b06eecb6f59362
 * Address:     0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b
 */

import { RpcProvider, Account, Contract, json, CallData, hash, num } from 'starknet';
import fs from 'fs';
import path from 'path';

const RPC_URL = "https://api.cartridge.gg/x/starknet/sepolia";
const PRIVATE_KEY = "0x01c0b584b3f377f7d712797ef79f97dc43de9a19da06585071b06eecb6f59362";
const DEPLOYER_ADDRESS = "0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b";
const OZ_CLASS_HASH = "0x061dac032f228abef9c6626f995015233097ae253a7f72d68552db02f2971b8f";

const provider = new RpcProvider({ nodeUrl: RPC_URL });

async function main() {
    console.log("=== StarkVeil PrivacyPool Deployment ===\n");

    // Step 1: Check if the deployer account is already deployed
    console.log("Step 1: Checking deployer account status...");
    try {
        const nonce = await provider.getNonceForAddress(DEPLOYER_ADDRESS);
        console.log(`  Account already deployed! Nonce: ${nonce}`);
    } catch (e) {
        console.log(`  Account not yet deployed. Deploying now...`);
        await deployAccount();
    }

    // Step 2: Create Account object
    const account = new Account(provider, DEPLOYER_ADDRESS, PRIVATE_KEY);

    // Step 3: Read the Sierra contract class
    console.log("\nStep 2: Reading PrivacyPool Sierra artifact...");
    const sierraPath = path.join(process.cwd(), "contracts/target/dev/contracts_PrivacyPool.contract_class.json");
    const sierraJSON = JSON.parse(fs.readFileSync(sierraPath, 'utf-8'));
    console.log(`  Sierra read: ${sierraJSON.entry_points_by_type ? 'OK' : 'MISSING entry_points'}`);

    // Step 4: Declare the contract class
    console.log("\nStep 3: Declaring PrivacyPool class...");
    let classHash;
    try {
        const declareResult = await account.declare({
            contract: sierraJSON,
        });
        console.log(`  Declare tx: ${declareResult.transaction_hash}`);
        console.log(`  Class hash: ${declareResult.class_hash}`);
        classHash = declareResult.class_hash;

        console.log("  Waiting for declare tx confirmation...");
        await provider.waitForTransaction(declareResult.transaction_hash);
        console.log("  ✅ Declared!");
    } catch (e) {
        if (e.message && e.message.includes("already declared")) {
            console.log("  Class already declared — extracting class hash from artifact...");
            classHash = hash.computeContractClassHash(sierraJSON);
            console.log(`  Class hash: ${classHash}`);
        } else {
            // Try computing class hash and checking if it exists
            console.log(`  Declare error: ${e.message}`);
            classHash = hash.computeContractClassHash(sierraJSON);
            console.log(`  Computed class hash: ${classHash}`);

            try {
                const existing = await provider.getClassByHash(classHash);
                console.log("  Class already exists on-chain!");
            } catch (e2) {
                console.error("  ❌ Cannot declare and class doesn't exist. Error:", e.message);
                process.exit(1);
            }
        }
    }

    // Step 5: Deploy the contract (no constructor args — PrivacyPool has no constructor)
    console.log("\nStep 4: Deploying PrivacyPool contract...");
    try {
        const deployResult = await account.deploy({
            classHash: classHash,
            constructorCalldata: [],  // No constructor args
        });
        console.log(`  Deploy tx: ${deployResult.transaction_hash}`);
        console.log(`  Contract address: ${deployResult.contract_address}`);

        console.log("  Waiting for deploy tx confirmation...");
        await provider.waitForTransaction(deployResult.transaction_hash);
        console.log("  ✅ Deployed!");

        console.log("\n========================================");
        console.log(" DEPLOYMENT COMPLETE!");
        console.log("========================================");
        console.log(` Contract Address: ${deployResult.contract_address}`);
        console.log("\n Update NetworkEnvironment.swift:");
        console.log(`   case .sepolia: return "${deployResult.contract_address}"`);
    } catch (e) {
        console.error("  Deploy error:", e.message);

        // The contract might already be deployed at a deterministic address
        const deployedAddr = hash.calculateContractAddressFromHash(
            0,  // salt
            classHash,
            [],  // constructor calldata
            DEPLOYER_ADDRESS  // deployer address
        );
        console.log(`  Expected address: ${deployedAddr}`);
    }
}

async function deployAccount() {
    console.log("  Deploying OZ account...");
    const account = new Account(provider, DEPLOYER_ADDRESS, PRIVATE_KEY);

    try {
        const { transaction_hash } = await account.deployAccount({
            classHash: OZ_CLASS_HASH,
            constructorCalldata: CallData.compile({ publicKey: account.signer.getPubKey() }),
            addressSalt: account.signer.getPubKey(),
        });
        console.log(`  Deploy account tx: ${transaction_hash}`);
        await provider.waitForTransaction(transaction_hash);
        console.log("  ✅ Account deployed!");
    } catch (e) {
        console.log(`  Account deploy error: ${e.message}`);
        // Try a different approach — use the lower level API
        throw e;
    }
}

main().catch(e => { console.error("Fatal:", e.message); process.exit(1); });
