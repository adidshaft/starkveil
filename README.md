# StarkVeil: Native iOS Shielded Pool

StarkVeil is a purely native cypherpunk iOS wallet that enforces total financial privacy on Starknet. Unlike standard web3 wallets, StarkVeil removes the need for Trusted Execution Environments (TEEs) and external wallet apps. It brings Zero-Knowledge STARK proof synthesis directly onto A-series silicon via a Rust SDK, gives users a fully self-contained shielded account (no ArgentX needed), and uses an original Shielded Note commitment scheme for private transfers.

**Current status (Phase 21 — Live on Sepolia):** PrivacyPool contract deployed on Starknet Sepolia testnet. Full U↔S cycle functional: shield, unshield, private transfer and shielded-to-shielded sends all work end-to-end. Wallet uses a clean U/S model inspired by Zashi. Total balance card shows U+S inline breakdown. 3 action buttons: Send, Receive, Shield. Unified Send auto-detects `svk:` prefix for private transfers vs `0x` for public sends. Shield/Unshield is a single toggle view. Receive shows two clearly labelled addresses: S (`svk:0x…` — for private receives) and U (`0x…` — for exchanges). 4-tab nav: Wallet | Swap | Activity | Settings. **Phase 21:** Activity feed now correctly shows `+`/`−` prefixes and green/red/amber colours for all 5 event kinds (deposit, receive, private send, unshield, public send). Activity tab is fully scrollable from the bottom nav. All views use a consistent glassmorphic design (frosted cards, purple glow borders, green/red accent icons). **QR Scanner:** No reinstall required — grant camera permission once in iOS Settings → Privacy → Camera.

## Project Structure
- **`contracts/`**: The Cairo smart contract that handles the appending of the UTXO Poseidon hashes and validates STARK nullifier proofs to prevent double-spending.
- **`prover/`**: A standard Rust Cargo library that compiles to static binaries (`libstarkveil_prover.a`) leveraging FFI `C` strings to pass Proofs to Swift.
- **`ios/StarkVeil/`**: The native Apple SwiftUI application interface. Handles `@MainActor` thread-safe background light-client syncing, unspent note caching, and premium glassmorphic visual interactions.

---

## 🚀 How to Run on Starknet Sepolia (Testnet)

The PrivacyPool contract is **already deployed** on Sepolia. No local node required.

