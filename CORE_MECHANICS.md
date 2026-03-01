# StarkVeil: Core Mechanics & Architecture Reference

This document serves as the central source of truth for the StarkVeil project's system architecture, development phases, and core cryptographic mechanics.

## Development Phases

### Phase 1: Cryptographic Architecture (Completed)
Defined the visibility surfaces, threat models, and fundamental data structures.
- **UTXO Model**: Zcash-style `Note` structure containing value, asset ID, owner viewing key, and memo.
- **Nullifiers**: Used to track spent notes and prevent double spending without revealing which exact note was spent.

### Phase 2: On-Chain Shielded Pool (Cairo) (Completed)
The on-chain settlement layer built on Starknet.
- **PrivacyPool Contract**: Handles `shield`, `private_transfer`, and `unshield` operations.
- **Merkle Tree**: An append-only state construct (depth 20) utilizing Starknet's native Poseidon hash. It stores root commitments representing all unspent shielded value.
- **Zero-Knowledge Hooks**: Prepared `private_transfer` to accept and process verified S-Two STARK proofs, decoupling heavy computation from iOS devices directly onto the Starknet execution layer.

### Phase 3: Client-Side Proving Pipeline (In Progress)
Transitioning STARK proof generation to iOS via a Rust SDK, omitting TEE trust assumptions.
- **Target**: Mobile-native Rust code cross-compiled as `libstarkveil_prover.a`.
- **FFI**: Uniffi or raw C bindings communicating JSON-serialized structs (Notes, Nullifiers) between Swift and Rust.
- **Output**: Generates formatted dummy proofs (for MVP) and eventually full S-Two cryptographic proofs to be posted on-chain.

### Phase 4: iOS App Engineering (SwiftUI) (Upcoming)
The mobile frontend managing keys, state, and user interactions.
- **CoreData Syncing**: Light client engine indexing Starknet RPC events to rebuild the Merkle tree locally.
- **Viewing Key Logic**: Identifying user-owned notes from raw blockchain events.

### Phase 5: High-End UI/UX Assembly (Upcoming)
Premium dark-themed glassmorphic UI overlay ensuring "Privacy by Default".

### Phase 6: Auditing & Launch (Upcoming)
Formal verification of Cairo contracts and beta net deployment.
- **[CRITICAL TODO]**: Before real ZK verifiers are wired, someone must pre-compute the 20 levels of canonical Poseidon empty-subtree hashes starting from 0, and hardcode the exact 20 hex constants synchronously into both the `PrivacyPool.cairo` `get_zero_hash()` method and the Rust SDK. If these differ, no proofs will verify.

---

## Core Mechanics Dictionary

- **Note (`Note`)**: The fundamental unit of value inside the shielded pool. A public encapsulation of `Hash(value, asset_id, owner_ivk, memo)`.
- **Note Commitment**: The Poseidon hash of a fully constructed `Note`. This is inserted into the Merkle Tree on-chain.
- **Nullifier**: A cryptographic hash derived from a spending key and the note's position. Used to publicly flag a note as "spent" without tracking its origin. `Hash(spending_key, note_position)`.
- **Viewing Key (IVK)**: A decentralized read-only key stored on iOS iCloud. Allows reconstruction of note values for auditing but cannot authorize spending.
- **Spending Key**: Safely isolated inside the iOS Secure Enclave.
- **Private Transfer Proof**: The STARK equation proving:
  1. The unspent status of the consumed Note's Nullifier.
  2. Conservation of Balance (Inputs = Outputs + Fee).
  3. Range bounds (Amounts > 0 and within limit).
