# Phase 8 Security, Privacy & Correctness Audit — StarkVeil Full-Stack

## Audit Prompt

Perform a deep security, privacy, and correctness audit of the complete StarkVeil codebase spanning
Cairo contracts, Rust FFI prover, Swift iOS core, the privacy model, and the integration path to Stwo.

1. **Cairo Contract Audit** (`contracts/src/`)
   - Review `shield()`, `private_transfer()`, `unshield()`, `verify_proof()`, `insert_leaf()`
   - Check Poseidon zero-hash correctness at all 20 levels
   - Verify Merkle sibling-bound formula (`nodes_at_level`) at every level
   - Check `encrypted_memo` is committed in `Shielded` event and immutable post-emission
   - Confirm nullifier registry is append-only with no delete path
   - Check reentrancy ordering in `unshield()` (state before external call)
   - Verify `historic_roots` write ordering relative to `mt_root` update

2. **Rust FFI Prover Audit** (`prover/src/lib.rs`, `prover/include/`)
   - Audit all 7 exported FFI functions for memory safety
   - Null-pointer guards on all `CString` inputs
   - `free_rust_string` as sole deallocation path
   - `derive_ivk` domain separation correctness
   - `note_nullifier` scheme matches Cairo contract
   - Mock proof bytes clearly flagged

3. **Swift iOS Audit** (`ios/StarkVeil/StarkVeil/Core/`)
   - `WalletManager`: nonce consistency, `isPendingSpend` reset in all error paths,
     `isNullifierSpent` called before proof, double-spend race window
   - `SyncEngine`: IVK derived outside loop, fallback correctness, `nil` vs `throw` handling
   - `NoteEncryption`: HKDF domain separation, nonce randomness, timing on auth failure
   - `RPCClient.isNullifierSpent`: selector derivation algorithm, fail-open safety
   - `KeychainManager`: `nil` on missing item, `kSecAttrAccessible` on all items

4. **Privacy Model Audit**
   - Linkability of shield commitment to unshield nullifier
   - Deterministic nonce scheme — same user/amount/asset produces duplicate commitments
   - Wrong IVK in private transfer — attacker-controlled IVK scenario
   - Metadata leak via `encrypted_memo` field length
   - SyncEngine timing side-channels

5. **Integration Path to Stwo**
   - Where mock bytes live and what interface a real Stwo circuit needs
   - Swift call sites requiring change at proof integration time
   - Whether `verify_proof` stub leaves a clean hook or needs redesign

Files audited:
- `contracts/src/privacy_pool.cairo`
- `contracts/src/interfaces.cairo`
- `contracts/src/types.cairo`
- `prover/src/lib.rs`
- `prover/src/types.rs`
- `ios/StarkVeil/StarkVeil/Core/WalletManager.swift`
- `ios/StarkVeil/StarkVeil/Core/SyncEngine.swift`
- `ios/StarkVeil/StarkVeil/Core/NoteEncryption.swift`
- `ios/StarkVeil/StarkVeil/Core/NoteDecryptor.swift`
- `ios/StarkVeil/StarkVeil/Core/RPCClient.swift`
- `ios/StarkVeil/StarkVeil/Core/KeychainManager.swift`
- `ios/StarkVeil/StarkVeil/Views/PrivateTransferView.swift`

---

## Findings Summary

