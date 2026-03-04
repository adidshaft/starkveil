# StarkVeil: Native iOS Shielded Pool

StarkVeil is a purely native cypherpunk iOS wallet that enforces total financial privacy on Starknet. Unlike standard web3 wallets, StarkVeil removes the need for Trusted Execution Environments (TEEs) and external wallet apps. It brings Zero-Knowledge STARK proof synthesis directly onto A-series silicon via a Rust SDK, gives users a fully self-contained shielded account (no ArgentX needed), and uses an original Shielded Note commitment scheme for private transfers.

**Current status (Phase 18 Complete — End-to-End Sepolia Execution + All Phase 8 Audit Fixes):** All 8 remaining Phase 8 critical/high audit bugs resolved: RFC-6979 deterministic ECDSA signing (H-2), correct Cairo ABI encoding for shield/transfer/unshield (C-5, C-6), u256 128-bit split (C-4), recipient IVK as ownerPubkey (H-4), no plaintext fallback (M-2), confirmation-before-addNote (M-6), valid mock proof hex (H-7). V3 transactions on Starknet RPC v0.8. Wallet activation live on Sepolia. Build targets physical iOS devices only (Simulator lacks the `xcframework` arm64 simulator slice).

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
Navigate to the `prover/` directory and use the pre-configured bash script to trigger `cargo` targeting Apple ARM architecture and automatically generate the universal `StarkVeilProver.xcframework` bundle.
```bash
cd prover
./build_ios.sh
```
*This generates `/prover/target/StarkVeilProver.xcframework`.*

### 4. Run the Xcode Simulator
The Xcode project `ios/StarkVeil/StarkVeil.xcodeproj` is fully configured. It statically maps to the newly generated Rust `.xcframework`.
1. Open the project in Xcode.
2. Select **iPhone 15 Simulator** or a **Physical Device** as the target.
3. Hit **Command + R** to build and run the SwiftUI cypherpunk visual interface.

---

## ✅ Verification Guide — Reproduce All Wallet Functionality

This section lets anyone reproduce and confirm every feature of StarkVeil end-to-end. Follow the steps in order against a local Katana node or Sepolia Testnet.

### Prerequisites
```bash
# Required tools
katana --version          # Starknet Dojo (v1.7.1+)
scarb --version           # Cairo build tool (2.x)
sncast --version          # Starknet Foundry 0.50.0
cargo --version           # Rust 1.75+
xcodebuild -version       # Xcode 15+
```

---

### Step 1 · Build the Rust Prover
```bash
cd prover
./build_ios.sh
# Expected: prover/target/StarkVeilProver.xcframework exists
ls prover/target/StarkVeilProver.xcframework
```

### Step 2 · Start the Local Chain
```bash
katana --dev
# Leave running. Note the funded account addresses and private keys printed on startup.
# Default RPC: http://127.0.0.1:5050
```

### Step 3 · Deploy the PrivacyPool Contract
```bash
cd contracts && scarb build

# Import a Katana account (use keys from Step 2)
sncast account import \
  --name katana_test \
  --address <KATANA_ADDRESS> \
  --private-key <KATANA_PRIV_KEY> \
  --type open_zeppelin \
  --url http://127.0.0.1:5050

# Declare the contract class
sncast --profile katana_test declare --contract-name PrivacyPool
# → note the CLASS_HASH in the output

# Deploy via Katana UDC
sncast --profile katana_test invoke \
  --contract-address 0x41a78e741e5af2fec34b695679bc6891742439f7afb8484ecd7766661ad02bf \
  --function deployContract \
  --calldata <CLASS_HASH> 0x0 0x0 0x0
# → CONTRACT_ADDRESS is in event data[0] of the receipt
```

### Step 4 · Build & Run the iOS App
```bash
open ios/StarkVeil/StarkVeil.xcodeproj
# In Xcode: select physical iOS device or Simulator → ⌘R
```

**In the app, set the RPC URL to:** `http://127.0.0.1:5050` and contract address to the value from Step 3.

---

### Step 5 · Wallet Onboarding — Create or Import
| Checkpoint | Expected Result |
|---|---|
| Tap **Create Wallet** | 12-word BIP-39 mnemonic displayed |
| Write down the 12 words, confirm | Wallet created, proceeds to Activation |
| **Import Wallet** with same words | Recovers identical Starknet address |

