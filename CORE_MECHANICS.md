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


### Phase 10.3: Activity Feed (Completed)
- **`ActivityEvent`**: Persistent SwiftData record for deposit, transfer, and unshield operations. Rendered in `ActivityTabView` with colour-coded icons.

---

### Phase 11: Starknet Account Abstraction (Completed)
- **`StarknetAccount.swift`**: HKDF-derived STARK keypair, real EC public key, OZ v0.8 counterfactual address via chained Pedersen hash.
- **3-State App Flow**: Onboarding → AccountActivation → Vault, all persisted in Keychain.

### Phases 12–13: Real Starknet Cryptography (Completed)
Replaced all SHA-256 placeholder cryptography with real Rust FFI exports:
- `stark_pubkey`: EC scalar multiply on the STARK curve.
- `stark_compute_address`: Chained Pedersen hash for OZ v0.8 address formula.
- `stark_sign_transaction`: STARK ECDSA with deterministic `k`.
- `starknet_getNonce` + `starknet_estimateMessageFee` wired into all transaction flows.

### Phase 14: Fee Estimation (Completed)
- `RPCClient.estimateInvokeFee`: `starknet_estimateMessageFee` with 1.5× multiplier, falls back to 0.01 ETH on RPC error.

### Phase 15: Full Privacy Implementation (Completed)
The core privacy layer — without this, commitments and nullifiers were fake:
- **`note_commitment`**: Real `Poseidon(value, asset, owner_pubkey, nonce)` via Rust FFI.
- **`note_nullifier`**: Real `Poseidon(commitment, spending_key)` via Rust FFI.
- **`derive_ivk`**: `Poseidon(spending_key, domain)` — IVK is a proper Starknet felt252.
- **`NoteEncryption.swift`**: HKDF-SHA256 + AES-256-GCM encrypted memos keyed by IVK. `encryptMemo` / `decryptMemo` / `computeCommitment` / `computeNullifier`.
- **`isNullifierSpent` (RPCClient)**: `starknet_call` on `is_nullifier_spent` selector before proof generation.
- **SyncEngine IVK trial-decryption**: IVK derived once per batch outside the event loop. Notes that fail AES-GCM authentication are silently dropped (belong to other wallets).
- **`PrivateTransferView`**: Full-screen cover UI for shield-to-shield private transfers. Requires recipient's Starknet address and their IVK hex.

### Phase 16: Audit Hardening (Completed)
Resolved 2C + 4H + 5M audit vulnerabilities:
- **Deterministic nonces**: `Poseidon(IVK, value, asset)` — consistent across shield, SyncEngine decoding, and unshield. Eliminates nonce mismatch.
- **Pending-spend rollback**: `defer { isPendingSpend = false }` on failure in both `executeUnshield` and `executePrivateTransfer`.
- **Nullifier check order**: `isNullifierSpent` moved before `generateTransferProof` (H-NULLIFIER-ORDER).
- **Correct Keccak-250 selectors**: `transfer` and `is_nullifier_spent` now use real `starknet_keccak` values.
- **IVK loop optimization**: Derived once per SyncEngine batch, not per-event.
- **Recipient IVK required**: `PrivateTransferView` asks for the recipient's real IVK instead of deriving from their public address.
- **Cairo `Shielded` event**: Now emits `encrypted_memo: felt252` field at `data[5]` for SyncEngine trial-decryption.
- **Mock verifier**: `verify_proof` returns `true` (documented, intentional for demo). Stwo client-side proving circuit is the next milestone.

---

## Core Mechanics Dictionary

