const https = require('https');
const rpcUrl = "https://rpc.starknet-testnet.lava.build";
const contractAddress = "0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc";
const payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "starknet_getStorageAt",
    params: {
        contract_address: contractAddress,
        key: "0x03e2609850a479983c566ae20fc029bc61956f6950343015ef33ea32dd2d935d",
        block_id: "latest"
    }
};
const options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
const req = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log("Storage:", data));
});
req.write(JSON.stringify(payload));
req.end();

const payload2 = {
    jsonrpc: "2.0", id: 2, method: "starknet_call",
    params: {
        request: {
            contract_address: contractAddress,
            entry_point_selector: "0x00074addea198acfff933b6d6b4a4ba165265c7d7261d654c5e32ed6e53e4437",
            calldata: []
        },
        block_id: "latest"
    }
};
const req2 = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log("Call:", data));
});
req2.write(JSON.stringify(payload2));
req2.end();