| ID | Severity | File | Line | Description |
|---|---|---|---|---|
| C-1 | **CRITICAL** | `privacy_pool.cairo` | 58–64 | Mock verifier returns `true` unconditionally — no proof required to drain pool |
| C-2 | **CRITICAL** | `WalletManager.swift` | 546, 715, 730 | Deterministic nonce `Poseidon(IVK,value,asset)` → same user+amount+asset produces identical commitment → second note unspendable |
| C-3 | **CRITICAL** | `lib.rs` | 264–265 | Space in IVK domain hex string → `from_hex_be` always fails → wrong fallback domain `0x494b56` used for every IVK |
| C-4 | **CRITICAL** | `WalletManager.swift` | 407–418, 559–569 | u256 split divides by `UInt64.max` (2^64) not 2^128 → wrong token amounts for all deposits/withdrawals above ~18.44 STRK |
| C-5 | **CRITICAL** | `WalletManager.swift` | 611–612 | `executeShield` calldata missing `asset` and `encrypted_memo` — all shield transactions revert on-chain |
| C-6 | **CRITICAL** | `WalletManager.swift` | 747–759 | `executePrivateTransfer` calldata does not match Cairo `private_transfer()` ABI — all private transfers revert on-chain |
| H-1 | **HIGH** | `WalletManager.swift` | 783 | `removeNote()` called but never defined anywhere — compile error |
| H-2 | **HIGH** | `lib.rs` | 155–183 | `stark_sign_transaction` accepts caller-supplied `k` with no RFC 6979 enforcement — ECDSA nonce reuse breaks key |
| H-3 | **HIGH** | `RPCClient.swift` | 400–402 | `isNullifierSpent` selector computed with SHA3-256 not Ethereum Keccak-256 — nullifier check always silently disabled |
| H-4 | **HIGH** | `WalletManager.swift` | 731–735 | Recipient account address used as `ownerPubkey` in output commitment — address ≠ EC pubkey → received notes permanently unspendable |
| H-5 | **HIGH** | `lib.rs` | 301–311 | Missing note fields silently replaced with `0x0` — wrong nullifier produced with no error |
| H-6 | **HIGH** | `privacy_pool.cairo` | 187–188 | `private_transfer` uses live `mt_root` tip not a client-supplied historic root — all real proofs will fail after any intervening leaf insertion |
| H-7 | **HIGH** | `lib.rs` | 339 | Mock proof element `"0x504c414345484f4c444552_50524f4f46"` contains underscore — invalid felt252 hex |
| M-1 | **MEDIUM** | `SyncEngine.swift` | 201 | `try?` collapses `InvalidCiphertext` to `nil` — own notes with malformed on-chain ciphertext silently dropped |
| M-2 | **MEDIUM** | `WalletManager.swift` | 739–742 | Private transfer falls back to plaintext memo hex on encryption failure — private memo exposed on-chain |
| M-3 | **MEDIUM** | `SyncEngine.swift` | 149–150 | Cold-start scans only last 10 blocks — long-inactive users miss incoming notes |
| M-4 | **MEDIUM** | `NoteEncryption.swift` / `NoteDecryptor.swift` | 58 / 30 | Two incompatible encryption schemes coexist with different HKDF `info` values — notes encrypted by one cannot be decrypted by the other |
| M-5 | **MEDIUM** | `lib.rs` | 361–364 | `free_rust_string` has no double-free protection — second call is heap UB |
| M-6 | **MEDIUM** | `WalletManager.swift` | 640 | Optimistic `addNote` before shield confirmation — revert leaves phantom note |
| L-1 | LOW | `privacy_pool.cairo` | 146–147 | `historic_roots` written after `mt_root` — defensively wrong order |
| L-2 | LOW | `WalletManager.swift` | 132–137 | Dedup guard uses `(value,asset,ivk,memo)` not commitment hash — breaks after C-2 fix |
| L-3 | LOW | `WalletManager.swift` | 780–785 | No activity event logged for successful private-to-private transfers |
| L-4 | LOW | `lib.rs` | 263 | Comment misidentifies domain separator bytes (`494b4b` / IKK vs `49564b` / IVK) |
| L-5 | LOW | `privacy_pool.cairo` | 244–249 | `unshield` public inputs omit Merkle root — Stwo circuit cannot enforce membership |
| I-1 | INFO | Protocol | — | `encrypted_memo` length leaks approximate plaintext length on-chain |
| I-2 | INFO | UI | — | Attacker-controlled recipient IVK leaks memo content to attacker (funds still safe) |
| I-3 | INFO | `SyncEngine.swift` | — | Timing safe — decryption is batched; no per-note observable delay |

**Safe (no issues):**
- Merkle tree sibling bound `ceil(leaf_count / 2^level)` is correct at all 20 levels ✓
- Poseidon zero-hash constants populated for levels 0–20 (verified chain present in code) ✓
- `encrypted_memo` emitted in `Shielded` event; Cairo events are immutable post-emission ✓
- Nullifier registry `Map<felt252, bool>` is append-only; no `delete` or `write(nf, false)` path ✓
- `unshield()` marks nullifier spent *before* `erc20.transfer` — reentrancy safe ✓
- All 7 FFI functions check for null pointers before `CStr::from_ptr` ✓
- `CString::new().unwrap_or_else` used throughout — no panic-across-FFI ✓
- `free_rust_string` is the only deallocation path ✓
- IVK domain separation from nullifier: `Poseidon(sk, domain)` vs `Poseidon(commitment, sk)` — distinct ✓
- `nullifier = Poseidon(commitment, sk)` matches Cairo `is_nullifier_spent` scheme ✓
- Mock proof bytes are clearly commented as placeholders ✓
- `KeychainManager.masterSeed()` returns `nil` on missing item — no fallback ✓
- `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` set on all `store()` calls ✓
- AES-GCM nonce is generated by CryptoKit internally — random 96-bit ✓
- `decryptMemo` returns `nil` on GCM auth failure (does not throw) ✓
- `isNullifierSpent` fail-open (`false`) on RPC error is documented and intentional ✓
- `isTransferInFlight` guard prevents concurrent transfer re-entrancy ✓
- Shield commitment → nullifier: unlinkable without spending key — chain observer cannot link ✓

---

## Section 1 — Cairo Contract

### BUG C-1 — CRITICAL: Mock verifier unconditionally accepts all proofs

**File:** `contracts/src/privacy_pool.cairo:58–64`

```cairo
fn verify_proof(ref self: ContractState, proof: Span<felt252>, public_inputs: Span<felt252>) -> bool {
    // MOCK VERIFIER: Returns true unconditionally for demo purposes.
    true
}
```

`verify_proof` is called by both `private_transfer` (line 205) and `unshield` (line 249).
Any caller can invoke `unshield()` with empty `proof = []`, fabricated `nullifier`, and
arbitrary `amount`/`recipient`/`asset`. The pool is fully drainable with zero cryptographic
knowledge. This is not a production blocker given the contract is in development, but it
**must** be gated before any live deployment.

**Fix:** Add an admin-controlled `is_live_mode: bool` storage flag that starts `false`. Gate
`verify_proof` so it returns `true` only when `is_live_mode == false` (test) or the Stwo
verifier validates (production). Do not deploy to Mainnet or any production Sepolia pool
holding real value until Stwo is integrated.

---

### BUG H-6 — HIGH: `private_transfer` binds proof to live `mt_root`, not client-supplied historic root

**File:** `contracts/src/privacy_pool.cairo:187–188`

```cairo
// The root here is the current tip; in production the client should
// supply the specific historic root the proof was generated against
public_inputs.append(self.mt_root.read());
```

