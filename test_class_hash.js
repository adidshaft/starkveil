const https = require('https');

const rpcUrl = "https://rpc.starknet-testnet.lava.build";
// Undeployed address
const address = "0x00dcfda26eed804f5be31b7d5e4a50e1efee5474c10a4dbffcb04b901fc86a9f";

const payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "starknet_getClassHashAt",
    params: ["latest", address]
};

const options = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' }
};

const req = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log(data));
});
req.write(JSON.stringify(payload));
req.end();
