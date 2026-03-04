const { hash } = require('starknet');

console.log("approve:", hash.getSelectorFromName("approve"));
console.log("shield:", hash.getSelectorFromName("shield"));
console.log("unshield:", hash.getSelectorFromName("unshield"));
console.log("transfer:", hash.getSelectorFromName("transfer"));