A ZK proof for note membership is generated at a specific Merkle root R. If even one leaf is
inserted between proof generation and submission, `mt_root` advances to R'. The contract feeds
R' into `public_inputs`, causing the circuit's membership check to fail. Every
`private_transfer` would be rejected the moment any concurrent shield/transfer occurs.

**Fix:** Add `historic_root: felt252` as an explicit parameter to `private_transfer`. Validate
it and use it in `public_inputs`:

```cairo
fn private_transfer(
    ref self: ContractState,
    proof: Array<felt252>,
    nullifiers: Array<felt252>,
    new_commitments: Array<felt252>,
    fee: u256,
    historic_root: felt252   // ← add this
) {
    assert(self.historic_roots.read(historic_root), 'Unknown historic root');
    let mut public_inputs = ArrayTrait::new();
    public_inputs.append(historic_root);   // ← not mt_root.read()
    ...
```

---

### BUG L-1 — LOW: `historic_roots` written after `mt_root`

**File:** `contracts/src/privacy_pool.cairo:146–147`

```cairo
self.mt_root.write(current_hash);
self.historic_roots.write(current_hash, true);
```

Within a single Starknet transaction these writes are atomic. However, once H-6 is fixed and
contracts may assert `historic_roots.read(root)` in the same execution, defensive ordering
(write the root to the set *before* advancing the tip) is preferable.

**Fix:** Swap the two lines.

---

### BUG L-5 — LOW: `unshield` public inputs omit Merkle root

**File:** `contracts/src/privacy_pool.cairo:244–249`

```cairo
let mut public_inputs = ArrayTrait::new();
public_inputs.append(amount.low.into());
public_inputs.append(amount.high.into());
public_inputs.append(recipient.into());
public_inputs.append(asset.into());
```

A real `unshield` circuit proves Merkle membership (the note is in the tree). Without the root
in `public_inputs`, the circuit cannot enforce membership, allowing a user to unshield a note
that was never shielded.

**Fix:** Accept and validate a `historic_root` parameter (same as H-6), then prepend it to
`public_inputs`.

---

### Nullifier registry append-only — SAFE ✓

There is no `nullifiers.write(nf, false)` path anywhere in the contract. The registry is
append-only. `is_nullifier_spent` is a read-only view. ✓

### `encrypted_memo` immutability — SAFE ✓

`encrypted_memo` is included in the `Shielded` event struct (line 39) and emitted at line 171.
Cairo events are emitted by-value and are permanently recorded in transaction receipts; they
cannot be mutated after emission. ✓

### Reentrancy ordering in `unshield()` — SAFE ✓

```cairo
// line 251–252: state mutation BEFORE external call
assert(!self.nullifiers.read(nullifier), 'Note already spent');
self.nullifiers.write(nullifier, true);

// line 254–255: external call AFTER state mutation
let erc20 = IERC20Dispatcher { contract_address: asset };
erc20.transfer(recipient, amount);
```

Any reentrant call to `unshield()` with the same nullifier hits the `assert` at line 251 and
reverts. ✓

### Merkle sibling-bound formula — SAFE ✓

```cairo
let nodes_at_level = (leaf_count + level_size - 1) / level_size;
```

For level `k`, `level_size = 2^k`. The bound `ceil(leaf_count / 2^k)` correctly limits which
level-`k` nodes were previously written, fixing the prior bug that used raw `leaf_count` for
every level. ✓

---

## Section 2 — Rust FFI Prover

### BUG C-3 — CRITICAL: IVK domain separator always uses wrong fallback

**File:** `prover/src/lib.rs:264–265`

```rust
// Domain separator: ASCII "StarkVeil IVK v1" packed as a felt252
// = 0x537461726b5665696c20494b4b2076 31 (hex of the ASCII string)
let domain = FieldElement::from_hex_be("0x537461726b5665696c20494b562076 31")
    .unwrap_or(FieldElement::from(0x494b56_u64));  // "IVK" fallback
```

Two compounding bugs:

1. **Space character in hex literal.** The string `"...76 31"` contains an ASCII space (0x20)
   between the bytes `76` and `31`. `from_hex_be` rejects any non-hex character and returns
   `Err(...)`. The `unwrap_or` silently substitutes `FieldElement::from(0x494b56_u64)`.

2. **Byte-order error in the intended hex.** The code comment writes `494b4b` (I-K-K) and the
   literal writes `494b56` (I-K-V). The correct ASCII for "IVK" is `0x49 0x56 0x4b` (I-V-K =
   `49564b`). Even without the space the wrong domain would be used.

Because the bug is consistently present, every existing IVK is derived with domain `0x494b56`
("IKV"). The system works internally today, but any future correction to the domain separator
silently invalidates all existing IVKs, making historical notes undetectable.

**Fix:**

```rust
// Correct ASCII hex for "StarkVeil IVK v1"
// S    t    a    r    k    V    e    i    l    sp   I    V    K    sp   v    1
// 53   74   61   72   6b   56   65   69   6c   20   49   56   4b   20   76   31
let domain = FieldElement::from_hex_be("0x537461726b5665696c2049564b207631")
    .expect("hardcoded IVK domain constant is always valid hex");
let ivk = poseidon_hash_many(&[sk, domain]);
```

---

### BUG H-2 — HIGH: ECDSA `k` is caller-supplied with no RFC 6979 enforcement

**File:** `prover/src/lib.rs:155–183`