### Step 6 · Account Activation (Deploy On-Chain)
| Checkpoint | Expected Result |
|---|---|
| Open `AccountActivationView` | Displays computed Starknet address (deterministic) |
| Copy address → fund it via Katana or faucet | ETH balance appears in the view |
| Tap **Activate Wallet** | Deploys OZ v0.8 account contract on-chain |
| Tap **Check Status** | `AccountActivated` state transitions to `VaultView` |

### Step 7 · Shield (Public → Private)
| Checkpoint | Expected Result |
|---|---|
| Tap **Shield** in `ShieldedBalanceCard` | Opens ShieldView with amount + memo fields |
| Enter amount + memo, tap Shield | Tx submitted; `isShielding = true` spinner shows |
| Wait 5 s (one SyncEngine poll cycle) | Note appears in balance; Activity tab shows green Deposit row |
| Toggle balance visibility (eye icon) | Amount revealed/hidden with animation |

> **On-chain verification:**
> ```bash
> sncast --profile katana_test call \
>   --contract-address <CONTRACT_ADDRESS> \
>   --function mt_next_index
> # Value increments by 1 per shield
> ```

### Step 8 · Private Transfer (Shield → Shield, No Public Trace)
| Checkpoint | Expected Result |
|---|---|
| Tap **Private Transfer** button (below action grid) | `PrivateTransferView` opens as full-screen cover |
| Enter: recipient Starknet address, their IVK hex, amount, optional memo | Fields validated live |
| Tap **Send Privately** | On-chain `Transfer` event emitted with encrypted output commitment |
| Recipient's SyncEngine polls Shielded events | Recipient trial-decrypts memo with their IVK — note appears in their balance |
| Activity tab on sender's device | Shows 🔒 Transfer row with tx hash |

> **Privacy confirmation:** Query `starknet_getEvents` for the Transfer event — you will see only opaque commitment hashes, no amounts, no addresses.

### Step 9 · Unshield (Private → Public)
| Checkpoint | Expected Result |
|---|---|
| Tap **Unshield** | `UnshieldFormView` opens |
| Enter recipient public address + amount | Validates against UTXO balance |
| Tap **Unshield** | Nullifier posted on-chain; ERC-20 transferred to recipient |
| Check on-chain nullifier registry | `is_nullifier_spent` returns `true` for that nullifier |
| Try to unshield the **same note again** | App throws `noteAlreadySpent` immediately (pre-flight check) |
| Activity tab | Shows 🔓 Unshield row |

> **On-chain verification:**
> ```bash
> sncast --profile katana_test call \
>   --contract-address <CONTRACT_ADDRESS> \
>   --function is_nullifier_spent \
>   --calldata <NULLIFIER_HEX>
> # Returns 1 (true) after a successful unshield
> ```

### Step 10 · Double-Spend Prevention
| Checkpoint | Expected Result |
|---|---|
| Shield a note, then unshield it | Succeeds ✅ |
| Attempt to unshield the same note again | App shows `noteAlreadySpent` error immediately |
| Manually craft duplicate unshield tx on-chain | Cairo contract rejects with `Note already spent` panic |

### Step 11 · Network Isolation
| Checkpoint | Expected Result |
|---|---|
| Switch from Sepolia to Mainnet in Settings | All UTXO notes clear instantly |
| Switch back to Sepolia | Sepolia notes reload from SwiftData |
| Mainnet and Sepolia notes never mix | Confirmed by `networkId` scoping in `StoredNote` |

### Step 12 · Wallet Recovery
| Checkpoint | Expected Result |
|---|---|
| Delete the app | All notes removed from device |
| Reinstall app → Import Wallet with same 12 words | Same Starknet address derived |
| Activate → VaultView | SyncEngine re-scans from block 0, trial-decrypts all shielded events, restores UTXO balance |

---

## 🔮 What's Pending (Post-Hackathon)

| Item | Priority | Notes |
|---|---|---|
| Stwo client-side ZK prover circuit | Critical | Replace mock verifier in `privacy_pool.cairo` with real on-chain Stwo verifier |
| RFC 6979 nonce for ECDSA signing | High | Replace SHA-256 deterministic k with proper RFC 6979 |
| QR code for account address | Medium | Address display in `AccountActivationView` |
| Mainnet contract deployment | Medium | Upgrade from Sepolia |
| Starknet ID integration | Low | Replace `anon.stark` placeholder |

