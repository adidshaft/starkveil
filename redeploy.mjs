/**
 * redeploy.mjs — Declare + Deploy updated PrivacyPool (starknet.js v9.2.1)
 */
import { RpcProvider, Account, hash } from 'starknet';
import fs from 'fs';
import path from 'path';

const RPC_URL = "https://api.cartridge.gg/x/starknet/sepolia";
const PRIVATE_KEY = "0x01c0b584b3f377f7d712797ef79f97dc43de9a19da06585071b06eecb6f59362";
const DEPLOYER_ADDRESS = "0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b";

const provider = new RpcProvider({ nodeUrl: RPC_URL });

async function main() {
    console.log("=== StarkVeil PrivacyPool Redeployment ===\n");

    // starknet.js v9 uses options-object constructor
    const account = new Account({
        provider: provider,
        address: DEPLOYER_ADDRESS,
        signer: PRIVATE_KEY,
        cairoVersion: "1",
    });
    console.log("Account created:", account.address);

    // Read artifacts
    const sierraPath = path.join(process.cwd(), "contracts/target/dev/contracts_PrivacyPool.contract_class.json");
    const casmPath = path.join(process.cwd(), "contracts/target/dev/contracts_PrivacyPool.compiled_contract_class.json");
    const sierra = JSON.parse(fs.readFileSync(sierraPath, 'utf-8'));
    const casm = JSON.parse(fs.readFileSync(casmPath, 'utf-8'));
    console.log("Sierra and CASM artifacts loaded.");

    // Declare
    console.log("\nDeclaring PrivacyPool class...");
    let classHash;
    try {
        const declareResult = await account.declare({
            contract: sierra,
            casm: casm,
        });
        console.log(`Declare tx: ${declareResult.transaction_hash}`);
        classHash = declareResult.class_hash;
        console.log(`Class hash: ${classHash}`);

        console.log("Waiting for declare confirmation...");
        await provider.waitForTransaction(declareResult.transaction_hash);
        console.log("✅ Declared!");
    } catch (e) {
        const msg = e.message || String(e);
        console.log("Declare result:", msg);
        if (msg.includes("already declared") || msg.includes("Class already")) {
            try {
                classHash = hash.computeContractClassHash(sierra);
            } catch (e2) {
                classHash = hash.computeSierraContractClassHash(sierra);
            }
            console.log(`Using computed class hash: ${classHash}`);
        } else {
            throw e;
        }
    }

    // Deploy
    console.log("\nDeploying PrivacyPool contract...");
    try {
        const deployResult = await account.deploy({
            classHash: classHash,
            constructorCalldata: [],
        });
        console.log(`Deploy tx: ${deployResult.transaction_hash}`);

        const contractAddr = deployResult.contract_address || "CHECK_RECEIPT";
        console.log(`Contract address: ${contractAddr}`);

        console.log("Waiting for deploy confirmation...");
        await provider.waitForTransaction(deployResult.transaction_hash);
        console.log("✅ Deployed!");

        console.log("\n========================================");
        console.log(" DEPLOYMENT COMPLETE!");
        console.log("========================================");
        console.log(` Contract Address: ${contractAddr}`);
    } catch (e) {
        console.error("Deploy error:", e.message || e);
    }
}

main().catch(e => { console.error("Fatal:", e.message || e); process.exit(1); });
