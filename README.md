<div align="center">
  <img src="logos/starkveil_logo_white.png" alt="StarkVeil Logo" width="150" height="auto" style="border-radius: 22%;">
</div>

<p align="center">
  <code>Cairo</code> &nbsp;&middot;&nbsp; <code>STARKs</code> &nbsp;&middot;&nbsp; <code>Shielded Privacy</code> &nbsp;&middot;&nbsp; <code>iOS Wallet</code>
</p>

# StarkVeil: Native iOS Shielded Pool

StarkVeil is a purely native cypherpunk iOS wallet that enforces total financial privacy on Starknet. Unlike standard web3 wallets, StarkVeil removes the need for Trusted Execution Environments (TEEs) and external wallet apps. It brings Zero-Knowledge STARK proof synthesis directly onto A-series silicon via a Rust SDK, gives users a fully self-contained shielded account (no ArgentX needed), and uses an original Shielded Note commitment scheme for private transfers.

**Current status (Phase 21 — Live on Sepolia):** PrivacyPool contract deployed on Starknet Sepolia testnet. Full U↔S cycle functional: shield, unshield, private transfer and shielded-to-shielded sends all work end-to-end. Wallet uses a clean U/S model inspired by Zashi. Total balance card shows U+S inline breakdown. 3 action buttons: Send, Receive, Shield. Unified Send auto-detects `svk:` prefix for private transfers vs `0x` for public sends. Shield/Unshield is a single toggle view. Receive shows two clearly labelled addresses: S (`svk:0x<ivk>:0x<pubkey>` — for private receives) and U (`0x…` — for exchanges). 4-tab nav: Wallet | Swap | Activity | Settings. Activity feed correctly shows `+`/`−` prefixes and colours for all 5 event kinds. **Phase 21:** Completely replaced the hackathon mock proof verifier with a production-grade Circle STARK proving system. The iOS Swift client now synthesizes a 68-column M31/QM31 algebraic execution trace locally via the Rust `stwo` framework. The Starknet Sepolia `PrivacyPool` contract natively verifies this STARK proof via Fiat-Shamir FRI layering, guaranteeing balance conservation and unforgeable ownership on-chain without TEEs.

---

## 🏆 How to reproduce it on your own Mac, iPhone and Simulators

> **Note:** Since this is a native iOS app, you'll have to follow the steps below to reproduce it on your end. No worries, it's just a one-time thing and you do **not** have to deploy the pool contract or compile the Rust Prover!

### How to test right now:

1. **Clone the repository:**
   ```bash
   git clone https://github.com/adidshaft/starkveil.git
   cd starkveil
   ```

2. **Open the project in Xcode:**
   ```bash
   open ios/StarkVeil/StarkVeil.xcodeproj
   ```

3. **Run the App:**
   - **Easiest Method (No Apple Developer Account needed):** Select any iOS Simulator (e.g., *iPhone 15 Pro*) at the top of Xcode and press **⌘R** (Run). 
   - **On a Physical iPhone (Requires free Apple ID):** Click on the `StarkVeil` project in the left sidebar → **Signing & Capabilities** → Check *Automatically manage signing* → Select your Personal Team → Choose your plugged-in iPhone at the top → Press **⌘R**.

*(See [Comprehensive Technical Verification](#-comprehensive-technical-verification) below to see exactly how to verify the cryptographic proofs on-chain).*

---

## Project Structure
- **`contracts/`**: The Cairo smart contract that handles the appending of the UTXO Poseidon hashes and validates STARK nullifier proofs to prevent double-spending.
- **`prover/`**: A standard Rust Cargo library that compiles to static binaries (`libstarkveil_prover.a`) leveraging FFI `C` strings to pass Proofs to Swift.
- **`ios/StarkVeil/`**: The native Apple SwiftUI application interface. Handles `@MainActor` thread-safe background light-client syncing, unspent note caching, and premium glassmorphic visual interactions.

---

## 🚀 How to Run on Starknet Sepolia (Testnet)

The PrivacyPool contract is **already deployed** on Sepolia. No local node required.

### Deployed Contract (Phase 21 Stwo Verifier)
| | |
|---|---|
| **Network** | Starknet Sepolia (v0.14.1) |
| **Contract address** | `0x062cf904594a71239b0a72350289175b233bacf84e5649c656acabee69206b6f` |
| **Class hash** | `0x024559a23de684c4421ff64afd7edce6630b905c12d8a7f6431f9459e3fb76f9` |
| **Compiler** | Scarb / Cairo 2.16.0 · Sierra 1.7.0 |
| **Deployed** | 2026-03-07 |
| **RPC (primary)** | `https://api.cartridge.gg/x/starknet/sepolia` (Cartridge, v0.9.0) |
| **Contract on Voyager** | [View on Voyager](https://sepolia.voyager.online/contract/0x062cf904594a71239b0a72350289175b233bacf84e5649c656acabee69206b6f) |
| **Declare tx** | [View on Voyager](https://sepolia.voyager.online/tx/0x05ba511955e82ebe8b04290421599769dbed9f2b716488ae4b3a376cc499ea8a) |
| **Deploy tx** | [View on Voyager](https://sepolia.voyager.online/tx/0x02dae02bd25317a78f07f23d039b0c2fe03dd4e2ca5c377df77e833f795299ef) |

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
3. Paste the `svk:0x<ivk>:0x<pubkey>` address and amount.
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
>   --function get_mt_next_index
> # Value increments by 1 per shield
> ```

### Step 8 · Private Transfer (Shield → Shield, No Public Trace)
| Checkpoint | Expected Result |
|---|---|
| Tap **Private Transfer** button (below action grid) | `PrivateTransferView` opens as full-screen cover |
| Enter: recipient shielded address (`svk:<ivk>:<pubkey>`), amount, optional memo | Fields validated live |
| Tap **Send Privately** | On-chain `Transfer` event emitted with encrypted output commitment |
| Recipient's SyncEngine polls Transfer events | Recipient trial-decrypts the encrypted note with their IVK — note appears in their balance |
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
*   **Action:** User inputs the recipient's Shielded Address (`svk:0x<ivk>:0x<pubkey>`) and an amount, then taps **Send**.
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
    *   **Trial Decryption:** The wallet attempts to decrypt the `encrypted_note` payload of every new commitment using its own `IVK`.
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

## 📚 Deep Dive & Security

For an extensive deep-dive into the StarkVeil architecture, the underlying cryptographic mechanics (Merkle Trees, ZK Proof binding, FFI integration), and the local UTXO model, please refer to the core mechanics document:

👉 **[Read CORE_MECHANICS.md](./CORE_MECHANICS.md)**

StarkVeil was continuously audited throughout development. For full security assessments (including vulnerability patches like RFC-6979 deterministic nonces), threat modeling, and formal cryptographic analysis, check the audits directory:

👉 **[View Security Audits](./audits/)**
