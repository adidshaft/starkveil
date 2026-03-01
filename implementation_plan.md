# StarkVeil: The Bulletproof Starknet Privacy Wallet
**Vision**: A truly cypherpunk, native Starknet iOS wallet offering complete financial privacy by default. Using native STARK proving infrastructure and Cairo, StarkVeil enforces a Zcash-style shielded pool without any trusted execution environments (TEEs) or off-chain data availability hacks.

**Target UX**: A dark-themed, glassmorphic UI that feels premium, seamless, and deeply responsive. The user never sees complex "shielding" steps—everything public is instantly auto-shielded.

---

## Phase 1: Cryptographic Architecture & Rules of Engagement

The core philosophy of StarkVeil is **trustless computation** utilizing Starknet's S-two prover and Cairo capability, steering completely clear of Encifher's threshold ElGamal over TEEs stack.

*   **Shielded Notes Model**: Adopt a Zcash-style UTXO model to handle private notes.
    *   **Note structure**: `Poseidon(value, asset_id, owner_ivk, memo)`
    *   **Nullifiers (Double-spend protection)**: `Poseidon(spending_key, note_position)`
*   **Keys and Stealth Addresses**:
    *   **Spending Key**: Derived from the user's seed phrase, safeguarded in the iOS Secure Enclave.
    *   **Viewing Key**: Stored in iCloud Keychain (user-opt-in). Extracts decryptable incoming notes, and provides selective auditability compliance without risking funds.
*   **Privacy by Default Rule Engine**:
    *   **Auto-Shield**: Any deposit sent to the user's public Starknet address is detected and systematically routed to a **shielding transaction**.
    *   **Private Sending**: Outbound transfers exclusively consume shielded notes. Emits the corresponding nullifiers while outputting fresh shielded commitments for the recipient.

> **Manual Step 1**: Conduct a cryptographic threat-model review session. Define exact visibility surfaces concerning what an observer on Starknet block explorers will see (e.g., asset types vs. amounts vs. participants).

---

## Phase 2: On-Chain Shielded Pool (Cairo Smart Contracts)

Forge the on-chain settlement layer—the smart contracts handling the shielded Merkle root. Use the open-sourced `strkBTC` patterns or `Tongo SDK` core logic.

1.  **Deploy `PrivacyPool` Contract (Cairo)**:
    *   `shield()`: Public to Private minting function. Accepts user's funds, adds a new *commitment* into the Poseidon-based Merkle tree.
    *   `private_transfer()`: The engine. Accepts a STARK proof that proves (1) nullifier validity (unspent status), (2) balance conservation (Input = Output + Fee), and (3) range proofs (0 ≤ value ≤ MAX). Adds the new Note formulation to the commitment tree.
    *   `unshield()`: Only utilized when absolutely necessary. Burns a note and transfers public Starknet funds to a known address.
2.  **Verify S-two STARK Proofs On-Chain**: Leverage built-in verification efficiency. Only the Merkle tree root and nullifier hash table are updated on Starknet.

> **Manual Step 2**: Spin up a local Starknet node (`katana`). Deploy an isolated, simplified test of the `PrivacyPool` contract to manually verifygas limits on STARK verifications for the `private_transfer` proofs.

---

## Phase 3: Client-Side Proving Pipeline

This is the hardest but most crucial engineering step: transitioning STARK proof generation directly to iOS devices to omit TEE trust assumptions.

1.  **Cairo Circuits Definition**: Build the exact equations logic ensuring Note generation (amount hidden, sender has sufficient balance). Compile this to a STARK-compatible circuit using `S-two`.
2.  **Proving SDK (Rust Crate & FFI)**:
    *   Embed the StarkWare official client-side SDK (or S-two prover logic) into a Rust package.
    *   Wrap it with a `Swift FFI` boundary so iOS native code can pass the exact `[Note, Nullifier, New Commitment]` payloads from the Swift layers to the underlying Rust circuit.
3.  **Proof Generation UX Pipeline**: Apply recursive STARKs locally for lighter processing if needed. Expected time: 5-30s based on hardware (iPhone 15+). To avoid blocking the UX, background this proof operation.

> **Manual Step 3**: Execute physical benchmarking. Compile the barebones Swift-Rust Prover on an older device (iPhone 12/13) to measure actual battery drain, RAM footprint, and latency.

---

## Phase 4: iOS App Engineering (SwiftUI)

This governs user interaction. "Apple-level" engineering.

1.  **Wallet Core Setup**:
    *   BIP-39 seed generation → Generate Starknet standard spending/viewing keypair.
    *   Setup iOS Secure Enclave protocols via `starknet.swift` bindings.