---
- **Poseidon Zero Hashes**: For the STARK proof to cryptographically verify on iOS, the Merkle tree `get_zero_hash()` constants in `.cairo` and the Rust STARK circuits must match exactly.
- **Strict Thread Isolation**: `WalletManager.swift` utilizes explicit `@MainActor` thread-safe Combine pipelines when intercepting network toggle transitions between Mainnet and Sepolia. This rigorously guarantees UTXOs do not leak dynamically across the chain environments.

---

## Architecture

### System Overview

Three-tier trust boundary. The iPhone is the only machine that ever sees private data — no server, no TEE, no cloud.

```
┌─────────────────────────────────────────────────────────────────────┐
│                        iPhone  (A-series Silicon)                   │
│                                                                     │
│  ┌───────────────────────────────────────────────────────────────┐  │
│  │                      SwiftUI Application                      │  │
│  │                                                               │  │
│  │   VaultView ◄── ShieldedBalanceCard    PrivateSendForm        │  │
│  │       │                                                       │  │
│  │   WalletManager (@MainActor)          NetworkManager          │  │
│  │   · UTXO note cache (plaintext)       · Mainnet / Sepolia     │  │
│  │   · balance = Σ note.value            · RPC endpoint routing  │  │
│  │       │                                                       │  │
│  │   SyncEngine  (light client, RunLoop.main, 5 s poll)         │  │
│  │   · detects Shielded events via RPC                          │  │
│  │   · emits Note → WalletManager via PassthroughSubject        │  │
│  │   · networkChanged → clearStore() (MainActor.assumeIsolated) │  │
│  └────────────────────────┬──────────────────────────────────────┘  │
│                           │  C FFI  ·  JSON over c_char*            │
│  ┌────────────────────────▼──────────────────────────────────────┐  │
│  │               Rust Prover  (libstarkveil_prover.a)            │  │
│  │                                                               │  │
│  │   generate_transfer_proof(notes_json: *const c_char)         │  │
│  │   → FFIResult::Success { proof, nullifiers,                  │  │
│  │                          new_commitments, fee }              │  │
│  │                                                               │  │
│  │   free_rust_string(ptr)  ← caller frees exactly once        │  │
│  └───────────────────────────────────────────────────────────────┘  │
└────────────────────────────────┬────────────────────────────────────┘
                                 │  Starknet JSON-RPC
                                 │
              ┌──────────────────▼──────────────────────────┐
              │        Starknet  (Mainnet · Sepolia)         │
              │                                             │
              │  ┌───────────────────────────────────────┐  │
              │  │        PrivacyPool  Cairo Contract     │  │
              │  │                                       │  │
              │  │  · Poseidon Merkle tree  (depth 20)   │  │
              │  │  · Nullifier registry  (append-only)  │  │
              │  │  · Historic root archive               │  │
              │  │  · ERC-20 asset custody               │  │
              │  └───────────────────────────────────────┘  │
              └─────────────────────────────────────────────┘
```

---

### The Privacy Primitive: Notes and Commitments

Private data never leaves the device in plaintext. Assets on-chain are represented only as Poseidon hashes — an observer cannot reverse a hash to discover owner, amount, or asset.

```
                        LOCAL ONLY  (never transmitted to chain)
  ┌────────────────────────────────────────────────────────────────┐
  │  Note                                                          │
  │  ├── value:      "0.500000000"        (ETH amount, plaintext)  │
  │  ├── asset_id:   0x049D36570D4e46f…  (ERC-20 contract addr)   │
  │  ├── owner_ivk:  <incoming viewing key>  (private key)         │
  │  └── memo:       "auto-shield"                                 │
  └──────────────────────────────┬─────────────────────────────────┘
                                 │  Poseidon hash  (one-way, ZK-friendly)
                                 ▼
                   ┌─────────────────────────────┐
                   │     Note Commitment          │  ← written to chain
                   │     (public hash only)       │    reveals NOTHING
                   │     0x293d3e8a80f400da…      │    about owner or value
                   └─────────────────────────────┘

                        LOCAL + SECRET
  ┌────────────────────────────────────────────────────────────────┐
  │  Nullifier  =  Poseidon(spending_key, leaf_position)           │
  │  ├── spending_key:    <private key — never leaves device>      │
  │  └── leaf_position:  index of the note in the Merkle tree      │
  └──────────────────────────────┬─────────────────────────────────┘
                                 │  revealed only when spending
                                 ▼
                   ┌─────────────────────────────┐
                   │     Nullifier Hash           │  ← posted on-chain
                   │     (public spent signal)    │    to mark note spent
                   │     0xabc…nullifier          │    CANNOT be linked back
                   └─────────────────────────────┘    to the commitment
```