```rust
pub unsafe extern "C" fn stark_sign_transaction(
    tx_hash_hex: *const c_char,
    private_key_hex: *const c_char,
    k_hex: *const c_char,   // ← caller controls k
) -> *mut c_char {
    ...
    match sign(&pk, &msg_hash, &k) { ... }
}
```

Reusing the same `k` for two different messages allows complete private key recovery via the
standard ECDSA nonce-reuse attack: `sk = (s1 * z2 - s2 * z1) / (r * (s1 - s2)) mod n`.
The comment documents the risk but provides no enforcement. If Swift passes the same `k` twice
(accidentally, or due to a crash-and-retry pattern), the spending key is exposed.

**Fix:** Remove the `k` parameter from the public FFI. Derive `k` deterministically inside
Rust using RFC 6979 (`starknet_crypto` exposes `get_nonce_from_message` for this purpose).
Callers must never be able to influence `k`.

```rust
// Remove k_hex parameter entirely
pub unsafe extern "C" fn stark_sign_transaction(
    tx_hash_hex: *const c_char,
    private_key_hex: *const c_char,
) -> *mut c_char {
    ...
    // Deterministic k via RFC 6979
    let k = starknet_crypto::get_nonce_from_message(&pk, &msg_hash);
    match sign(&pk, &msg_hash, &k) { ... }
}
```

---

### BUG H-5 — HIGH: Missing note fields silently replaced with `0x0`

**File:** `prover/src/lib.rs:301–311`

```rust
let value_str  = note.value.as_deref().unwrap_or("0x0");
let sk_str     = note.spending_key.as_deref().unwrap_or("0x0");
...
let commitment = poseidon_hash_many(&[value, asset, owner, nonce]);
let nullifier  = poseidon_hash_many(&[commitment, sk]);   // sk = 0 if missing
```

If `spending_key` is absent from the JSON input, `sk = FieldElement::ZERO`. The produced
nullifier is `Poseidon(commitment, 0)` — a value that does not exist on-chain. The Swift caller
receives a plausible-looking result with no error, removes the note from the UTXO set, and
submits a transaction that will be rejected. Funds are lost silently.

**Fix:** Return an explicit error for any required security field that is `None`:

```rust
let sk_str = note.spending_key.as_deref()
    .ok_or_else(|| "missing required field: spending_key".to_string())?;
// (use ? operator after converting loop body to return Result)
```

---

### BUG H-7 — HIGH: Mock proof element contains underscore — invalid felt252 hex

**File:** `prover/src/lib.rs:339`

```rust
"0x504c414345484f4c444552_50524f4f46".to_string(),  // "PLACEHOLDER PROOF"
```

An underscore is not a valid hex character. Any consumer that parses this as a `felt252` (e.g.,
a future Stwo integration shim, a logging tool, or the Cairo ABI decoder) will reject it with a
parse error. The value is also not the correct hex encoding of "PLACEHOLDER PROOF" — the
underscore splits two separate byte sequences.

**Fix:** Remove the underscore. Use a clearly labelled constant:

```rust
// Mock proof — replace entirely when Stwo prover is integrated.
// Value is ASCII hex for "PLACEHOLDER" to make mock proofs visually identifiable in logs.
let mock_proof = vec![
    "0x0000000000000001".to_string(),
    "0x504c414345484f4c444552".to_string(),   // "PLACEHOLDER" — no underscore
];
```

---

### Memory safety — all FFI functions — SAFE ✓

Every exported function checks for `null` before calling `CStr::from_ptr`. All
`CString::new()` calls use `unwrap_or_else` to avoid panicking across the FFI boundary.
`free_rust_string` performs a null check before `CString::from_raw`. ✓

---

## Section 3 — Swift iOS Core

### BUG C-4 — CRITICAL: u256 split at 2^64 instead of 2^128

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:407–418` (identical at `559–569`)

```swift
if amountWei < Double(UInt64.max) {   // threshold ≈ 1.844 × 10^19 wei ≈ 18.44 STRK
    amountU256Low  = String(format: "0x%llx", UInt64(amountWei))
    amountU256High = "0x0"
} else {
    let highPart = UInt64(amountWei / Double(UInt64.max))  // divides by 2^64, NOT 2^128
    let lowPart  = UInt64(amountWei.truncatingRemainder(dividingBy: Double(UInt64.max)))
    amountU256Low  = String(format: "0x%llx", lowPart)
    amountU256High = String(format: "0x%llx", highPart)
}
```

Cairo's `u256` struct splits at the **128-bit boundary**: `low = value mod 2^128`,
`high = value >> 128`. For 100 STRK (= 10^20 wei):

| | Correct (split at 2^128) | Actual (split at 2^64) |
|---|---|---|
| `u256.low` | `0xDE0B6B3A76400000` (10^20) | ≈ `0x6C6B935B8BBD4000` |
| `u256.high` | `0x0` | `0x5` |

The ERC-20 `transfer_from` inside `shield()` attempts to transfer the wrong amount. For all
realistic STRK values (< 340 billion STRK), `u256.high` must be `0x0` and `u256.low` must
hold the full wei value — which fits in a u128.

An additional issue: `Double` has a 53-bit mantissa, so values above ~9,000 STRK
(≈ 9 × 10^21 wei > 2^53 ≈ 9 × 10^15) lose precision in the intermediate `amountWei` variable.

**Fix:** Use integer arithmetic throughout. For any realistic STRK amount, `u256.high == 0`:

```swift
// All realistic STRK amounts fit in UInt128 (max ≈ 340 × 10^9 STRK).
// Use Decimal for lossless wei conversion, then encode as u256{low, high=0}.
let amountDecimal = Decimal(amount) * Decimal(sign: .plus, exponent: 18, significand: 1)
let amountWeiBig  = (amountDecimal as NSDecimalNumber).stringValue  // exact integer string
// Encode as felt252 hex for Starknet
let amountU256Low  = "0x" + String(UInt128(amountWeiBig)!, radix: 16)
let amountU256High = "0x0"
```

---

### BUG C-5 — CRITICAL: `executeShield` calldata missing `asset` and `encrypted_memo`

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:611–612`

