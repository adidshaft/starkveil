const https = require('https');
const rpcUrl = "https://rpc.starknet-testnet.lava.build";
const contractAddress = "0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc";
const payload = {
    jsonrpc: "2.0",
    id: 1,
    method: "starknet_getEvents",
    params: {
        filter: {
            from_block: { block_number: 0 },
            to_block: "latest",
            address: contractAddress,
            chunk_size: 10
        }
    }
};
const options = { method: 'POST', headers: { 'Content-Type': 'application/json' } };
const req = https.request(rpcUrl, options, (res) => {
    let data = '';
    res.on('data', chunk => data += chunk);
    res.on('end', () => console.log(JSON.stringify(JSON.parse(data), null, 2)));
});
req.write(JSON.stringify(payload));
req.end();
