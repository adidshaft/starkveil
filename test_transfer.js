const { execSync } = require('child_process');
const https = require('https');

const rpcUrl = "https://api.cartridge.gg/x/starknet/sepolia";
const contractAddress = "0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc";
const strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";

function rpcCall(method, params) {
    return new Promise((resolve, reject) => {
        const payload = { jsonrpc: "2.0", id: 1, method, params };
        const options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
        const req = https.request(rpcUrl, options, (res) => {
            let data = '';
            res.on('data', chunk => data += chunk);
            res.on('end', () => resolve(JSON.parse(data)));
        });
        req.on('error', reject);
        req.write(JSON.stringify(payload));
        req.end();
    });
}

function runRustProver() {
    try {
        const inputNodesJSON = JSON.stringify([{
            value: "0x16345785d8a0000",
            asset_id: strkContract,   
            owner_pubkey: "0x7ef44c8e5d9675e4ccf89447ae919c34bd8e979b7646ac6329eece3746dd3c", // Sepolia deployer
            nonce: "0x0",
            commitment: "0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f",
            address_type: "0x0",
            encrypted_value: "0x0",
            recipient_address: "0x0",
            spending_key: "0x704d6b7e32e47c3b1dfa0d65fdfbc96fef3202f2e4ed7c73fa6b791cfa0439d"
        }]);
        
        // 0.05 STRK to another pubkey
        const outputNodesJSON = JSON.stringify([{
            value: "0xb1a2bc2ec500000",
            asset_id: strkContract,
            owner_pubkey: "0x33246ce85ebdc292e6a5c5b4dd51fab2757be34b8ffda847ca6925edf31cb67", // Katana deployer pubkey
            nonce: "0x0",
            commitment: "0x20351717b08dd97de89d6e4b8df21b6c00ed646cb0b7e28a9b2d87e076dfbd6", // dummy
            address_type: "0x0",
            encrypted_value: "0x0",
            recipient_address: "0x0",
            spending_key: "0x0"
        }]);

        // Escape JSON for shell payload
        const inputEscaped = inputNodesJSON.replace(/"/g, '\\"');
        const outputEscaped = outputNodesJSON.replace(/"/g, '\\"');
        
        // Use Rust binary or stark_cli to generate the payload instead of Swift.
        console.log("We'd normally call the Swift app to trigger the Rust CoreData proof here.");
    } catch (e) { console.error(e) }
}

async function main() {
    console.log("=== 1. Checking shielded event exists ===");
    runRustProver();
}

main().catch(console.error);