```swift
// encryptedMemo is computed at line 574–584 but never used here
let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x3", "0x3",
                amountLow, amountHigh, commitmentKey]
```

The Cairo `shield()` signature requires five felt arguments:
`(asset: ContractAddress, amount_low, amount_high, note_commitment, encrypted_memo)`.

The calldata sends only three (`amountLow, amountHigh, commitmentKey`). `data_len = "0x3"`
confirms this. The call reverts on-chain with an argument-count mismatch. The optimistic
`addNote(note)` at line 640 still fires, leaving a phantom note in the wallet.

**Fix:**

```swift
let strkContractAddress = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d" // Starknet Sepolia STRK
let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x5", "0x5",
                strkContractAddress, amountLow, amountHigh, commitmentKey, encryptedMemo]
```

---

### BUG C-6 — CRITICAL: `executePrivateTransfer` calldata does not match Cairo ABI

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:747–759`

```swift
let calldata: [String] = [
    "0x1", contractAddress, transferSelector, "0x0", "0x5", "0x5",
    nullifier, outputCommitment, inputNote.value, recipientAddress, encryptedMemo
]
```

The Cairo `private_transfer()` interface is:

```cairo
fn private_transfer(proof: Array<felt252>, nullifiers: Array<felt252>,
                    new_commitments: Array<felt252>, fee: u256)
```

The calldata passes `(nullifier, commitment, amount, address, memo)` — none of these match
the function's parameter types. `Array<felt252>` requires `[len, ...elements]` ABI encoding.
Every private transfer reverts on-chain.

**Fix:** Encode the ABI correctly:

```swift
let proofLen    = String(transferProof.count)
let nullifiers  = [nullifier]
let commitments = [outputCommitment]
let callPayload = [proofLen] + transferProof
    + [String(nullifiers.count)]  + nullifiers
    + [String(commitments.count)] + commitments
    + [feeLow, feeHigh]           // u256 fee

let calldata: [String] = [
    "0x1", contractAddress, transferSelector, "0x0",
    String(callPayload.count), String(callPayload.count)
] + callPayload
```

---

### BUG C-2 — CRITICAL: Deterministic nonce produces duplicate commitments

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:546, 715, 730`

```swift
// shield (line 546)
let noteNonce = try StarkVeilProver.poseidonHash(elements: [ivkHex, String(format: "%.6f", amount), "STRK"])

// executePrivateTransfer output note (line 730)
let outputNonce = try StarkVeilProver.poseidonHash(elements: [recipientIVK, inputNote.value, inputNote.asset_id])
```

Because `nonce = Poseidon(IVK, value, asset)` is fully deterministic and the IVK is constant
per wallet, shielding the same amount of the same asset twice yields **identical commitments**.
Two identical Merkle leaves share one nullifier (`Poseidon(commitment, sk)`). Spending one
nullifies both notes, silently destroying the second.

Identical commitments on-chain also prove they came from the same key, breaking unlinkability.

**Fix:** Use a cryptographically random 32-byte nonce at shield time. Persist the nonce in
`StoredNote` and embed it in the encrypted memo so SyncEngine can re-derive the exact
commitment during scanning.

```swift
// executeShield
var randomBytes = [UInt8](repeating: 0, count: 32)
let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
guard status == errSecSuccess else {
    throw NSError(domain: "StarkVeil", code: 20,
                  userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed"])
}
randomBytes[0] &= 0x07   // clamp to STARK_PRIME range
let noteNonce = "0x" + randomBytes.map { String(format: "%02x", $0) }.joined()
```

---