2.  **State Sync Engine (Light Client)**:
    *   Build a background syncing engine. It pings the Starknet RPC, downloads only the updated shielded Merkle tree paths, and hashes local notes to check for viewing-key matches.
    *   Utilize local encrypted DB (`CoreData` + `SQLCipher`) storing current balances and witnesses.
3.  **Private-by-default logic flow**:
    *   If a public payload event hits the app's address, automatically trigger the invisible `shield()` flow in the background (potentially with a cool "shredding and rebuilding" animation).

> **Manual Step 4**: Build a localized UI sandbox just for tweaking complex state sync race conditions (e.g., getting a new incoming transaction while actively generating an outbound proof).

---

## Phase 5: High-End UI/UX Assembly

To compete, the interface must be extremely fluid and evoke the feeling of entering a secure, high-tech vault.

1.  **Aesthetics & Atoms**:
    *   **Color Palette**: True OLED black (`#000000`), Dark obsidian grays (`#1A1A1A`), accented by striking electric tones (e.g., `Neon Indigo` or `Laser Green` for successful actions).
    *   **Typography**: Opt for a futuristic yet incredibly legible font (e.g., `Outfit` or `Space Grotesk`).
    *   **Material**: Frosted glassmorphism panels acting as cards hiding the actual balance until you tap/Hold (to preserve physical privacy from over-the-shoulder lookers).
2.  **Micro-animations**:
    *   **The "Shielding" effect**: When public funds are received, show them converting to "encrypted nodes" with a beautiful matrix-like or fluid morphing effect.
    *   **Proof Generation Loop**: Instead of a standard loading spinner, show a "Cryptographic Proof Synthesis" geometric animation (like connecting dots or a growing Mandelbrot element) so the user feels the 5-20 second wait is doing *heavy, important* computational work.
3.  **Auditor's Mode (Selective Disclosure)**: A clean sub-view where users can securely output a zero-knowledge statement or export a time-framed viewing key for tax/compliance purposes, wrapped in a polished PDF or QR code generator.

> **Manual Step 5**: Produce High-Fidelity Figma prototypes capturing complete state-transitions (Idle -> Hiding -> Sending -> Proving -> Broadcasted). Gather small focus group feedback regarding the "Proving" loading state.

---

## Phase 6: Auditing & Launch

1.  **Audit the Core Components**:
    *   Schedule formal verification for the `Nullifier` uniqueness equations (preventing millions being minted).
    *   Hire a specialized ZK auditing firm (Nethermind / Trail of Bits) to inspect the Cairo pool contracts.
2.  **App Store Finalization**:
    *   Draft explicit terms to navigate Apple’s stringent crypto policies.
    *   Ensure the presence of an active "Selective Disclosure" mode to prove non-malicious functionality if regulated.
3.  **Beta Rollout (Testnet)**:
    *   Run a closed Testnet Beta to collect metrics on UX flow drop-offs and on-device proof failure edge cases.

> **Manual Step 6**: Conduct a simulated "Hackathon" on your own codebase. Give the starknet community access to the testnet contract holding dummy bounties, asking them to try tracing or doubly-spending notes.

---

## Phase 5: High-End UI/UX Assembly

Now that the core STARK proving mechanisms and state boundaries are solidly engineered, we must overhaul the UI to match the "Premium Vault" aesthetic requirements.

### User Review Required
Please review the styling constraints below. In Phase 5, we will focus exclusively on the `ios/StarkVeil/Views/` components. No changes will be made to the `Core/` logic or Rust Prover SDK.

### 1. View Refactoring & Splitting
- Break down `VaultView.swift` into manageable subcomponents:
  - `VaultHeaderView.swift` (Sync status and title)
  - `ShieldedBalanceCard.swift` (The interactive privacy-blur balance)
  - `PrivateSendForm.swift` (The action area)
  
### 2. Styling Constraints (Glassmorphism & OLED)
- Base background: Pure OLED Black (`#000000`).
- Card backgrounds: `UltraThinMaterial` or customized `#1A1A1A` with a heavy blur radius.
- Accents: Introduce a striking color logic. For instance, Electric Purple / Neon Indigo buttons when active, or Laser Green success text.
- Typography: Setup custom font modifiers targeting `SpaceGrotesk` and `Outfit` if they are packaged, or configure exact system fallbacks.

### 3. Micro-Animations
- **Syncing Status**: The green/red dot should have an organic breathing (scale up/down) animation.
- **Privacy Reveal**: The long-press un-blurring of the balance should use `withAnimation(.spring())` for extreme fluidity.
- **Proof Generation Loop**: Swap the generic `ProgressView` during `isProving == true` for a custom geometric or pulsing skeleton animation indicating complex mathematical STARK synthesis.
