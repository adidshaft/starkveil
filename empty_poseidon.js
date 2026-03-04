const { hash } = require('starknet');

// Create a small script to print poseidon computed over empty array
import('starknet').then((starknet) => {
    // starknet.js exports poseidonHashMany but it might be under utils
    const hashMany = starknet.poseidonHashMany || starknet.hash.poseidonHashMany;
    if (hashMany) {
        console.log("Empty poseidon JS:", hashMany([]).toString(16));
    }
}).catch(console.error);