### BUG H-1 — HIGH: `removeNote()` is undefined — compile error

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:783`

```swift
removeNote(inputNote)   // no such method defined in WalletManager or any extension
```

A search of the entire iOS source tree returns this as the only occurrence. The
`executePrivateTransfer` (RPC path) does not compile. Additionally, `storedNote` (with
`isPendingSpend = true`) is never deleted from SwiftData in the success path — only the
in-memory `notes[]` would be updated (if the function compiled). On next launch `loadNotes`
would purge the pending-spend note correctly, but the success path is unclean.

**Fix:** Define the helper (mirrors the inline removal pattern in `executeUnshield`):

```swift
private func removeNote(_ note: Note) {
    if let idx = notes.firstIndex(where: {
        $0.value == note.value && $0.asset_id == note.asset_id &&
        $0.memo  == note.memo  && $0.owner_ivk == note.owner_ivk
    }) {
        notes.remove(at: idx)
    }
    let ctx = persistence.context
    let netId = activeNetworkId
    let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
    if let stored = (try? ctx.fetch(desc))?.first(where: {
        $0.value == note.value && $0.asset_id == note.asset_id &&
        $0.memo  == note.memo  && $0.owner_ivk == note.owner_ivk
    }) {
        ctx.delete(stored)
        try? ctx.save()
    }
}
```

---

### BUG H-3 — HIGH: `isNullifierSpent` selector uses SHA3-256 instead of Keccak-256

**File:** `ios/StarkVeil/StarkVeil/Core/RPCClient.swift:400–402`

```swift
// Keccak-250 of "is_nullifier_spent".
// python3: hex(int(hashlib.sha3_256(b'is_nullifier_spent').hexdigest(),16) & ((1<<250)-1))
let selector = "0x243759dd8b145b290cb0ebd7289fcba6c154362acb1c778339ec59a2be5527b"
```

Starknet function selectors are defined as
`keccak256(function_name) & (2^250 - 1)` using **Ethereum's Keccak-256**, not NIST SHA3-256.
Python's `hashlib.sha3_256` computes NIST SHA3, which produces a different digest.

If the selector is wrong, `starknet_call` returns an error, `try?` converts it to `nil`,
and `isNullifierSpent` returns `false` (fail-open). The client-side double-spend pre-check
is permanently disabled. The on-chain contract check remains authoritative, but users waste
gas on transactions for already-spent nullifiers without a friendly pre-flight error.

**Fix:** Compute the correct Keccak-250 selector:

```python
from eth_hash.auto import keccak
name = b"is_nullifier_spent"
print(hex(int.from_bytes(keccak(name), 'big') & ((1 << 250) - 1)))
```

Apply the same correction to `shieldSelector` (line 591) and `unshieldSelector` (line 424)
in `WalletManager.swift`, verifying each against the actual deployed Cairo ABI.

---

### BUG H-4 — HIGH: Recipient address used as `ownerPubkey` — received notes unspendable

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:731–735`

```swift
let outputCommitment = try StarkVeilProver.noteCommitment(
    value: inputNote.value,
    assetId: inputNote.asset_id,
    ownerPubkey: recipientAddress,  // ← Starknet account address, not EC public key
    nonce: outputNonce
)
```

When the recipient later calls `executeUnshield`, their commitment is recomputed at line
383–388 with `ownerPubkey: keys.publicKey.hexString` — the STARK EC public key. In Starknet,
an account address is `Pedersen(classHash, publicKey, salt, ...)` and is **not equal** to the
EC public key. The recomputed commitment will not match the on-chain commitment, producing a
wrong nullifier that the contract rejects. Received funds are permanently unspendable.

**Fix:** The `PrivateTransferView` already collects the recipient's IVK. Extend it to also
collect the recipient's **public key** (not address). Alternatively, establish a convention
that the `ownerPubkey` field always stores the account address consistently in both shield and
spend paths (update `executeUnshield` to use `senderAddress` as `ownerPubkey` instead of the
EC key, and adjust the Rust commitment function accordingly).

---

### BUG M-1 — MEDIUM: `try?` in SyncEngine silently drops malformed-ciphertext notes

**File:** `ios/StarkVeil/StarkVeil/Core/SyncEngine.swift:201`

```swift
if let plain = try? NoteEncryption.decryptMemo(encHex, ivkHex: ivkHex) {
    decryptedMemo = plain
} else {
    continue   // treated as "not our note"
}
```

`NoteEncryption.decryptMemo` has two distinct failure modes:

- Returns `nil` — GCM authentication failed; note is not addressed to this wallet ✓
- Throws `NoteEncryptionError.invalidCiphertext` — hex is malformed ✗

`try?` collapses both to `nil`. A note shielded by this wallet but stored on-chain with a
malformed `encrypted_memo` (due to C-5 calldata bug, sequencer encoding, or a data-length
truncation) is treated as "not ours" and skipped forever. Balance disappears with no error.

**Fix:**

```swift
do {
    if let plain = try NoteEncryption.decryptMemo(encHex, ivkHex: ivkHex) {
        decryptedMemo = plain               // successfully decrypted → our note
    } else {
        continue                            // nil = wrong key → not our note
    }
} catch {
    // Structural error — unknown note format; log and accept with fallback memo
    // so funds are not silently lost if on-chain encoding has a bug.
    print("[SyncEngine] Ciphertext parse error for \(commitment): \(error)")
    decryptedMemo = "Shielded: \(commitment.prefix(10))…"
}
```

---

### BUG M-2 — MEDIUM: Private transfer exposes memo as plaintext on encryption failure

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:739–742`

```swift
let encryptedMemo = (try? NoteEncryption.encryptMemo(
    memo.isEmpty ? "private transfer" : memo,
    ivkHex: recipientIVK
)) ?? Data(memo.utf8).hexString   // ← plaintext UTF-8 hex on failure
```

If AES encryption fails, the user's private memo (or the default "private transfer" tag) is
hex-encoded and placed in calldata in plaintext. Any full-node operator permanently sees the
content. The fallback violates the confidentiality guarantee of private transfers.

**Fix:** Make the encryption non-optional and propagate the throw:

```swift
let encryptedMemo = try NoteEncryption.encryptMemo(
    memo.isEmpty ? "private transfer" : memo,
    ivkHex: recipientIVK
)
```

---

### BUG M-3 — MEDIUM: Cold-start sync scans only last 10 blocks

**File:** `ios/StarkVeil/StarkVeil/Core/SyncEngine.swift:149–150`

```swift
let fromBlock = currentBlock == 0 ? max(0, latestBlock - 10) : currentBlock + 1
```

When no checkpoint exists (`currentBlock == 0`), the engine scans only the 10 most recent
blocks. A user inactive for more than ~5 minutes on Sepolia (blocks ≈ 30 s) misses notes in
between, resulting in missing balance with no error.

**Fix:** Store a `walletCreationBlock` in Keychain during onboarding and use it as the default
scan start:

```swift
let walletBirth = KeychainManager.walletCreationBlock() ?? 0
let fromBlock = currentBlock == 0 ? walletBirth : currentBlock + 1
```

---

### BUG M-4 — MEDIUM: Two incompatible encryption schemes coexist

**Files:** `NoteEncryption.swift:58`, `NoteDecryptor.swift:30`

```swift
// NoteEncryption.swift — global per-wallet key
let info = Data("note-enc-v1".utf8)

