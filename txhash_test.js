const { hash } = require('starknet');

const senderAddress = "0x00dcfda26eed804f5be31b7d5e4a50e1efee5474c10a4dbffcb04b901fc86a9f";
const classHash = "0x01a736d6ed154502257f02b1ccdf4d9d1089f80811cdce04ae10f7690f00fbd3"; // sep

// This matches the ResourceBounds mapping structure
const resourceBounds = {
    // We pass hex strings, starknet.js will parse them
    l1_gas: { max_amount: '0x30d40', max_price_per_unit: '0x174876e800' },
    l2_gas: { max_amount: '0x989680', max_price_per_unit: '0x174876e800' },
    l1_data_gas: { max_amount: '0x2710', max_price_per_unit: '0x174876e800' }
};

const nonce = "0x5";
const chainId = "0x534e5f5345504f4c4941"; // SN_SEPOLIA
const calldata = ["0x2", "0xabc", "0xdef", "0x3", "0x1", "0x2", "0x3", "0xfab", "0x123", "0x5", "0x1", "0x1", "0x1", "0x1", "0x1"];

try {
    // Pass correct version
    const txHash = hash.calculateInvokeTransactionHash({
        senderAddress,
        version: 3, // Numeric 3
        compiledCalldata: calldata,
        nonce,
        resourceBounds,
        chainId,
        tip: "0x0",
        nonceDataAvailabilityMode: "0x0", // L1
        feeDataAvailabilityMode: "0x0",   // L1
        accountDeploymentData: [],
        paymasterData: []
    });

    console.log("Starknet.js txHash:", txHash);
} catch (e) {
    console.error("Error with starknet.js:", e.message);
    console.error(e.stack);
}