**Key unlinkability property:** an on-chain observer sees two disjoint sets — commitments (deposits) and nullifiers (spends) — but cannot determine which nullifier corresponds to which commitment without the spending key. The sets are cryptographically unlinkable.

---

### Poseidon Merkle Tree (Depth 20)

Every shielded note appends its commitment as a leaf. The root is a compact fingerprint of all shielded assets. A ZK proof demonstrates "my note is somewhere in this tree" without revealing which leaf.

```
  Depth 20  ·  max capacity: 2²⁰ = 1,048,576 notes

                            ┌────────────┐
                            │    Root    │  ← mt_root  (public, on-chain)
                            └─────┬──────┘
                           ╱             ╲
                  ┌────────┐           ┌────────┐
                  │Node[19,0]│         │Node[19,1]│
                  └───┬────┘           └────┬───┘
                     ╱ ╲                   ╱ ╲
                   …     …               …     …
                  ╱ ╲
         ┌────────┐  ┌────────┐
         │Node[1,0]│  │Node[1,1]│
         └────┬───┘  └────┬───┘
             ╱ ╲         ╱ ╲
     ┌──────┐ ┌──────┐  ┌──────┐ ┌──────┐
     │C[0]  │ │C[1]  │  │ Z[0] │ │ Z[0] │  ← empty slots use
     │Note A│ │Note B│  │(zero)│ │(zero)│    pre-computed zero hashes
     └──────┘ └──────┘  └──────┘ └──────┘    so the root is always valid

  Zero hash chain  (Poseidon-derived, byte-identical in Cairo and Rust):
    Z[0]  = 0x0
    Z[1]  = Poseidon(Z[0], Z[0])  =  0x293d3e8a80f400da…
    Z[2]  = Poseidon(Z[1], Z[1])  =  0x296ec483967ad3fb…
    …
    Z[20] = Poseidon(Z[19],Z[19]) =  0x2dbdbece8787cd76…  ← root when empty

  Leaf insert cost: O(20) Poseidon hashes
  Sibling bound:    nodes_at_level = ⌈leaf_count / 2^level⌉  (level-aware)
```

---

### Operation 1 — Shield  (Public → Private)

Locks a public ERC-20 balance into the pool. The contract receives only a hash — it never learns the note's owner or internal fields.

```
  User wallet                              PrivacyPool contract
      │                                           │
      │  Compute note commitment locally:         │
      │  c = Poseidon(value, asset, ivk, memo)    │
      │  (done on-device, never sent in plain)    │
      │                                           │
      │─── ERC20.approve(pool, amount) ──────────▶│
      │                                           │
      │─── shield(asset, amount, c) ─────────────▶│
      │                                           │
      │                              ERC20.transfer_from(caller → pool)
      │                              assets locked in contract custody
      │                                           │
      │                              insert_leaf(c) into Merkle tree
      │                              mt_root updated
      │                              historic_roots[root] = true
      │                                           │
      │                              emit Shielded {
      │                                asset    ← token address  (public)
      │                                amount   ← deposit size   (public)
      │                                commitment: c  ← opaque hash
      │                                leaf_index     ← position only
      │                              }
      │
      │  SyncEngine detects Shielded event via 5 s RPC poll
      │  Reconstructs Note from local key material
      │  WalletManager.addNote(note) → balance display updates

  ┌─────────────────────────────────┬──────────────────────────────┐
  │  Visible on-chain               │  Hidden from all observers   │
  ├─────────────────────────────────┼──────────────────────────────┤
  │  Asset type, deposit amount     │  Depositor identity          │
  │  Opaque commitment hash         │  Note plaintext fields       │
  │  Leaf position in tree          │  Spending key                │
  └─────────────────────────────────┴──────────────────────────────┘
```

---