### Deployed Contract
| | |
|---|---|
| **Network** | Starknet Sepolia |
| **Contract address** | `0x20768453fb80c8958fdf9ceefa7f5af63db232fe2b8e9e36ead825301c4de74` |
| **Class hash** | `0x6d5bfe6fe2243398e0edad308bd54d5c74b8e7e4944fda952170505818a18de` |
| **RPC (primary)** | `https://api.cartridge.gg/x/starknet/sepolia` (Cartridge, v0.9.0) |
| **Explorer** | [Voyager Sepolia](https://sepolia.voyager.online/contract/0x20768453fb80c8958fdf9ceefa7f5af63db232fe2b8e9e36ead825301c4de74) |

### 1. Build the Rust Prover
```bash
cd prover
./build_ios.sh
# Expected output: prover/target/StarkVeilProver.xcframework
```

### 2. Build the Cairo Contract (optional — already deployed)
```bash
cd contracts
scarb build   # Produces Sierra + CASM in target/dev/
```

### 3. Run the iOS App
```bash
open ios/StarkVeil/StarkVeil.xcodeproj
# Select iPhone 15 Simulator or physical device → ⌘R
```
The app points to Sepolia by default. No configuration needed.

### 4. Fund Your Wallet
1. Create or import a wallet in the app.
2. Tap the avatar → **Activate Wallet** to see your Starknet address.
3. Fund it with Sepolia STRK from the [Starknet Faucet](https://starknet-faucet.vercel.app/).
4. Tap **Activate** — this deploys your OpenZeppelin account on-chain.

### 5. Shielding
1. Tap **Shield** on the main screen.
2. Enter an amount (e.g. `0.1`) and tap **Shield**.
3. Approve + shield multicall submits in one tx.
4. On success: a banner appears with a tappable tx hash linking to Voyager.
5. Your shielded balance updates immediately.

### 6. Private Transfer (S → S)
1. Ask the recipient to share their SVK from **Receive → Shielded Address (S)**.
2. Tap **Send** → select **Shielded (S)** mode.
3. Paste the `svk:0x…` address and amount.
4. Tap **Send (Private)** — no amounts or addresses visible on-chain.

### 7. Unshield (S → U)
1. Tap **Shield** → switch to **Unshield** tab.
2. Enter the amount matching an existing shielded note.
3. Tap **Unshield** — STRK returns to your public balance.

---

### Local Development (optional)
For local chain testing with Katana:
```bash
katana --dev   # RPC: http://127.0.0.1:5050
```
Then re-deploy the contract:
```bash
cd /path/to/starknetWallet
node deploy_contract.js   # Declares + deploys PrivacyPool via starknet.js
```
Update `NetworkEnvironment.swift` local case with your new contract address.

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

## 🔍 Comprehensive Technical Verification

For developers, auditors, and privacy enthusiasts, here is the exact lifecycle of a StarkVeil transaction, from public STRK (U) to the shielded pool (S), through a private transfer, and back to public STRK (U).

This section details how to verify the cryptographic proofs, on-chain state transitions, and the specific algorithms used at each step to guarantee absolute financial privacy.

### The Flow: U → S → Private Transfer → U

#### Stage 1: Shield (U → S)
**What happens:** A public Starknet account deposits STRK into the `PrivacyPool` contract.
*   **Action:** User inputs an amount (e.g. `0.1 STRK`) and taps **Shield**.
*   **Algorithms:**
    *   **Note Commitment:** `c = Poseidon(value, asset_id, owner_pubkey, nonce)`
        *   *Why Poseidon?* It is a ZK-friendly hash function, making it orders of magnitude cheaper to compute inside a STARK circuit later.
    *   **Memo Encryption:** `AES-256-GCM(key = HKDF(IVK), plaintext = memo)`
        *   *Why AES-256-GCM?* Standard symmetric encryption to allow the owner's `SyncEngine` to recover the memo string. The key is derived purely from the incoming viewing key (IVK).
*   **On-Chain Verification:**
    *   Query the `PrivacyPool` contract on Voyager or via `sncast`.
    *   Find the `Shielded` event. You will see the deposited `amount`, the `asset` contract address, and the opaque `commitment`.
    *   **Privacy check:** Notice that the `commitment` reveals nothing about the user's IVK or the memo. The wallet's public address is visible as the *sender* of the transaction, which is expected for a public-to-private deposit.

#### Stage 2: Private Transfer (S → S)
**What happens:** Moving shielded STRK to another user inside the privacy pool without revealing sender, receiver, or amount.
*   **Action:** User inputs the recipient's Shielded Address (`svk:0x...`) and an amount, then taps **Send**.
*   **Algorithms:**
    *   **Nullifier Generation:** `nf = Poseidon(commitment, spending_key)`
        *   *Why Nullifier?* It proves the note is spent without revealing *which* note was spent. The contract enforces `!nullifiers[nf]` to stop double-spends.
    *   **Output Commitments:** New `Poseidon` hashes are generated for the recipient's note and the sender's change note.
    *   **STARK Proof:** The `libstarkveil_prover` Rust core generates a Cairo-compatible STARK proof asserting: `Σ Input = Σ Output + Fee`, and that all inputs exist in the Merkle Tree.
        *   *Why STARKs?* Quantum-resistant, highly scalable, and require no trusted setup (unlike SNARKs).
*   **On-Chain Verification:**
    *   Find the `Transfer` event on-chain.
    *   **Privacy check:** You will only see the `proof` blob, a list of `nullifiers` (spent signals), and a list of `new_commitments`.
    *   Notice that the transaction **does not contain any amounts, asset IDs, or recipient addresses**. To an outside observer, this transaction is completely opaque.

#### Stage 3: Sync & Discovery
**What happens:** The recipient's wallet detects the incoming private transfer.
*   **Action:** The wallet's `SyncEngine` polls the RPC every 5 seconds for new `Transfer` events.
*   **Algorithms:**
    *   **Trial Decryption:** The wallet attempts to decrypt the `encrypted_memo` field of every new commitment using its own `IVK`.
        *   `if decrypt(ciphertext, IVK) == success: add_to_wallet_balance()`
        *   *Why Trial Decryption?* Since the destination address is not on-chain, the wallet must attempt to unlock every new note. If it succeeds, the note belongs to the user.
*   **Verification:**
    *   The recipient's wallet balance updates automatically. Without the `IVK`, no one else can decrypt the memo or know who received the transfer.

#### Stage 4: Unshield (S → U)
**What happens:** Withdrawing shielded STRK back to a public Starknet account.
*   **Action:** User inputs a public Starknet address (`0x...`) and an amount matching a single note, then taps **Unshield**.
*   **Algorithms:**
    *   **Nullifier Generation:** Same as private transfer, a nullifier is generated to destroy the shielded note.
    *   **STARK Proof:** The proof asserts the note's validity and, crucially, binds the `recipient_address` and `amount` as **public inputs**.
        *   *Why Public Inputs?* This cryptographically forces the smart contract to transfer the exact `amount` to the exact `recipient_address`. A malicious front-runner cannot alter the destination without invalidating the cryptographic proof.
*   **On-Chain Verification:**
    *   Find the `Unshielded` event on-chain.
    *   **Privacy check:** You will see the `recipient` address, the `amount`, and the `nullifier`. However, you **cannot cryptographically link** this `nullifier` back to the original `commitment` from Stage 1. The identity of the depositor is completely severed from the identity of the withdrawer.
    *   Call `is_nullifier_spent(nf)` on the contract; it will return `1` (true).

---

## 🔮 What's Pending (Post-Hackathon)

| Item | Priority | Notes |
|---|---|---|
| Stwo client-side ZK prover circuit | Critical | Replace mock verifier in `privacy_pool.cairo` with real on-chain Stwo verifier |
| RFC 6979 nonce for ECDSA signing | High | Replace SHA-256 deterministic k with proper RFC 6979 |
| Mainnet contract deployment | Medium | Upgrade from Sepolia |
| Starknet ID integration | Low | Replace `anon.stark` placeholder |
| Mainnet STRK faucet / deposit flow | Low | UX for onboarding new users |

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