// NoteDecryptor.swift — per-note key (commitment-specific)
let info = Data((commitment + "starkveil-note-ivk").utf8)
```

These are cryptographically incompatible: a note encrypted with `NoteDecryptor.encrypt`
cannot be decrypted by `NoteEncryption.decryptMemo` and vice versa. SyncEngine uses
`NoteEncryption.decryptMemo`. If any past code path used `NoteDecryptor`, those notes will
never appear in the wallet.

**Fix:** Delete `NoteDecryptor.swift`. The per-note subkey scheme in `NoteDecryptor` is
cryptographically stronger (provides note-specific key isolation); if adopting it, migrate
all paths uniformly.

---

### BUG M-5 — MEDIUM: `free_rust_string` double-free is undefined behaviour

**File:** `prover/src/lib.rs:361–364`

```rust
pub unsafe extern "C" fn free_rust_string(s: *mut c_char) {
    if s.is_null() { return; }
    let _ = CString::from_raw(s);   // deallocates; pointer now dangling
}
```

A second call with the same pointer is heap UB (use-after-free). Rust's `CString::from_raw`
will attempt to access the already-freed allocation.

**Fix:** Document in the Swift FFI wrapper (`StarkVeilProver.swift`) that the pointer **must**
be nil-ised at the call site immediately after freeing. Use a `defer` pattern:

```swift
var ptr: UnsafeMutablePointer<CChar>? = fn(arg)
defer { free_rust_string(ptr); ptr = nil }
let json = ptr.map { String(cString: $0) } ?? ""
```

---

### BUG M-6 — MEDIUM: Optimistic `addNote` before shield confirmation

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift:640`

```swift
addNote(note)   // optimistic: fires regardless of whether tx is confirmed
```

If the shield transaction reverts (which it will due to C-5 until fixed), the user sees
positive balance that does not exist on-chain. The phantom note persists across restarts.

**Fix:** Call `pollUntilAccepted` before `addNote`:

```swift
let finality = await RPCClient().pollUntilAccepted(rpcUrl: rpcUrl, txHash: broadcastedHash)
guard case .accepted = finality else {
    throw NSError(domain: "StarkVeil", code: 30,
                  userInfo: [NSLocalizedDescriptionKey: "Shield transaction did not confirm."])
}
addNote(note)
```

---

### IVK derivation outside loop — SAFE ✓

**File:** `ios/StarkVeil/StarkVeil/Core/SyncEngine.swift:174–184`

IVK is derived **once** before the `for event in events` loop, with a Keychain fallback.
O(N) key-derivation-per-event bug from Phase 7 is confirmed fixed. ✓

### `isPendingSpend` reset in all error paths — SAFE ✓

**File:** `ios/StarkVeil/StarkVeil/Core/WalletManager.swift` (executeUnshield)

```swift
var didSuccessfullySubmit = false
defer {
    if !didSuccessfullySubmit {
        storedNote.isPendingSpend = false
        try? ctx.save()
    }
}
```

The `defer` block runs on every exit path (normal, throw, and early return). `didSuccessfullySubmit`
is only set to `true` after `addInvokeTransaction` returns without throwing. Any error between
`isPendingSpend = true` and the RPC call reverts the flag. ✓

### `isNullifierSpent` called before `generateTransferProof` — SAFE ✓

In `executeUnshield` (line 391–400) and `executePrivateTransfer` (line 725–726) the
on-chain nullifier check precedes proof generation. ✓

### KeychainManager returns `nil` on missing item — SAFE ✓

`masterSeed()` calls `load(account:)` which returns `nil` when `SecItemCopyMatching` returns
anything other than `errSecSuccess`. No fallback value is produced. ✓

### `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` on all items — SAFE ✓

