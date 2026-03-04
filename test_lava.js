const https = require('https');

// Working Starknet Sepolia RPCs
const rpcUrls = [
    "https://starknet-sepolia.g.alchemy.com/starknet/version/rpc/v0_7/demo",
    "https://api.cartridge.gg/x/starknet/sepolia"
];

const contractAddress = "0x74b2fe0e8674fb9f5ee5417e435492e88dd8dac2c68f67f328d8970883fa931";
const userAddress = "0x00dcfda26eed804f5be31b7d5e4a50e1efee5474c10a4dbffcb04b901fc86a9f";

function rpcCall(url, method, params) {
    return new Promise((resolve, reject) => {
        const parsed = new URL(url);
        const payload = { jsonrpc: "2.0", id: 1, method, params };
        const options = {
            hostname: parsed.hostname, path: parsed.pathname,
            method: 'POST', headers: { 'Content-Type': 'application/json' },
            port: parsed.port || 443
        };
        const req = https.request(options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => {
                try { resolve(JSON.parse(data)); }
                catch (e) { resolve({ raw: data.slice(0, 500) }); }
            });
        });
        req.on('error', e => resolve({ error: e.message }));
        req.write(JSON.stringify(payload));
        req.end();
    });
}

async function main() {
    // Try Lava with proper JSON-RPC params format (positional array)
    console.log("========== Lava (positional params) ==========");
    const url = "https://rpc.starknet-testnet.lava.build";

    console.log("\n--- PrivacyPool getClassHashAt ---");
    // Lava may want positional array params
    const c1 = await rpcCall(url, "starknet_getClassHashAt", ["latest", contractAddress]);
    console.log(JSON.stringify(c1, null, 2));

    console.log("\n--- User getClassHashAt ---");
    const c2 = await rpcCall(url, "starknet_getClassHashAt", ["latest", userAddress]);
    console.log(JSON.stringify(c2, null, 2));

    console.log("\n--- User getNonce ---");
    const n = await rpcCall(url, "starknet_getNonce", ["latest", userAddress]);
    console.log(JSON.stringify(n, null, 2));

    console.log("\n--- STRK balanceOf user ---");
    const strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
    const balOfSelector = "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e";
    const b = await rpcCall(url, "starknet_call", {
        request: { contract_address: strkContract, entry_point_selector: balOfSelector, calldata: [userAddress] },
        block_id: "latest"
    });
    console.log(JSON.stringify(b, null, 2));

    // Let's also check ALL the previous wallet addresses from logs
    // Check if the user created a new wallet — their address may have changed!
    console.log("\n--- Check STRK balanceOf contract ---");
    const b2 = await rpcCall(url, "starknet_call", {
        request: { contract_address: strkContract, entry_point_selector: balOfSelector, calldata: [contractAddress] },
        block_id: "latest"
    });
    console.log(JSON.stringify(b2, null, 2));
}

main().catch(console.error);
