const https = require('https');

const rpcUrl = "https://rpc.starknet-testnet.lava.build";

const senderAddress = "0x00dcfda26eed804f5be31b7d5e4a50e1efee5474c10a4dbffcb04b901fc86a9f"; // My activated address
const nonce = "0x5"; // Replace with whatever
const contractAddress = "0x74b2fe0e8674fb9f5ee5417e435492e88dd8dac2c68f67f328d8970883fa931";
const strkContractAddress = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d";
const approveSelector = "0x219209e083275171774dab1df80982e9df2096516f06319c5c6d71ae0a8480c";
const shieldSelector = "0x1d142bf165333b22247aed261a8174bd8ba65a3f9b25570d99a8b8f2c32e3ba";
const amountLow = "0x14d1120d7b160000"; // 1.5 STRK
const amountHigh = "0x0";

// Some mock commitment elements
const commitmentKey = "0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f";
const encryptedMemo = "0x123";

const calldata = [
    "0x2",
    strkContractAddress,
    approveSelector,
    "0x3",
    contractAddress, amountLow, amountHigh,
    contractAddress,
    shieldSelector,
    "0x5",
    strkContractAddress, amountLow, amountHigh, commitmentKey, encryptedMemo
];

const payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "starknet_estimateFee",
    params: {
        request: [{
            type: "INVOKE",
            sender_address: senderAddress,
            calldata: calldata,
            version: "0x3",
            nonce: nonce,
            resource_bounds: {
                l1_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l2_gas: { max_amount: "0x0", max_price_per_unit: "0x0" },
                l1_data_gas: { max_amount: "0x0", max_price_per_unit: "0x0" }
            },
            signature: [],
            paymaster_data: [],
            account_deployment_data: [],
            nonce_data_availability_mode: "L1",
            fee_data_availability_mode: "L1",
            tip: "0x0"
        }],
        simulation_flags: ["SKIP_VALIDATE"],
        block_id: "latest"
    }
};

const options = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' }
};

const req = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log(JSON.stringify(JSON.parse(data), null, 2)));
});

req.on('error', e => console.error(e));
req.write(JSON.stringify(payload));
req.end();
