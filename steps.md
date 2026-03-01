# StarkVeil: Journey & Architecture Decisions

This file serves as a comprehensive log of the steps taken, architectural decisions made, and the reasoning behind the current state of the StarkVeil product from day one.

## The Core Philosophy
We started with a vision of a cypherpunk, native Starknet iOS wallet offering complete financial privacy by default. We explicitly chose to **reject Trusted Execution Environments (TEEs)** and instead rely on true mathematical cryptography (ZK-STARKs) generated locally on bare-metal iPhone silicon.

---

## Phase 1: Cryptographic Architecture
- **Decision**: We adopted a Zcash-style UTXO model mapping `Notes` and `Nullifiers`.
- **Why**: This is the industry gold standard for privacy. It keeps the sender, receiver, and transfer amount mathematically masked on the public Starknet ledger, converting transparent balances into opaque cryptographic commitments.

## Phase 2: On-Chain Shielded Pool (Cairo)
- **Action**: Built the `PrivacyPool` smart contract inside the `contracts/` directory using Cairo 2.X.
- **Decision**: We implemented an append-only Merkle tree natively within contract storage using `Poseidon` hashing.
- **Why**: Poseidon is an algebraic hash function that is extremely STARK-friendly. It drastically reduces the computational cost of verifying ZK proofs on-chain compared to Keccak256 or SHA256.

## Phase 3: Client-Side Proving Engine (Rust FFI)
- **Action**: Created a standard Rust library (`prover/`) targeting Apple's iOS ARM architecture.
- **Decision**: Exported our payload structures using C-compatible Foreign Function Interfaces (FFI) and compiled the engine into a static archive (`libstarkveil_prover.a`).
- **Why**: Swift is excellent for UI but terrible for running heavy cryptographic ZK polynomial constraints. Native Rust compiled specifically for `aarch64-apple-ios` gives maximum proving performance while passing stringified JSON payloads back across the C-boundary safely using memory-managed pointers.

## Phase 4: iOS Native App Core (Swift)
- **Action**: Built the logic interfaces: `SyncEngine.swift`, `WalletManager.swift`, and `StarkVeilProver.swift`.
- **Decision**: Wrapped the C-pointers in Swift classes and implemented reactive data flows using Apple's `Combine` framework and `@MainActor` thread constraints.
- **Why**: To smoothly handle background node syncing, FFI proof generation delays, and state mutations without ever lagging or locking up the user's main UI thread.

## Phase 5: High-End UI/UX Assembly
- **Action**: Refactored the monolithic Swift interface into atomic components: `VaultHeaderView`, `ShieldedBalanceCard`, `PrivateSendForm`, and a dynamic `ProofSynthesisSkeleton`.
- **Decision**: Applied OLED True Black (`#000000`) backgrounds, `UltraThinMaterial` blurring, and continuous Haptic-feedback spring animations.
- **Why**: A cypherpunk wallet needs to feel viscerally secure. Forcing users to physically press and hold the screen to decrypt a blurred balance physically protects them from over-the-shoulder snooping.

## Phase 6: Cryptographic Alignment & Launch Prep
- **Action**: Executed an offline algorithm to compute 20 depth-levels of empty Poseidon Zero-Hashes (`poseidon_hash(Level, Level)`), and injected these exact 20 hex constants into both the Cairo contract and the Rust prover SDK.
- **Decision**: Handled a deployment chain mismatch by identifying that Katana 1.7.1 outputs RPC 0.9.0 logic, therefore enforcing `snfoundryup -v 0.50.0` for `sncast` contract deployments.
- **Why**: The zero-hashes are absolutely essential: if the iOS Prover and the Katana Smart Contract do not agree on the exact mathematical state of an "Empty" Merkle Tree, the ZK Proofs will permanently fail to verify on-chain.

---

## Current State of the Product
StarkVeil is currently a functionally complete Sandbox engineered perfectly for Hackathon evaluation. 
1. The **Smart Contracts** compile flawlessly and are configured for local Katana deployment.
2. The **Rust Prover SDK** builds directly to an iOS compatible static C-library with accurately mapped FFI boundaries.
3. The **SwiftUI Application** is fully wired. Bridging headers seamlessly link the UI to the underlying Rust math engine. Xcode will successfully build and launch the application natively onto an iOS Simulator to demo the complex private transfer cycles.
