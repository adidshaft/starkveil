# StarkVeil: Core Mechanics & Architecture Reference

This document serves as the central source of truth for the StarkVeil project's system architecture, development phases, and core cryptographic mechanics.

## Development Phases

### Phase 1: Cryptographic Architecture (Completed)
Defined the visibility surfaces, threat models, and fundamental data structures.
- **UTXO Model**: StarkVeil `Note` commitment structure containing value, asset ID, owner viewing key, and memo.
- **Nullifiers**: Used to track spent notes and prevent double spending without revealing which exact note was spent.

### Phase 2: On-Chain Shielded Pool (Cairo) (Completed)
The on-chain settlement layer built on Starknet.
- **PrivacyPool Contract**: Handles `shield`, `private_transfer`, and `unshield` operations.
- **Merkle Tree**: An append-only state construct (depth 20) utilizing Starknet's native Poseidon hash. It stores root commitments representing all unspent shielded value.
- **Zero-Knowledge Hooks**: Prepared `private_transfer` to accept and process verified S-Two STARK proofs, decoupling heavy computation from iOS devices directly onto the Starknet execution layer.

### Phase 3: Client-Side Proving Pipeline (Completed)
Transitioning STARK proof generation to iOS via a Rust SDK, omitting TEE trust assumptions.
- **Target**: Mobile-native Rust code cross-compiled as `StarkVeilProver.xcframework` bundling simulators and physical binaries natively.
- **FFI**: Uniffi or raw C bindings communicating JSON-serialized structs (Notes, Nullifiers) between Swift and Rust.
- **Output**: Generates formatted dummy proofs (for MVP) and eventually full S-Two cryptographic proofs to be posted on-chain.

### Phase 4: iOS App Engineering (Completed)
The mobile frontend managing keys, state, and user interactions.
- **CoreData Syncing**: Light client engine indexing Starknet RPC events to rebuild the Merkle tree locally.
- **Viewing Key Logic**: Identifying user-owned notes from raw blockchain events.

### Phase 5: High-End UI/UX Assembly (Completed)
Premium dark-themed glassmorphic UI overlay ensuring "Privacy by Default".

### Phase 4: iOS App Engineering (SwiftUI Core)
Built a premium, dark-themed native iOS wallet wrapper capable of interfacing directly with the Rust Proving SDK via `.a` bridging.

#### Core iOS Architecture
1. **SyncEngine**: A light-client reactor polling Starknet JSON-RPC every 5 seconds (`starknet_blockNumber` + `starknet_getEvents`). Detects incoming `Shielded` events from the `PrivacyPool` contract, decodes Cairo `u256` arrays into Swift `Note` structs, and emits them via `PassthroughSubject`. Concurrency-safe via `isFetchingRPC` guard and `syncEpoch` network-switch isolation.
2. **WalletManager**: Holds the `decryptedBalance` and tracks the array of active unspent UTXO `Note` structs. Interacts asynchronously with the Rust STARK prover natively. Handles strictly-enforced state isolation flushes cross-thread.
3. **StarkVeilProver**: The FFI boundary struct. It serializes arrays of `Note` constraints into JSON, sends them via a `cString` pointer to the Rust `generate_transfer_proof` C-interface, frees the Rust memory to prevent iOS memory leakage, and decodes the resulting JSON payload.
4. **NetworkEnvironment**: Global deterministic singleton containing explicit RPC boundaries and routing limits for STARK proofs targeted at Mainnet or Sepolia respectively.

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

### Phase 6: Auditing & Launch (Completed)
Formal verification of Cairo contracts and beta net deployment.
- **[RESOLVED TO-DO]**: Computed the 20 levels of canonical Poseidon empty-subtree hashes starting from 0, and hardcoded the exact 20 hex constants synchronously into both the `PrivacyPool.cairo` `get_zero_hash()` method and the Rust SDK.

---