- **Note (`Note`)**: The fundamental unit of shielded value. Fields: `value`, `asset_id`, `owner_ivk`, `memo`. Persisted via `StoredNote` in SwiftData, scoped by `networkId`.
- **Note Commitment**: `Poseidon(value, asset_id, owner_pubkey, nonce)` via Rust FFI — written on-chain. Reveals nothing about the actual owner, amount, or asset.
- **Nullifier**: `Poseidon(commitment, spending_key)` via Rust FFI — posted on-chain when spending to mark a note as spent. Cannot be linked back to its commitment without the spending key.
- **Viewing Key (IVK)**: felt252 derived via `Poseidon(spending_key, domain)`. Allows AES-GCM memo decryption to identify owned notes; cannot authorize spending. Safe to share with watch-only wallets.
- **Spending Key**: Authorizes nullifier generation and STARK proof binding. Derived deterministically from the BIP-39 root via HKDF `"starkveil-sk-v1"`.
- **STARK Keypair**: Private key = HKDF(chainRoot, `"starkveil-stark-pk-v1"`) clamped to STARK curve order. Public key = real `private_key * G` via `stark_pubkey` FFI. Both deterministic from seed.
- **OZ Account Address**: `compute_address(class_hash, salt=pubkey, calldata=[pubkey], deployer=0x0)` using chained Pedersen hashes via FFI. Fully recoverable from the BIP-39 mnemonic.
- **Counterfactual Address**: Computed account address exists and can receive funds before the account contract is deployed.
- **BIP-39 Mnemonic**: 12-word phrase encoding master entropy. Derivation: entropy → PBKDF2 seed (64 bytes, stored in Keychain) → HMAC/HKDF keys.
- **NoteEncryption**: `encryptionKey = HKDF-SHA256(IVK_bytes, info="note-enc-v1")`. Memo encrypted with `AES-256-GCM`. Recipient trial-decrypts every Shielded event — GCM auth failure means Note belongs to someone else.
- **Deterministic Nonce**: `Poseidon(IVK, value, asset)` — used consistently in `executeShield`, SyncEngine, `executeUnshield`, and `executePrivateTransfer` to ensure commitment reconstruction always succeeds.
- **Pending-Spend State**: `StoredNote.isPendingSpend = true` is set before submitting an unshield/transfer tx. A `defer` block resets it to `false` if the tx fails, preventing permanently locked notes.
- **isNullifierSpent**: RPC call (`starknet_call` → `is_nullifier_spent` selector) performed before proof generation. Fail-open (returns false on RPC error); the Cairo contract is the authoritative guard.
- **IVK Trial-Decryption**: SyncEngine derives IVK once per block (outside the event loop) and attempts `NoteEncryption.decryptMemo` on every `Shielded` event. Notes that authenticate belong to this wallet; others are silently dropped.
- **PrivateTransferView**: Shield-to-shield private transfer UI. Requires the recipient's Starknet address AND their IVK hex. Encrypts the memo with the recipient's IVK so their SyncEngine can trial-decrypt it.
- **Mock Verifier**: `verify_proof` in `privacy_pool.cairo` returns `true` for all proofs. Documented as intentional for the demo — enables the full demo flow without a client-side ZK prover circuit. Stwo integration replaces this post-hackathon.
- **SyncCheckpoint**: SwiftData record mapping `networkId → lastBlockNumber`. Enables resumable syncing without duplicate note emission.
- **Private Transfer Proof**: STARK circuit asserting (1) input notes exist in the Merkle tree, (2) `Σin = Σout + fee`, (3) nullifiers derive from spending keys owning the inputs. Currently mock — real Stwo proving circuit pending.
- **Unshield Proof**: STARK circuit binding `(amount, asset, recipient)` as public inputs. Currently mock — same Stwo circuit pending.
- **`ActivityEvent`**: Persistent SwiftData record of a privacy-pool operation (deposit, transfer, unshield). Outlives the UTXO set so history is retained after notes are spent.
- **`PersistenceController`**: SwiftData `ModelContainer` singleton with a single shared `ModelContext` — inserts and fetches share the same context.
- **3-State App Flow**: `Onboarding` (no seed) → `AccountActivation` (seed exists, account not deployed) → `Vault` (full operation). Each state is persisted in Keychain and survives reinstall.
- **ResourceBoundsMapping**: V3 transaction fee structure with three gas markets: `l1_gas` (L2→L1 messages), `l2_gas` (execution computation, dominant cost), `l1_data_gas` (state diff blob posting). Each has `max_amount` (u64) and `max_price_per_unit` (u128).
- **V3 Resource Bound Encoding**: Each bound encoded as a 252-bit felt252: `resource_name(60 bits) | max_amount(64 bits) | max_price_per_unit(128 bits)`. Resource names: `L1_GAS=0x4c315f474153`, `L2_GAS=0x4c325f474153`, `L1_DATA=0x4c315f44415441`.
- **V3 Gas Hash**: `Poseidon(tip, l1_gas_bound, l2_gas_bound, l1_data_gas_bound)` — tip is the first element inside this hash, not a separate field in the outer hash.

---

### Phase 17: V3 Transaction Migration — Starknet RPC v0.8 (Completed)

Starknet Sepolia deprecated V1 transactions (error code 61: "version not supported"). Full migration to V3 was required for `DEPLOY_ACCOUNT`, `INVOKE`, and `starknet_estimateFee`.

**What changed:**

| V1 (deprecated) | V3 (current) |
|---|---|
| `max_fee: String` (ETH wei) | `resource_bounds: {l1_gas, l2_gas, l1_data_gas}` (STRK fri) |
| `version: "0x1"` | `version: "0x3"` |
| Pedersen tx hash | Poseidon tx hash |
| No extra fields | `tip`, `paymaster_data`, `nonce_data_availability_mode`, `fee_data_availability_mode` |

**Debug journey — errors resolved in sequence:**

1. **RPC error 61** — "version not supported": root cause was `version: "0x1"` on the transaction. Fixed by migrating all transaction structs to V3.