### Operation 2 — Private Transfer  (Private → Private)

The core privacy operation. No amounts, sender, or recipient appear on-chain. The contract only learns that some notes were spent and new ones were created.

```
  iPhone  (all computation off-chain)             PrivacyPool contract
          │                                               │
          │  UTXO selection: greedy pick from             │
          │  WalletManager.notes until Σvalue ≥ amount    │
          │                                               │
          │  ┌────────────────────────────────────────┐   │
          │  │       Rust Prover  (on-device)         │   │
          │  │                                        │   │
          │  │  For each input note:                  │   │
          │  │    nf = Poseidon(spending_key, pos)    │   │
          │  │                                        │   │
          │  │  For each output note:                 │   │
          │  │    c_out = Poseidon(val,asset,ivk,m)  │   │
          │  │                                        │   │
          │  │  STARK proof asserts:                  │   │
          │  │    · input notes exist in Merkle tree  │   │
          │  │    · Σ(input) = Σ(output) + fee        │   │
          │  │    · nullifiers derive from spending   │   │
          │  │      keys that own the input notes     │   │
          │  └─────────────────┬──────────────────────┘   │
          │                   │  FFI  (JSON over c_char*)  │
          │  FFIResult::Success { proof[], nullifiers[],   │
          │      new_commitments[], fee }                  │
          │                                               │
          │─── private_transfer(proof, nullifiers, ───────▶│
          │        new_commitments, fee)                   │
          │                                               │
          │                         verify_proof(proof, public_inputs)
          │                         public_inputs = [ mt_root,
          │                             nullifier_0, …, commitment_0, … ]
          │                                               │
          │                         for each nullifier:
          │                           assert !nullifiers[nf]  ← no double-spend
          │                           nullifiers[nf] = true
          │                                               │
          │                         for each new_commitment:
          │                           insert_leaf(commitment)
          │                                               │
          │                         emit Transfer {
          │                           new_commitments  ← opaque hashes only
          │                           fee              ← amount only
          │                         }

  ┌─────────────────────────────────┬──────────────────────────────┐
  │  Visible on-chain               │  Hidden from all observers   │
  ├─────────────────────────────────┼──────────────────────────────┤
  │  N nullifiers (spent signals)   │  Sender identity             │
  │  M new opaque commitments       │  Recipient identity          │
  │  STARK proof blob               │  Transfer amount             │
  │  Fee amount                     │  Asset type                  │
  └─────────────────────────────────┴──────────────────────────────┘
```

---

### Operation 3 — Unshield  (Private → Public)

Converts a shielded note back to a public ERC-20 balance. The recipient and amount become public inputs to the proof — the ZK circuit commits to exactly who receives what, preventing substitution after proof generation.

```
  iPhone  (all computation off-chain)             PrivacyPool contract
          │                                               │
          │  Select note to redeem                        │
          │  nf = Poseidon(spending_key, leaf_pos)        │
          │                                               │
          │  STARK proof binds:                           │
          │    · amount, asset, recipient  (all public)   │
          │    · note exists in a historic Merkle root    │
          │    · spending key ownership of the note       │
          │                                               │
          │─── unshield(proof, nullifier, ────────────────▶│
          │        recipient, amount, asset)              │
          │                                               │
          │                         verify_proof(proof, public_inputs)
          │                         public_inputs = [ amount.low,
          │                             amount.high, recipient, asset ]
          │                         (all four bound — swapping any one
          │                          invalidates the proof)
          │                                               │
          │                         assert !nullifiers[nf]
          │                         nullifiers[nf] = true
          │                                               │
          │                         ERC20.transfer(recipient, amount)
          │                         assets released from custody
          │                                               │
          │                         emit Unshielded {
          │                           recipient, amount, asset  ← public
          │                           nullifier                 ← spent signal
          │                         }

  ┌─────────────────────────────────┬──────────────────────────────┐
  │  Visible on-chain               │  Hidden from all observers   │
  ├─────────────────────────────────┼──────────────────────────────┤
  │  Recipient address              │  Which shielded note redeemed│
  │  Amount and asset type          │  Original depositor identity │
  │  Nullifier (spent signal)       │  Full deposit history        │
  └─────────────────────────────────┴──────────────────────────────┘
```

---

### Security Model

