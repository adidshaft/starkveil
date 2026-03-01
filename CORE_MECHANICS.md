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

### Phase 4: iOS App Engineering (SwiftUI Core)
Built a premium, dark-themed native iOS wallet wrapper capable of interfacing directly with the Rust Proving SDK via `.a` bridging.

#### Core iOS Architecture
1. **SyncEngine**: A background reactor that simulates (or eventually runs) Starknet Light Client polling. It detects incoming "public" tokens and auto-triggers Shielding pipelines silently.
2. **WalletManager**: Holds the `decryptedBalance` and tracks the array of active unspent UTXO `Note` structs. Interacts asynchronously with the Rust STARK prover natively.
3. **StarkVeilProver**: The FFI boundary struct. It serializes arrays of `Note` constraints into JSON, sends them via a `cString` pointer to the Rust `generate_transfer_proof` C-interface, frees the Rust memory to prevent iOS memory leakage, and decodes the resulting JSON payload.

---

### Phase 5: High-End UI/UX Assembly (SwiftUI)
The StarkVeil UI is constructed using native SwiftUI to offer a "Premium Vault" aesthetic. It breaks away from traditional "web3 wallet" interfaces to prioritize strict physical privacy against over-the-shoulder lookers.

#### Aesthetic Rules
- **Color Palette**: Pure OLED Black backgrounds (`#000000`) mapping to true pixels-off displays to conserve battery during heavy ZK operations. Use `UltraThinMaterial` or dark grays with blur radiuses for cards.
- **Micro-Animations**: 
  - The Syncing indicator utilizes scale-pulsing for a "breathing" background thread feel.
  - The Shielded Balance acts as the primary focal point: it remains universally obfuscated (`••••••`) and requires a deliberate, non-trivial intent gesture (a continuous `@GestureState` LongPress) to reveal the numeric `decryptedBalance`.
- **Proof Generation State**: Starknet STARK proof synthesis is an inherently blocking, complex mathematical operation. Instead of a standard loading spinner, the action button dynamically swaps to a "Synthesizing STARK Proof..." label alongside a `CircularProgressViewStyle`, communicating that actual secure computation is occurring natively.

#### SwiftUI Structure
- **VaultHeaderView**: Houses the branded typography and the SyncEngine status indicator.
- **ShieldedBalanceCard**: The interactive focal pane obfuscating the total parsed UTXO bounds.
- **PrivateSendForm**: The isolated constraint inputs handling `transferAmount` and `recipientAddress`. Holds independent local-validation for balance thresholds before emitting to the `WalletManager`.

---

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