2. **RPC error -32602 (invalid params)** — first instance: params were being sent as a named object `{"deploy_account_transaction": {...}}` instead of a positional array `[{...}]`. Fixed.

3. **RPC error -32602 (invalid params)** — second instance (`"missing field: l1_data_gas"`): the `ResourceBoundsMapping` struct only had `l1_gas` + `l2_gas`. Starknet RPC v0.8 requires all three gas markets. Added `l1_data_gas: ResourceBound` to the struct and all construction sites.

4. **RPC error 53** — "resources don't cover fee": the `FeeEstimateV3` decoder was reading fields `gas_consumed` / `gas_price` which don't exist in the v0.8 response. The actual fields are `l1_gas_consumed`, `l2_gas_consumed`, `l1_data_gas_consumed` plus corresponding `_price` fields. Because parsing always returned nil, the fallback was used (`l2_gas: 0x0`) — but the deploy actually needed `l2_gas_consumed: 0xb1600` (726k units). Fixed by rewriting `FeeEstimateV3` to decode correct field names and build per-resource-type bounds with a 1.5× multiplier.

5. **Hash mismatch (signature failure)**: The V3 Poseidon hash computation had two bugs versus the official spec:
   - `tip` was placed **outside** the gas hash; spec requires it **inside**: `Poseidon(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds)`
   - Resource bound felt252 encoding was missing the 60-bit resource name prefix per the spec: `resource_name(60) | max_amount(64) | max_price(128)`

**Files modified:**
- `RPCClient.swift`: New `ResourceBoundsMapping` (3 gas types), V3 structs for all tx types, corrected `FeeEstimateV3` decoder, RPC fallback with 15s timeout
- `StarknetTransactionBuilder.swift`: V3 Poseidon hash for INVOKE and DEPLOY_ACCOUNT with correct resource encoding and tip placement
- `WalletManager.swift`: All 3 invoke call sites migrated from `maxFee` → `resourceBounds`
- `AccountActivationView.swift`: Deploy flow uses V3 resource bounds end-to-end

**Outcome**: Wallet activation (`DEPLOY_ACCOUNT` V3) successfully broadcast and confirmed on Starknet Sepolia testnet.

---

### Phase 18: End-to-End Audit Fix Sweep (Completed)

Resolved all remaining Phase 8 critical/high/medium bugs to make Shield, Private Transfer, and Unshield execute correctly on Sepolia.

| Bug ID | Fix |
|---|---|
| **H-2** | RFC-6979 deterministic ECDSA nonces — `k` now derived inside Rust via `rfc6979` crate. Swift no longer supplies `k`. Eliminates nonce-reuse private key extraction. |
| **H-7** | Removed underscore from mock proof hex `0x504c414345484f4c444552_50524f4f46` → `0x504c414345484f4c444552`. |
| **C-4** | u256 split uses `Decimal` arithmetic at the 2^128 boundary (was 2^64). Affects all amount conversions. |
| **C-5** | Shield calldata now sends 5 args matching Cairo `shield(asset, amount_low, amount_high, note_commitment, encrypted_memo)`. Was sending 3. |
| **C-6** | Private transfer calldata now encodes `Array<felt252>` with length prefixes: `[len, ...elements]` for proof, nullifiers, new_commitments, plus u256 fee. |
| **H-4** | Recipient's IVK used as `ownerPubkey` in output commitment (was using account address ≠ EC pubkey → unspendable notes). |
| **M-2** | Encryption failure in private transfer now throws (was falling back to plaintext hex on-chain). |
| **M-6** | `executeShield` polls `starknet_getTransactionReceipt` before `addNote()` — no more phantom notes on revert. |

**Files modified:** `lib.rs`, `Cargo.toml`, `starkveil_prover.h`, `StarkVeilProver.swift`, `WalletManager.swift`, `StoredNote.swift`, `SyncEngine.swift`.

---

### Phase 20: Live Sepolia Deployment & Core Bug Fixes (Completed)

Deployed PrivacyPool to Starknet Sepolia and resolved 4 production bugs discovered during end-to-end testing.

#### Deployed Contract (Sepolia)

| | |
|---|---|
| **Contract address** | `0x20768453fb80c8958fdf9ceefa7f5af63db232fe2b8e9e36ead825301c4de74` |
| **Class hash** | `0x6d5bfe6fe2243398e0edad308bd54d5c74b8e7e4944fda952170505818a18de` |
| **RPC (primary)** | `https://api.cartridge.gg/x/starknet/sepolia` — Cartridge, JSON-RPC v0.9.0 |
| **RPC (fallback)** | `https://rpc.starknet-testnet.lava.build` — Lava, v0.8.1 |
| **Deployed via** | `deploy_contract.js` — starknet.js v9 programmatic deploy (sncast/starkli were incompatible with v0.9.0) |

