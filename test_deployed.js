const https = require('https');

// Test the Cartridge RPC with the exact format our Swift RPCClient sends
function rpcCall(url, method, params) {
    return new Promise((resolve, reject) => {
        const parsed = new URL(url);
        const payload = { jsonrpc: "2.0", id: 1, method, params };
        const options = {
            hostname: parsed.hostname, path: parsed.pathname,
            method: 'POST', headers: { 'Content-Type': 'application/json' },
        };
        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch (e) { resolve({ raw: data.slice(0, 500) }); }
            });
        });
        req.on('error', reject);
        req.write(JSON.stringify(payload));
        req.end();
    });
}

async function main() {
    const url = "https://api.cartridge.gg/x/starknet/sepolia";
    const privacyPool = "0x20768453fb80c8958fdf9ceefa7f5af63db232fe2b8e9e36ead825301c4de74";

    // 1. Verify PrivacyPool is deployed
    console.log("=== 1. Verify PrivacyPool deployed ===");
    const ch = await rpcCall(url, "starknet_getClassHashAt", {
        block_id: "latest", contract_address: privacyPool
    });
    console.log(JSON.stringify(ch, null, 2));

    // 2. Test getNonce with struct params (matches our Swift format)
    console.log("\n=== 2. getNonce with struct params ===");
    const n = await rpcCall(url, "starknet_getNonce", {
        block_id: "latest", contract_address: "0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b"
    });
    console.log(JSON.stringify(n, null, 2));

    // 3. Test estimateFee with our format (including l1_data_gas)
    console.log("\n=== 3. estimateFee with l1_data_gas ===");
    const strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
    const approveSelector = "0x219209e083275171774dab1df80982e9df2096516f06319c5c6d71ae0a8480c";
    const shieldSelector = "0x1d142bf165333b22247aed261a8174bd8ba65a3f9b25570d99a8b8f2c32e3ba";
    const addr = "0x04cd8bba3c9f970dd5cbd1f87a31ace6db3d47d9ae65f1fa9d16c0cb962f8f9b";
    const amountLow = "0x16345785d8a0000"; // 0.1 STRK

    const calldata = [
        "0x2",
        strkContract, approveSelector, "0x3",
        privacyPool, amountLow, "0x0",
        privacyPool, shieldSelector, "0x5",
        strkContract, amountLow, "0x0", "0xDEADBEEF", "0x123"
    ];

    const fee = await rpcCall(url, "starknet_estimateFee", {
        request: [{
            type: "INVOKE",
            sender_address: addr,
            calldata: calldata,
            version: "0x3",
            nonce: n.result || "0x1",
            resource_bounds: {
                l1_gas: { max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff" },
                l2_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l1_data_gas: { max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff" }
            },
            signature: [],
            paymaster_data: [],
            account_deployment_data: [],
            nonce_data_availability_mode: "L1",
            fee_data_availability_mode: "L1",
            tip: "0x0"
        }],
        block_id: "latest",
        simulation_flags: ["SKIP_VALIDATE"]
    });
    console.log(JSON.stringify(fee, null, 2));
}

main().catch(console.error);
