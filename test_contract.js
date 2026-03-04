const https = require('https');

const rpcUrl = "https://rpc.starknet-testnet.lava.build";
const contractAddress = "0x74b2fe0e8674fb9f5ee5417e435492e88dd8dac2c68f67f328d8970883fa931";

function rpcCall(method, params) {
    return new Promise((resolve, reject) => {
        const payload = { jsonrpc: "2.0", id: 1, method, params };
        const options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
        const req = https.request(rpcUrl, options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch (e) { resolve({ raw: data }); }
            });
        });
        req.on('error', reject);
        req.write(JSON.stringify(payload));
        req.end();
    });
}

async function main() {
    // 1. Check if PrivacyPool contract exists
    console.log("=== 1. Checking PrivacyPool contract class hash ===");
    const classHash = await rpcCall("starknet_getClassHashAt", ["latest", contractAddress]);
    console.log(JSON.stringify(classHash, null, 2));

    // 2. Check user account
    const userAddress = "0x00dcfda26eed804f5be31b7d5e4a50e1efee5474c10a4dbffcb04b901fc86a9f";
    console.log("\n=== 2. Checking user account ===");
    const userClass = await rpcCall("starknet_getClassHashAt", ["latest", userAddress]);
    console.log(JSON.stringify(userClass, null, 2));

    // 3. Check nonce  
    console.log("\n=== 3. User nonce ===");
    const nonce = await rpcCall("starknet_getNonce", ["latest", userAddress]);
    console.log(JSON.stringify(nonce, null, 2));

    const nonceVal = nonce.result || "0x0";
    const strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
    const approveSelector = "0x219209e083275171774dab1df80982e9df2096516f06319c5c6d71ae0a8480c";
    const shieldSelector = "0x1d142bf165333b22247aed261a8174bd8ba65a3f9b25570d99a8b8f2c32e3ba";
    const amountLow = "0x16345785d8a0000"; // 0.1 STRK
    const amountHigh = "0x0";
    const commitmentKey = "0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f";
    const encryptedMemo = "0x123";

    // 4. Single approve only
    console.log("\n=== 4. Estimate single approve ===");
    const approveCalldata = [
        "0x1", strkContract, approveSelector, "0x3",
        contractAddress, amountLow, amountHigh
    ];
    const approveEst = await rpcCall("starknet_estimateFee", {
        request: [{
            type: "INVOKE", sender_address: userAddress, calldata: approveCalldata,
            version: "0x3", nonce: nonceVal,
            resource_bounds: {
                l1_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l2_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l1_data_gas: { max_amount: "0x0", max_price_per_unit: "0x0" }
            },
            signature: [], paymaster_data: [], account_deployment_data: [],
            nonce_data_availability_mode: "L1", fee_data_availability_mode: "L1", tip: "0x0"
        }],
        simulation_flags: ["SKIP_VALIDATE"], block_id: "latest"
    });
    console.log(JSON.stringify(approveEst, null, 2));

    // 5. Multicall (approve + shield)
    console.log("\n=== 5. Estimate multicall (approve + shield) ===");
    const multicallCalldata = [
        "0x2",
        strkContract, approveSelector, "0x3",
        contractAddress, amountLow, amountHigh,
        contractAddress, shieldSelector, "0x5",
        strkContract, amountLow, amountHigh, commitmentKey, encryptedMemo
    ];
    const multicallEst = await rpcCall("starknet_estimateFee", {
        request: [{
            type: "INVOKE", sender_address: userAddress, calldata: multicallCalldata,
            version: "0x3", nonce: nonceVal,
            resource_bounds: {
                l1_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l2_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l1_data_gas: { max_amount: "0x0", max_price_per_unit: "0x0" }
            },
            signature: [], paymaster_data: [], account_deployment_data: [],
            nonce_data_availability_mode: "L1", fee_data_availability_mode: "L1", tip: "0x0"
        }],
        simulation_flags: ["SKIP_VALIDATE"], block_id: "latest"
    });
    console.log(JSON.stringify(multicallEst, null, 2));
}

main().catch(console.error);