| Property | Mechanism | Guarantee |
|---|---|---|
| **Owner unlinkability** | `commitment = Poseidon(value, asset, ivk, memo)` | On-chain data reveals no identity |
| **Spend unlinkability** | `nullifier = Poseidon(spending_key, leaf_pos)` | Nullifier cannot be correlated to its commitment |
| **Double-spend prevention** | `nullifiers: Map<felt252, bool>` — append-only | Each nullifier accepted exactly once |
| **Membership proof** | Poseidon Merkle root + ZK Merkle witness | Proves note exists without revealing which leaf |
| **Proof commitment** | Public inputs include all output values | Proof cannot be replayed for different amounts or recipients |
| **Historic roots** | `historic_roots: Map<felt252, bool>` | Client can prove against a root older than chain tip |
| **Balance conservation** | ZK circuit: `Σin = Σout + fee` | No shielded balance inflation possible |
| **Tree capacity guard** | `assert(leaf_count < 1_048_576)` | Tree cannot overflow and cause silent data loss |
| **Thread isolation** | `WalletManager: @MainActor`, `dispatchPrecondition` | UTXO mutations are race-condition-free |
| **Network UTXO isolation** | `clearStore()` via `MainActor.assumeIsolated` on `networkChanged` | Mainnet notes never contaminate Sepolia view |
| **Persisted UTXO isolation** | `StoredNote` scoped by `networkId` in SwiftData | Notes survive app restarts without cross-network leakage |
| **clearStore ordering** | `clearStore(old)` → `activeNetworkId = new` → `loadNotes(new)` | Strict ordering prevents deleting wrong network's records |
| **IVK key protection** | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | No iCloud backup; no device transfer; no background access |
| **Per-note key separation** | HKDF-SHA256 with commitment as `info` param | Compromise of one memo key cannot attack any other note |
| **Foreign note rejection** | AES-GCM authentication tag mismatch → `nil` returned silently | Other users' notes leave zero trace in local state |
| **IVK recoverability** | BIP-39 mnemonic → PBKDF2 → HMAC/HKDF derivation | IVK reconstruction from recovery phrase on any new device |
| **Unshield commitment** | Proof binds `(amount, asset, recipient)` as public inputs | Proof cannot redirect funds to a different recipient after generation |
| **No server trust** | Rust prover statically linked into app binary | Proof generated entirely on-device |
| **No TEE dependency** | A-series silicon + Rust STARK circuits | Privacy does not rely on Intel SGX or any cloud enclave |

---

## Full-Stack Security & Privacy Assessment

_Completed across 7 audit passes (Phases 4–16). Last updated: Phase 16._

### Layer 1 — Key Material & Derivation

| Property | Mechanism | Status |
|---|---|---|
| Master seed Keychain storage | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, no iCloud backup | ✅ |
| Mnemonic memory wipe | Zeroed after PBKDF2 derivation, never stored to disk | ✅ |
| IVK / SK domain separation | HKDF info: `starkveil-ivk-v1` vs `starkveil-sk-v1` | ✅ |
| STARK private key distribution | `grindKey` rejection-sampling — uniform over `[1, order)` | ✅ Phase 5 |
| STARK public key | Real EC scalar multiply via `starknet-crypto::get_public_key` | ✅ Phase 12 |
| Account address | Real Cairo Pedersen hash (shift-point constants), correct length suffix | ✅ Phase 12 |
| Wallet reset | `deleteWallet` wipes `masterSeed`, `accountAddress`, `accountDeployed` atomically | ✅ |
| IVK derivation from spending key | `stark_derive_ivk` via Poseidon FFI | ✅ Phase 15 |

### Layer 2 — Cryptographic Primitives

| Property | Mechanism | Status |
|---|---|---|
| Pedersen hash | `starknet-crypto::pedersen_hash` (not SHA-256) | ✅ Phase 12 |
| Poseidon hash | `starknet-crypto::poseidon_hash_many` (matches Cairo contract) | ✅ Phase 12 |
| ECDSA signing | `starknet-crypto::sign` with deterministic k | ✅ Phase 12 |
| AES-GCM memo encryption | HKDF-SHA256 + AES-256-GCM, random 96-bit nonce via CryptoKit | ✅ Phase 15 |
| Note commitment | Real `Poseidon(value, asset, pubkey, nonce)` via Rust FFI | ✅ Phase 15 |
| Nullifier | Real `Poseidon(commitment, spending_key)` via Rust FFI | ✅ Phase 15 |
| IVK encryption key | HKDF-SHA256 from IVK bytes, info=`note-enc-v1` | ✅ Phase 15 |
| Transfer selector | `starknet_keccak("transfer")` Keccak-250 | ✅ Phase 16 |
| is_nullifier_spent selector | `starknet_keccak("is_nullifier_spent")` Keccak-250 | ✅ Phase 16 |