All Keychain writes go through the single `store(_:account:)` helper (line 92–106) which
unconditionally sets `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. No item escapes to
iCloud backup. ✓

---

## Section 4 — Privacy Model

### Shield commitment → unshield nullifier linkability — SAFE ✓ (computationally)

On-chain an observer sees:
- `Shielded`: `(asset, amount, commitment, encrypted_memo)`
- `Unshielded`: `(recipient, amount, asset, nullifier)`

Linking requires `commitment → nullifier`. The nullifier is `Poseidon(commitment, sk)`.
Without `sk` (the spending key, which is never on-chain) the mapping is irreversible:
Poseidon is a one-way permutation with a 252-bit key space. ✓

### Deterministic nonce — duplicate commitment privacy break — see C-2

The deterministic scheme `Poseidon(IVK, value, asset)` also leaks: two identical commitments
prove they came from the same wallet. This is a **linkability** issue in addition to the
double-nullification correctness bug catalogued as C-2.

### Wrong/attacker-controlled recipient IVK scenario

If the sender uses an attacker-controlled IVK in `PrivateTransferView`:

- The output commitment uses `ownerPubkey: recipientAddress` (line 734), which is the
  real recipient's address. The attacker cannot spend the funds.
- The AES key is `HKDF(attackerIVK)`. The attacker decrypts the memo content.

Confidentiality of the memo is broken; fund safety is maintained. See I-2.

### `encrypted_memo` field length — see I-1

AES-GCM adds exactly 28 bytes of overhead (12-byte nonce + 16-byte tag) plus the plaintext
length. The `felt252` on-chain stores the ciphertext as a hex string; its length directly
reveals the plaintext length. Observers can distinguish "shielded deposit" (16 bytes) from
custom memos by ciphertext length. **Mitigation:** pad memos to a fixed block size.

### SyncEngine timing side-channels — SAFE ✓

IVK decryption is performed entirely off the main thread inside a `Task`. All decoded notes
are batched into a single `decodedNotes` array and delivered to the main actor in one
`await MainActor.run` call. No per-note observable timer or UI update occurs mid-loop. ✓

---

## Section 5 — Integration Path to Stwo

### Mock proof probe points

| Location | File | Line | Change required |
|---|---|---|---|
| `generate_transfer_proof` — mock bytes | `lib.rs` | 337–341 | Replace with real Stwo proof bytes; add Merkle witness inputs (`leaf_position`, `merkle_path: [felt252; 20]`) to the `Note` struct |
| `verify_proof` stub | `privacy_pool.cairo` | 58–64 | Replace body with `IStwoVerifier.verify(proof, public_inputs)` call |
| `private_transfer` public inputs | `privacy_pool.cairo` | 187–202 | Apply H-6 fix (accept `historic_root` param; validate against `historic_roots` map) |
| `unshield` public inputs | `privacy_pool.cairo` | 244–249 | Apply L-5 fix (add `historic_root`; add Merkle membership proof) |
| Swift call sites | `WalletManager.swift` | 239, 403, 763 | Pass Merkle witness (fetched from `mt_nodes` RPC) into `generateTransferProof` |
| `Note` struct | `prover/src/types.rs` + `StarkVeilProver.swift` | — | Add `merkle_path`, `leaf_position`, `owner_pubkey` to both Rust and Swift structs (fixes L-NOTE-STRUCT-MISMATCH from Phase 7) |

### `verify_proof` hook quality — CLEAN ✓

The stub already has the correct signature:
`fn verify_proof(ref self: ContractState, proof: Span<felt252>, public_inputs: Span<felt252>) -> bool`

Stwo's on-chain verifier accepts exactly this interface. The function body is the only thing
that needs replacing; no external interface redesign is required for the verifier itself. The
surrounding changes (H-6 historic root, L-5 membership proof) affect the *callers* of
`verify_proof`, not the function signature.

### What a real Stwo circuit needs from the FFI

```
Input per note:
  value:          felt252
  asset_id:       felt252
  owner_pubkey:   felt252   (EC public key, not address)
  nonce:          felt252   (random, stored in note)
  spending_key:   felt252
  leaf_position:  u32
  merkle_path:    [felt252; 20]   (sibling hashes root→leaf)

Global inputs:
  historic_root:  felt252
  output_notes:   [{value, asset_id, owner_pubkey, nonce}]   (sender-specified)

Output:
  proof:          Vec<felt252>   (Stwo FRI proof)
  nullifiers:     Vec<felt252>   (computed by circuit, not by Swift)
  new_commitments:Vec<felt252>   (computed by circuit, not by Swift)
```

---

## Low / Info Findings

### L-2 — Dedup guard breaks after C-2 fix

**File:** `WalletManager.swift:132–137`

```swift
let isDuplicate = notes.contains {
    $0.value == note.value && $0.asset_id == note.asset_id &&
    $0.owner_ivk == note.owner_ivk && $0.memo == note.memo
}
```

After C-2 is fixed (random nonces), two notes with identical `(value, asset, ivk, memo)` but
different nonces are distinct. The current guard would incorrectly drop the second. Post-C-2,
deduplicate on the Poseidon commitment hash, which is unique per note.

### L-3 — No activity event for private-to-private transfers

**File:** `WalletManager.swift:780–785`

`executePrivateTransfer` (RPC path) returns `broadcastedHash` without calling `logEvent`.
The Activity tab shows no record of the transfer. Add `logEvent(kind: .transfer, ...)` before
the `return`.

### L-4 — Comment misidentifies domain separator bytes

**File:** `lib.rs:263`

```rust
// = 0x537461726b5665696c20494b4b2076 31 (hex of the ASCII string)
```

`494b4b` decodes to "IKK"; the code has `494b56` (I-K-V). Neither is correct ("IVK" = `49564b`).
Update the comment when applying the C-3 fix.

### I-1 — Memo length leaks approximate plaintext size

AES-GCM overhead is exactly 28 bytes. `felt252` on-chain encodes as hex. The ciphertext length
directly reveals plaintext length. Mitigation: pad all memos to a fixed size (e.g., 128 bytes)
before encryption.

### I-2 — Attacker-controlled recipient IVK leaks memo

If a user is social-engineered into using an attacker's IVK as the recipient's key, the
attacker decrypts the memo (AES key = HKDF(attacker IVK)). The output commitment still uses
`recipientAddress` as `ownerPubkey`, so funds remain safe. Mitigation: display a warning in
`PrivateTransferView` to verify the IVK out-of-band (QR code or secure channel).

### I-3 — SyncEngine timing is safe

Decryption batches entirely off main thread; all results emitted in a single `MainActor.run`.
No per-note observable delay. ✓
