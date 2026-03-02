# StarkVeil: Native iOS Shielded Pool

StarkVeil is a purely native cypherpunk iOS wallet that enforces total financial privacy on Starknet via a Zcash-style UTXO model. Unlike standard web3 wallets, StarkVeil removes the need for Trusted Execution Environments (TEEs), bringing Zero-Knowledge STARK proof synthesis directly to the `A`-series silicon inside the iPhone via a Rust SDK bridging layer.

**Current status (Phase 9 — Production Ready):** Full Starknet JSON-RPC sync engine, SwiftData UTXO persistence, AES-GCM note decryption via CryptoKit, and live FFI STARK proof generation on-device. The iOS UI precisely matches the `StarkVeil_UI_Prototype` web reference.

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

## Technical Edge Cases
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
| **IVK key protection** | `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` | No iCloud backup; no device transfer; no background access |
| **Per-note key separation** | HKDF-SHA256 with commitment as `info` param | Compromise of one memo key cannot attack any other note |
| **Foreign note rejection** | AES-GCM authentication tag mismatch → `nil` returned silently | Other users' notes leave zero trace in local state |
| **No server trust** | Rust prover statically linked into app binary | Proof generated entirely on-device |
| **No TEE dependency** | A-series silicon + Rust STARK circuits | Privacy does not rely on Intel SGX or any cloud enclave |
