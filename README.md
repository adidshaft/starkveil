# StarkVeil: Native iOS Shielded Pool

StarkVeil is a purely native cypherpunk iOS wallet that enforces total financial privacy on Starknet via a Zcash-style UTXO model. Unlike standard web3 wallets, StarkVeil removes the need for Trusted Execution Environments (TEEs), bringing Zero-Knowledge STARK proof synthesis directly to the `A`-series silicon inside the iPhone via a Rust SDK bridging layer.

## Project Structure
- **`contracts/`**: The Cairo smart contract that handles the appending of the UTXO Poseidon hashes and validates STARK nullifier proofs to prevent double-spending.
- **`prover/`**: A standard Rust Cargo library that compiles to static binaries (`libstarkveil_prover.a`) leveraging FFI `C` strings to pass Proofs to Swift.
- **`ios/StarkVeil/`**: The native Apple SwiftUI application interface. Handles `@MainActor` thread-safe background light-client syncing, unspent note caching, and premium glassmorphic visual interactions.

---

## 🚀 How to Spin Up the Sandbox (Hackathon Guide)

This repo is completely configured for local testing. Follow these steps sequentially to spin the architecture back up.

### 1. Launch the Local Chain
Open a fresh terminal, ensure the Starknet Dojo toolchain is installed (`katana`), and start the node:
```bash
katana --dev
```
*Leave this running in the background. It spins up local accounts and an RPC endpoint on `127.0.0.1:5050`.*

### 2. Deploy the Cairo Contract
In a second terminal, navigate to the `contracts/` directory and build the Cairo code into Sierra format using `scarb`. 
```bash
cd contracts
scarb build
```

Link an `sncast` account pointing to one of the Katana pre-funded accounts (Katana prints these Private Keys directly in its terminal when it boots up).
```bash
sncast account import --name katana_test --address <PUB_KEY> --private-key <PRIV_KEY> --type open_zeppelin --url http://127.0.0.1:5050
```

Declare and Deploy the Privacy Pool using **sncast 0.50.0** (required for Katana RPC 0.9.0):
```bash
# Ensure correct sncast version
snfoundryup -v 0.50.0

# 1. Declare the contract
sncast --profile katana_test declare --contract-name PrivacyPool

# 2. Deploy via Katana's UDC (Universal Deployer Contract)
# Grab your CLASS_HASH from the output above, then run:
sncast --profile katana_test invoke \
  --contract-address 0x41a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf \
  --function "deployContract" \
  --calldata <CLASS_HASH> 0x0 0x0 0x0
```
*Your deployed contract address will be located in the receipt `event data[0]`.*

### 3. Build the STARK Rust Prover for iOS
Navigate to the `prover/` directory and use the pre-configured bash script to trigger `cargo` targeting Apple ARM architecture.
```bash
cd ../prover
./build_ios.sh
```
*This generates `/prover/target/aarch64-apple-ios/release/libstarkveil_prover.a`.*

### 4. Run the Xcode Simulator
The Xcode project `ios/StarkVeil/StarkVeil.xcodeproj` is fully configured. It statically maps to the Rust binary and the `starkveil_prover.h` bridging headers.
1. Open the project in Xcode.
2. Select **iPhone 15 Simulator** as the target.
3. Hit **Command + R** to build and run the SwiftUI cypherpunk visual interface.

---

## Technical Edge Cases
- **Poseidon Zero Hashes**: For the STARK proof to cryptographically verify on iOS, the Merkle tree `get_zero_hash()` constants in `.cairo` and the Rust STARK circuits must match exactly.
- **CoreData Isolation**: `WalletManager.swift` does not use CoreData in the repo right now to prevent hackathon scoping bloat, but relies on strictly bound `@MainActor` `[Notes]` loops across Combine publishers. Expect state to reset upon quitting the Simulator.