### Layer 3 — UTXO Integrity

| Property | Mechanism | Status |
|---|---|---|
| Phantom balance prevention | Zero-amount events dropped at SyncEngine | ✅ Phase 4 |
| Duplicate UTXO prevention | `addNote` deduplication by note fields | ✅ Phase 4 |
| Shield amount correctness | High/low u128 split for values > 18.44 STRK | ✅ Phase 4 |
| ETH balance parse | Reads both `[low_u128, high_u128]` words | ✅ Phase 5 |
| Deterministic nonce | `Poseidon(IVK, value, asset)` — consistent across shield/sync/unshield | ✅ Phase 16 |
| Pending-spend state | `isPendingSpend = true` before tx; reverts to false on failure | ✅ Phase 16 |
| Double-spend pre-flight | `isNullifierSpent()` RPC check before proof generation | ✅ Phase 15 |
| Nullifier check order | Checked before `generateTransferProof` (not after) | ✅ Phase 16 |

### Layer 4 — App & Session Security

| Property | Mechanism | Status |
|---|---|---|
| Biometric gate | Face ID / Touch ID via `LAContext` | ✅ |
| Auto-lock on backgrounding | `scenePhase == .background` re-arms lock | ✅ Phase 4 |
| Dynamic biometry icon | Detects Face ID vs Touch ID at runtime | ✅ Phase 4 |
| No-passcode fallback | User-facing error when no passcode is enrolled | ✅ Phase 4 |
| Task cancellation handling | Deploy poll catches `CancellationError`, persists confirmed state | ✅ Phase 5 |

### Layer 5 — Transaction Safety

| Property | Mechanism | Status |
|---|---|---|
| Deploy account signature | Real STARK ECDSA via `stark_sign_transaction` FFI | ✅ Phase 12 |
| Invoke transaction signature | Real STARK ECDSA | ✅ Phase 12 |
| Chain nonce | `starknet_getNonce` before every tx | ✅ Phase 13 |
| V3 tx format | All transactions use version `0x3` with `resource_bounds` | ✅ Phase 17 |
| V3 tx hash | Poseidon over `(tip, l1_gas_bounds, l2_gas_bounds, l1_data_gas_bounds)` per spec | ✅ Phase 17 |
| Resource bound encoding | `resource_name(60-bit) \| max_amount(64-bit) \| max_price(128-bit)` per felt252 | ✅ Phase 17 |
| Fee estimation | `starknet_estimateFee` with per-resource-type parsing (`l1_gas_consumed`, `l2_gas_consumed`, `l1_data_gas_consumed`) | ✅ Phase 17 |
| Wallet activation (Sepolia) | `DEPLOY_ACCOUNT` V3 successfully broadcast and confirmed on Sepolia | ✅ Phase 17 |

### Layer 6 — Privacy Properties

| Property | Mechanism | Status |
|---|---|---|
| Sender/recipient hiding | Shielded note model — only commitment + encrypted memo on-chain | ✅ |
| Amount hiding | Amount inside AES-256-GCM encrypted memo (IVK-keyed) | ✅ Phase 15 |
| Recipient privacy | Requires recipient's actual IVK — cannot be derived from address alone | ✅ Phase 16 |
| Network isolation | Direct Starknet RPC — no analytics relay | ✅ |
| IVK trial-decryption | SyncEngine: decrypt with own IVK once per batch (O(1) per block) | ✅ Phase 16 |
| UTF-8 fallback for memos | Non-UTF8 decrypted data shown as hex, not dropped | ✅ Phase 16 |
| Encrypted memo on Shielded event | Cairo emits `encrypted_memo: felt252` for trial-decryption | ✅ Phase 16 |
| Mock verifier (demo) | `verify_proof` returns `true`; Stwo integration pending post-hackathon | ⚠️ Demo only |

