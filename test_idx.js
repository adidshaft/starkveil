const https = require('https');
const rpcUrl = "https://rpc.starknet-testnet.lava.build";
const contractAddress = "0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc";
const payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "starknet_getStorageAt",
    params: {
        contract_address: contractAddress,
        key: "0x00a25379c1f6617ffc4b2314ba856f3dfc9ef61c99ff48d938c4e8a89aad6b7a",
        block_id: "latest"
    }
};
const options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
const req = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log("Index:", data));
});
req.write(JSON.stringify(payload));
req.end();