### Phase 7: Real Network Integration (Completed)
Transitioning the StarkVeil app off Katana Sandbox mocked timers and linking standard infrastructure nodes.
- **[Completed]**: Network selection topology (`NetworkEnvironment` integration) mapping to `mainnet-juno` or `sepolia-juno` HTTP pools.
- **[Completed]**: Dynamic `clearStore()` State-flush across `WalletManager` via `SyncEngine.networkChanged` with `MainActor.assumeIsolated` ordering guarantee.

---

### Phase 8: JSON-RPC Sync Engine (Completed)
Live blockchain polling replacing the mock deposit generator.
- **`RPCModels.swift`**: `Codable` structs for `starknet_blockNumber` and `starknet_getEvents` with correct `BlockId` encoding (fixed double-container JSON encoder crash).
- **`RPCClient.swift`**: `URLSession`-based HTTP client with paginated event fetching.
- **`SyncEngine.tick()`**: Diffs `currentBlockNumber` vs `latestBlock`, fetches events page-by-page, decodes Cairo `u256` arrays into Swift `Note` structs, delivers the full batch in a single `MainActor.run` hop.
- **Concurrency**: `isFetchingRPC` guard + `syncEpoch` counter prevent overlapping requests and stale-network note injection after network switches.

---

### Phase 9.0: UI Redesign — Web Prototype Match (Completed)
Rebuilt the entire SwiftUI interface to be pixel-identical to the web prototype.
- **`SplashScreenView`**: Shield logo, `STARKVEIL` title, animated sweep loader bar matching the prototype's `splash-screen`.
- **`VaultHeaderView`**: Avatar circle, `anon.stark` StarkNet ID, animated Shielded status pill badge.
- **`ShieldedBalanceCard`**: Eye-toggle reveals/blurs STRK amount + fiat label; Send (filled) and Receive (outlined) action buttons.
- **`TabSwitcherView`** / **`AssetsTabView`** / **`ActivityTabView`**: Asset rows + live Activity timeline matching prototype tab structure.
- **`BottomNavView`**: Wallet, Swap, ZK Proofs, Settings with `ultraThinMaterial` blur backdrop.
- **`STARKProofOverlay`**: Spinner + animated progress bar + monospace Cairo step log during proof generation.

### Phase 9.1: SwiftData Persistence (Completed)
- **`StoredNote`** + **`SyncCheckpoint`** SwiftData `@Model` classes persist the UTXO set and block number per `networkId`.
- `WalletManager` loads notes on cold start, writes on `addNote()`, and deletes by `networkId` on `clearStore()`.
- `SyncEngine` reads `SyncCheckpoint` on `startSyncing()` to resume from the exact last processed block.

### Phase 9.2: AES-GCM Note Decryption (Completed)
- **`KeychainManager`**: 32-byte IVK stored under `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` — no iCloud backup, no device transfer.
- **`NoteDecryptor`**: Per-note AES-256-GCM via HKDF-SHA256 subkeys (commitment as HKDF `info`). Foreign notes return `nil` silently — zero information leakage.

### Phase 9.3: FFI STARK Proving Integration (Completed)
- `StarkVeilProver.generateTransferProof()` Rust FFI fully wired into `WalletManager.executePrivateTransfer()` and `STARKProofOverlay`.
- `FFIResult` marked `Sendable` for Swift 6 nonisolated conformance.

---

### Phase 9 — Security Audit (Second Pass, Completed)
Five critical bugs identified and fixed after a second Claude CLI audit:
1. **`PersistenceController` context singleton** — computed property was creating isolated `ModelContext` instances; fixed to `let context` stored once.
2. **`clearStore()` ordering inversion** — `activeNetworkId` was set before `clearStore()` ran, deleting the wrong network's notes. Fixed ordering.
3. **`executePrivateTransfer` SwiftData sync** — spent notes only removed from memory; phantom balances appeared on relaunch. Fixed with full `ModelContext` delete + change note insert.
4. **`KeychainManager` IVK fallback** — `0xAB` repeating fallback was trivially guessable. Replaced with `precondition` crash on OS RNG failure.
5. **Checkpoint dead code** — `saveCheckpoint` / `loadCheckpoint` never called; duplicate notes emitted on every cold start. Fixed by wiring both into `tick()`'s epoch-guarded `MainActor.run`.

