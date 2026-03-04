/**
 * deploy_all.js — Declare + Deploy PrivacyPool to Starknet Sepolia
 * Account already deployed at 0x04cd8bba...
 */
const { RpcProvider, Account, CallData, hash, Signer } = require('starknet');
const fs = require('fs');
const path = require('path');

const RPC_URL = "https://api.cartridge.gg/x/starknet/sepolia";
const PRIVATE_KEY = "0x01c0b584b3f377f7d712797ef79f97dc43de9a19da06585071b06eecb6f59362";
const DEPLOYER_ADDRESS = "0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b";

const provider = new RpcProvider({ nodeUrl: RPC_URL });

async function main() {
    console.log("=== StarkVeil PrivacyPool — Declare & Deploy ===\n");

    const account = new Account({
        provider: provider,
        address: DEPLOYER_ADDRESS,
        signer: new Signer(PRIVATE_KEY),
        cairoVersion: '1',
    });

    // Verify account is deployed
    const nonce = await provider.getNonceForAddress(DEPLOYER_ADDRESS);
    console.log(`Deployer account nonce: ${nonce} ✅\n`);

    // Read Sierra + CASM
    const sierraPath = path.join(__dirname, "contracts/target/dev/contracts_PrivacyPool.contract_class.json");
    const casmPath = path.join(__dirname, "contracts/target/dev/contracts_PrivacyPool.compiled_contract_class.json");

    const sierraJSON = JSON.parse(fs.readFileSync(sierraPath, 'utf-8'));
    const casmJSON = JSON.parse(fs.readFileSync(casmPath, 'utf-8'));
    console.log(`Sierra: ${(fs.statSync(sierraPath).size / 1024).toFixed(0)} KB`);
    console.log(`CASM:   ${(fs.statSync(casmPath).size / 1024).toFixed(0)} KB\n`);

    // Step 1: Declare
    console.log("Step 1: Declaring PrivacyPool class...");
    let classHash;
    try {
        const declareResult = await account.declare({
            contract: sierraJSON,
            casm: casmJSON,
        });
        classHash = declareResult.class_hash;
        console.log(`  Tx: ${declareResult.transaction_hash}`);
        console.log(`  Class hash: ${classHash}`);
        console.log("  Waiting for confirmation...");
        await provider.waitForTransaction(declareResult.transaction_hash);
        console.log("  ✅ Declared!\n");
    } catch (e) {
        const msg = e.message || '';
        console.log(`  Note: ${msg.slice(0, 300)}`);
        // If already declared, extract the class hash
        if (msg.includes('51') || msg.includes('already') || msg.includes('Class already declared')) {
            classHash = hash.computeSierraContractClassHash(sierraJSON);
            console.log(`  Using computed class hash: ${classHash}\n`);
        } else {
            // Try computing anyway
            try {
                classHash = hash.computeSierraContractClassHash(sierraJSON);
                console.log(`  Computed class hash: ${classHash}`);
                // Check if it already exists
                const existing = await provider.getClassByHash(classHash);
                if (existing) {
                    console.log("  Class already exists on-chain! ✅\n");
                }
            } catch (e2) {
                console.error("  Fatal: Cannot determine class hash");
                throw e;
            }
        }
    }

    // Step 2: Deploy
    console.log("Step 2: Deploying PrivacyPool contract...");
    try {
        const deployResult = await account.deploy({
            classHash: classHash,
            constructorCalldata: [],
            salt: "0x535441524b5645494c", // "STARKVEIL"
        });

        const contractAddr = Array.isArray(deployResult.contract_address)
            ? deployResult.contract_address[0]
            : deployResult.contract_address;
        console.log(`  Tx: ${deployResult.transaction_hash}`);
        console.log(`  Contract: ${contractAddr}`);
        console.log("  Waiting for confirmation...");
        await provider.waitForTransaction(deployResult.transaction_hash);

        console.log("\n========================================");
        console.log("  ✅ DEPLOYMENT COMPLETE!");
        console.log("========================================");
        console.log(`  Contract: ${contractAddr}`);
        console.log(`  Class:    ${classHash}`);
        console.log(`\n  NetworkEnvironment.swift update:`);
        console.log(`  case .sepolia: return "${contractAddr}"`);
    } catch (e) {
        console.error(`  Error: ${e.message?.slice(0, 400)}`);
    }
}

main().catch(e => { console.error("Fatal:", e.message || e); process.exit(1); });