**Entry points (computed from deployed ABI):**

| Function | Selector |
|---|---|
| `shield` | `0x1d142bf165333b22247aed261a8174bd8ba65a3f9b25570d99a8b8f2c32e3ba` |
| `private_transfer` | `0x2605e7681cf37ab3a81d1732a9c8a75f2544c5967628a4d6999f276c6ba513c` |
| `unshield` | `0x3079978d9c0e08ca0a86356d70a7eea2408b5d3882425b2f30a60818eac5b1b` |

#### Bug Fixes

| Bug | Root Cause | Fix |
|---|---|---|
| **Shielded balance shows raw wei** | `recomputeBalance()` summed `Double(note.value)` directly. Notes store value as raw wei (e.g. `100000000000000000` = 0.1 STRK). | Divide by `1e18` in `recomputeBalance()`. |
| **Activity log shows raw wei** | `addNote()` passed `note.value` (raw wei string) to `logEvent()`. | Convert wei → STRK before logging. |
| **Unshield RPC Error 41** | The multicall `calldata_len` was set before the full payload was assembled, so the sequencer read the wrong number of args. | Build the complete `callPayload` first, then derive `calldata_len = callPayload.count`. |
| **Private transfer felt252 overflow** | `spendingKeyHex = keys.privateKey.hexString` is a raw 32-byte value; top bits may exceed the STARK field prime, making it an invalid felt252. | `clampToFelt252()` helper masks the top 3 bits of the MSB (`bytes[0] &= 0x07`) before use in Poseidon hashes. Privacy-preserving: clamping does not weaken the key, it only ensures field validity. |

#### Note Value Format
- Notes are **stored** with `value` as a raw wei decimal string (e.g. `"100000000000000000"`).
- `recomputeBalance()` divides by `1e18` so `WalletManager.balance` is always in **STRK**.
- The activity log and UI both display STRK amounts.

#### Felt252 Clamping Rule
The STARK field prime is `P = 2^251 + 17·2^192 + 1` (slightly less than `2^252`). Any 32-byte private key whose top 3 bits are non-zero overflows `P`. The `clampToFelt252` helper (static on `WalletManager`) masks those bits, guaranteeing the value is in-range for Cairo felt252. This matches the clamping Cairo/starknet-rs apply internally. Applied to `spendingKeyHex` whenever it is used as a felt252 argument in FFI calls.

#### UI Improvements
- **Shield/Unshield success banner**: tx hash is now a tappable `Link` opening `https://sepolia.voyager.online/tx/<hash>` so users can independently verify on-chain.
- **ReceiveView — Shielded QR**: labelled *"Shielded Address — for private receives"* above the QR image.
- **ReceiveView — Public address card**: labelled *"Public Address (U) — for exchanges & public sends"* with copy-with-checkmark feedback.

**Files modified:** `NetworkEnvironment.swift`, `WalletManager.swift`, `ShieldView.swift`, `ReceiveView.swift`, `Scarb.toml`.

---

### Phase 21: Real Circle STARK Prover & Verifier (Stwo / M31) (Completed)

Replaced the structural "mock" STARK verifier with a production-grade Circle STARK proving system built on the `stwo` framework.

#### 1. Rust Stwo Prover (`prover/src/stark/`)
The client-side iOS SDK now synthesizes real STARK proofs locally using the `M31` (base) and `QM31` (complex quad) prime fields.
- **Trace Layout**: 68 `M31` columns encoding Poseidon hash I/O limbs, Merkle direction bits, step types, and public value bindings.
- **Circle FRI**: Twin-point folding formula `f_fold(x) = (f(P)+f(P'))/2 + α·(f(P)-f(P'))/(2y)`. Perfect power of 2 (order `p+1 = 2^31`) means no root-of-unity search is required.
- **AIR Constraints**: Enforces `commitment = Poseidon(value, asset, owner, nonce)`, `nullifier = Poseidon(commitment, key)`, Merkle authentication, and `Σin = Σout + fee`.

#### 2. Cairo 1.x Verifier (`contracts/src/stwo_verifier.cairo`)
A complete, optimized Cairo smart contract replacing the `verify_proof` hackathon mock.
- **Fiat-Shamir Transcript**: Reconstructs the Poseidon sponge identical to the prover.
- **FRI Verification**: Checks layer commitments, derives query indices, and validates Merkle decommitments for each FRI layer.
- **Poseidon Oracle**: Spot-checks random execution traces against the claimed hash inputs.

**Outcome**: The `PrivacyPool` contract now cryptographically verifies true zero-knowledge proofs on Sepolia, guaranteeing balance conservation and mathematical ownership for all Private Transfers and Unshields.