---

### Phase 10.1: BIP-39 Seed Phrase Wallet (Completed)
Deterministic key derivation replacing random per-device IVK.
- **`KeyDerivationEngine.swift`**: BIP-39 entropy → mnemonic → PBKDF2 seed → HMAC-SHA256 domain tag → HKDF-SHA256 separate StarkNet-compatible IVK + spending key.
- **`MnemonicSetupView`** / **`WalletImportView`**: First-launch flow for generating or restoring a seed phrase.
- IVK and SK derived deterministically — user can restore all shielded notes on a new device using only the 12-word phrase.

### Phase 10.2: Unshield Operation — Private → Public (Completed)
Complete the three-operation privacy suite with the outbound path.
- **`UnshieldFormView`**: User selects a UTXO note, enters a public recipient address, app generates an S-Two STARK proof binding `(amount, asset, recipient)` and calls `PrivacyPool.unshield()`.
- **`RPCClient`** extension: submits the invoke transaction via `starknet_addInvokeTransaction`.
- **`WalletManager`** update: `executeUnshield()` cleanly removes the spent note from memory and SwiftData.


## Core Mechanics Dictionary

- **Note (`Note`)**: The fundamental unit of shielded value. Fields: `value`, `asset_id`, `owner_ivk`, `memo`. Persisted via `StoredNote` in SwiftData, scoped by `networkId`.
- **Note Commitment**: `Poseidon(value, asset_id, owner_ivk, memo)` — written on-chain. Reveals nothing about owner, amount, or asset.
- **Nullifier**: `Poseidon(spending_key, leaf_position)` — posted on-chain when spending to mark a note as spent. Cannot be linked back to its commitment without the spending key.
- **Viewing Key (IVK)**: 32-byte read-only key derived deterministically from the user's BIP-39 master seed. Allows AES-GCM memo decryption to identify owned notes; cannot authorize spending.
- **Spending Key**: Authorizes nullifier generation and STARK proof binding. Derived deterministically from the same BIP-39 root via domain separation (HKDF `"starkveil-sk-v1"` versus `"starkveil-ivk-v1"`).
- **BIP-39 Mnemonic**: A 12 or 24-word phrase encoding the master entropy. Recovery phrase for the entire wallet. Derivation path: BIP-39 entropy → PBKDF2 seed (64 bytes stored in Keychain) → HMAC/HKDF keys.
- **NoteDecryptor**: HKDF-SHA256 derives a per-note 256-bit subkey from `(IVK, commitment)`. AES-256-GCM decrypts the event memo. Foreign notes fail authentication silently with zero side-effects.
- **SyncCheckpoint**: SwiftData record mapping `networkId → lastBlockNumber`. Enables resumable syncing across app restarts without duplicate note emission.
- **Private Transfer Proof**: STARK circuit asserting: (1) input notes exist in the Merkle tree, (2) `Σin = Σout + fee`, (3) nullifiers derive from spending keys owning the inputs.
- **Unshield Proof**: STARK circuit binding `(amount, asset, recipient)` as public inputs. Proves note ownership and unspent status, authorizes ERC-20 release to a named public recipient.
- **`ActivityEvent`**: Persistent SwiftData record of a privacy-pool operation (deposit, transfer, unshield). Outlives the UTXO set so the Activity tab retains history even after notes are spent.
- **`PersistenceController`**: SwiftData `ModelContainer` singleton. Holds a single shared `ModelContext` (not a computed property — inserts and fetches share the same context to remain visible to each other).
- **`SyncCheckpoint` ordering invariant**: On network switch — `clearStore(old)` runs first, then `activeNetworkId` is updated, then `loadNotes(new)`. This ordering is mandatory to avoid deleting the wrong network's records.

