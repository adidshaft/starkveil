# StarkVeil Security Audit — Phases 9–20
**Audited:** 2026-03-06
**Scope:** All code changes since the Phase 8 audit cutoff
**Files reviewed:** `prover/src/lib.rs`, `ios/.../StarkVeilProver.swift`, `ios/.../NoteEncryption.swift`, `ios/.../WalletManager.swift`, `ios/.../SyncEngine.swift`, `ios/.../RPCClient.swift`, `ios/.../StarknetTransactionBuilder.swift`, `contracts/src/privacy_pool.cairo`

---

## CRITICAL (5 findings)

---

### [C-1] `verify_proof` is a trivially forgeable hash-chain — not a STARK verifier

**File:** `contracts/src/privacy_pool.cairo:76–150`
**Impact:** Anyone can drain the privacy pool without possessing a spending key or Merkle witness.

The `verify_proof` function described as "Real Stwo STARK proof verification" is actually a chain of five Poseidon consistency checks between fields that the caller supplies. It checks:

```cairo
decommitment_hash == Poseidon(constraint_hash, trace_hash)
fri_alpha         == Poseidon(decommitment_hash, historic_root)
fri_layer_0       == Poseidon(fri_alpha, constraint_hash)
fri_layer_1       == Poseidon(fri_alpha, trace_hash)
fri_final         == Poseidon(fri_layer_0, fri_layer_1)
```

There is no circuit constraint evaluation, no FRI proximity test, no Merkle decommitment to an evaluation domain, and no binding to actual note values, Merkle paths, spending keys, or nullifiers. Any caller can construct an attack proof in O(5 Poseidon calls):

```python
# Attacker forgery — no private knowledge required
constraint_hash    = random_felt()
trace_hash         = random_felt()
decommitment_hash  = poseidon(constraint_hash, trace_hash)
fri_alpha          = poseidon(decommitment_hash, any_historic_root)
fri_layer_0        = poseidon(fri_alpha, constraint_hash)
fri_layer_1        = poseidon(fri_alpha, trace_hash)
fri_final          = poseidon(fri_layer_0, fri_layer_1)
proof = [8, constraint_hash, trace_hash, decommitment_hash,
         fri_alpha, fri_layer_0, fri_layer_1, fri_final]
```

The `_proof_commitment` (line 146) is computed but **never compared to anything**. The function returns `true` unconditionally for any self-consistent tuple.

**Additionally**, even if the circuit check were real, the function only binds `public_inputs[0]` (the historic root) to the FRI alpha. `public_inputs[1..n]` (nullifiers, commitments, amount, recipient, asset) are appended into the array but never consumed during verification. The amount, recipient, and asset for `unshield` are entirely unbound.

**Patch:** Replace with a real on-chain STARK verifier (e.g., the Stone/Stwo verifier contract deployed by StarkWare), or until then, lock the contract to a whitelist of trusted proof signers as a bridge mechanism. The MVP stub must **not** be deployed to mainnet in its current state.

```cairo
// TEMPORARY: replace verify_proof with a signature-based whitelist
// until the real Stwo verifier library is available on-chain.
fn verify_proof(ref self: ContractState, proof: Span<felt252>, public_inputs: Span<felt252>) -> bool {
    // proof[0] = operator_signature_r
    // proof[1] = operator_signature_s
    // The operator signs Poseidon(public_inputs) off-chain using the trusted prover key.
    assert(proof.len() >= 2, 'Proof too short');
    let pi_hash = poseidon_hash_span(public_inputs);
    let r = *proof.at(0);
    let s = *proof.at(1);
    // verify ECDSA(trusted_operator_pubkey, pi_hash, r, s)
    // — requires importing starknet::ecdsa::check_ecdsa_signature
    starknet::secp256r1::check_ecdsa_signature(pi_hash, TRUSTED_OPERATOR_PUBKEY, r, s)
}
```

---

### [C-2] Wrong RPC selector for `isNullifierSpent` — check always silently passes

**File:** `ios/.../RPCClient.swift:569`
**Impact:** The client-side double-spend guard is permanently bypassed. Attempting to spend an already-spent note will succeed through the iOS wallet until the transaction reverts on-chain.

```swift
// CURRENT — WRONG
let selector = "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e"
```

The hex `0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e` is `sn_keccak("balanceOf")` — the ERC-20 balance function. This selector is correctly used in `getSTRKBalance` and `getETHBalance`, but is **wrong** for `is_nullifier_spent` on the PrivacyPool contract. The PrivacyPool does not implement `balanceOf`, so `starknet_call` returns an error, the `guard let first = response.result?.first` guard fails, and the function returns `false` (not spent), regardless of the actual on-chain state.

**Patch:**
```swift
// Compute once: sn_keccak("is_nullifier_spent")
// = 0x5e01f1c3b1c57afe89da7eb88e0b0cca3a34afe84b6d1893e6e5df67a13c68c
let selector = "0x5e01f1c3b1c57afe89da7eb88e0b0cca3a34afe84b6d1893e6e5df67a13c68c"
```

> **Verification step:** Confirm via `starkli selector is_nullifier_spent` or `python3 -c "from starkware.cairo.lang.compiler.identifier_definition import *; from starkware.starknet.core.os.contract_hash import *; print(hex(get_selector_from_name('is_nullifier_spent')))"` before deploying.

---

### [C-3] `Int` overflow silently drops shielded deposits > ~9.22 STRK

**File:** `ios/.../SyncEngine.swift:219`
**Impact:** Any single shielded deposit exceeding ~9.22 STRK (Int.max ÷ 1e18) produces `nil` from the `Int()` initializer on the amount hex. The `guard … else { continue }` silently skips the event. The note is never added to the wallet, permanently hiding those funds.

```swift
// CURRENT — WRONG
guard let amountInt = Int(amountHex.replacingOccurrences(of: "0x", with: ""), radix: 16) else { continue }
let amountDouble = Double(amountInt) / 1e18
```

`Int.max` on 64-bit iOS = 9,223,372,036,854,775,807 ≈ 9.22 × 10¹⁸ wei = **9.22 STRK**. Any deposit above this value silently vanishes from the UTXO set.

Also, `amount.high` (event.data[2]) is completely ignored. For any u256 amount where `amount.high > 0` the displayed balance is silently truncated.

**Patch:**
```swift
// Replace Int parsing with UInt64 + Decimal for amounts
let amountLowHex  = event.data[1]
let amountHighHex = event.data[2]

// Parse low 128 bits safely via Decimal (no overflow for u128)
let lowStr  = amountLowHex.hasPrefix("0x")  ? String(amountLowHex.dropFirst(2))  : amountLowHex
let highStr = amountHighHex.hasPrefix("0x") ? String(amountHighHex.dropFirst(2)) : amountHighHex

var weiDecimal = Decimal(0)
for ch in lowStr {
    weiDecimal *= 16
    if let d = Int(String(ch), radix: 16) { weiDecimal += Decimal(d) }
}
// If amount.high != "0x0", add: weiDecimal += highValue * 2^128
// (amounts > 2^128 wei are astronomically large; treat as u128 for now)
guard weiDecimal > 0 else { continue }
let amountDouble = NSDecimalNumber(decimal: weiDecimal / Decimal(sign: .plus, exponent: 18, significand: 1)).doubleValue

// For rawWei, store as Decimal string to avoid u64 truncation:
let rawWei = (weiDecimal as NSDecimalNumber).stringValue
```

---

### [C-4] `StoredNote` missing `leaf_position` and `merkle_path` — all spends fail after app restart

**File:** `ios/.../Models/StoredNote.swift:14–44`, `ios/.../Core/StarkVeilProver.swift:18–21`
**Impact:** 100% of shielded transfer and unshield operations fail after the first app relaunch. The Rust FFI returns `"Input note 0 missing required field: leaf_position"` for every note loaded from SwiftData persistence.

`StoredNote` does not store `leaf_position` or `merkle_path`. `StoredNote.toNote()` reconstructs a `Note` with both fields as `nil`. The prover in `lib.rs:390–397` requires them:

```rust
let leaf_pos = match note.leaf_position {
    Some(p) => p,
    None => return ffi_error(&format!("Input note {} missing required field: leaf_position", i)),
};
```

Additionally, `executeUnshield` (WalletManager) calls `StarkVeilProver.generateTransferProof` instead of `generateUnshieldProof`, using a `TransferPayload` shape where an `UnshieldPayload` is required.

**Patch — StoredNote.swift:**
```swift
@Model final class StoredNote {
    // … existing fields …
    var leafPosition: Int?          // u32 Merkle leaf index from the Shielded event
    var merklePathJSON: String?     // JSON array of 20 sibling hashes, stored as String

    init(from note: Note, networkId: String, commitment: String = "",
         leafPosition: Int? = nil, merklePath: [String]? = nil) {
        // … existing assignments …
        self.leafPosition   = leafPosition
        self.merklePathJSON = merklePath.flatMap { try? JSONEncoder().encode($0) }
                                        .flatMap { String(data: $0, encoding: .utf8) }
    }

    func toNote() -> Note {
        let path = merklePathJSON
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        return Note(value: value, asset_id: asset_id, owner_ivk: owner_ivk,
                    owner_pubkey: owner_pubkey, nonce: nonce, spending_key: nil,
                    memo: memo, leaf_position: leafPosition.map { UInt32($0) },
                    merkle_path: path)
    }
}
```

**Patch — SyncEngine.swift** (populate leaf_position from event):
```swift
// event.data[4] = leaf_index (u32)
let leafIndex = event.data.count >= 5
    ? Int(event.data[4].replacingOccurrences(of: "0x", with: ""), radix: 16)
    : nil
// Pass leafIndex when inserting into WalletManager, then persist via StoredNote(leafPosition: leafIndex)
```

---

### [C-5] `clampToFelt252` masks only top 3 bits — produces invalid felt252 values

**File:** `ios/.../Core/WalletManager.swift` (static func `clampToFelt252`)
**Impact:** Private keys, IVKs, and commitment inputs outside the valid felt252 range `[0, p)` are passed to the Rust FFI, causing `FieldElement::from_hex_be` to reject them (`felt_from_hex` returns an error).

The STARK field prime `p = 2^251 + 17×2^192 + 1`. A valid felt252 must be `< p`. Masking only the top **3 bits** of a 256-bit value (byte[0] `&= 0x1F`) allows values up to `2^253 − 1`, which can be up to `2^253 / p ≈ 4` times larger than `p`. Roughly 75% of 32-byte random values with the top 3 bits cleared can still exceed `p` and are invalid felt252s.

The Rust signing loop correctly masks **5 bits** (`k_bytes[0] &= 0x07`, guaranteeing `k < 2^251 < p`). The Swift side must match.

**Patch:**
```swift
static func clampToFelt252(_ hexStr: String) -> String {
    let raw = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
    let padded = String(repeating: "0", count: max(0, 64 - raw.count)) + raw
    guard var bytes = Data(hexString: padded), bytes.count == 32 else { return hexStr }
    // Clear top 5 bits — guarantees value < 2^251 < p (STARK field prime)
    // This is the same mask used in lib.rs stark_sign_transaction for k generation.
    bytes[0] &= 0x07
    return "0x" + bytes.map { String(format: "%02x", $0) }.joined()
}
```

---

## HIGH (5 findings)

---

### [H-1] V3 resource bound name not padded to 15 hex chars — all transaction hashes wrong

**File:** `ios/.../Core/StarknetTransactionBuilder.swift:194`
**Impact:** Every V3 INVOKE and DEPLOY_ACCOUNT transaction hash produced by the app is incorrect. The sequencer rejects them with an invalid signature error.

Per the Starknet V3 spec, each resource bound field is encoded as a 252-bit felt with layout:

```
resource_name[60 bits] | max_amount[64 bits] | max_price_per_unit[128 bits]
= 15 hex chars         | 16 hex chars        | 32 hex chars
= 63 hex chars total = 252 bits
```

The current code:
```swift
let nameHex = String(name, radix: 16)   // "4c315f474153" = 12 chars (48-bit), NOT 15 chars
return "0x" + nameHex + amountPadded + pricePadded  // produces 60 hex = 240 bits WRONG
```

For `L1_GAS_NAME = 0x4c315f474153` (48-bit), the name occupies 12 hex chars instead of the required 15. The entire field is shifted, producing a wrong felt252 value with a different transaction hash.

**Patch:**
```swift
static func encodeResourceBound(name: UInt64, bound: ResourceBound) -> String {
    let amountHex = bound.max_amount.hasPrefix("0x")
        ? String(bound.max_amount.dropFirst(2)) : bound.max_amount
    let priceHex = bound.max_price_per_unit.hasPrefix("0x")
        ? String(bound.max_price_per_unit.dropFirst(2)) : bound.max_price_per_unit

    let amountPadded = String(repeating: "0", count: max(0, 16 - amountHex.count)) + amountHex
    let pricePadded  = String(repeating: "0", count: max(0, 32 - priceHex.count))  + priceHex

    // FIX: pad name to exactly 15 hex chars (60 bits) per Starknet V3 spec
    let rawName = String(name, radix: 16)
    let namePadded = String(repeating: "0", count: max(0, 15 - rawName.count)) + rawName

    // 15 + 16 + 32 = 63 hex chars = 252 bits = valid felt252
    return "0x" + namePadded + amountPadded + pricePadded
}
```

---

### [H-2] IVK stored as `owner_pubkey` in SyncEngine notes — Merkle witness mismatch

**File:** `ios/.../Core/SyncEngine.swift:232, 275`
**Impact:** Any note detected by `SyncEngine` (i.e., any note received after the UTXO was created by another device, or after an app reinstall) cannot be spent. The ZK prover computes `commitment = Poseidon(value, asset_id, clampedIVK, nonce)` using the wrong `owner_pubkey`, which differs from the actual Merkle leaf. The Merkle path verification inside the circuit immediately fails.

```swift
// CURRENT — WRONG for both Shielded and Transfer events
let clampedIVK = WalletManager.clampToFelt252(ivkHex)
let note = Note(
    ...
    owner_pubkey: clampedIVK,   // ← IVK, not the STARK EC public key
    nonce: commitment,          // ← on-chain commitment stored as nonce
    ...
)
```

The on-chain commitment was computed as `Poseidon(value, asset_id, stark_pubkey, original_nonce)`. When spending, the prover recomputes `Poseidon(value, asset_id, clampedIVK, on_chain_commitment)` — a different value, causing a Merkle path mismatch.

**Patch:** Derive the STARK public key from the spending key and store it as `owner_pubkey`:
```swift
// After deriving ivkHex, also derive the STARK public key once:
let starkPubKey: String
if let spendingKey = try? StarkVeilProver.starkPublicKey(privateKeyHex: clampedPrivKey) {
    starkPubKey = spendingKey
} else {
    // Fallback to IVK if pubkey derivation fails (watch-only mode)
    starkPubKey = clampedPrivKey
}

let note = Note(
    value: rawWei,
    asset_id: "0x5354524b",
    owner_ivk: ivkHex,
    owner_pubkey: starkPubKey,   // FIX: actual EC public key
    nonce: originalNonce,        // FIX: must be the original nonce, NOT the commitment
    spending_key: nil,
    memo: decryptedMemo ?? "Shielded deposit"
)
```

> **Design note:** The original nonce is not recoverable from on-chain data alone unless it is included in the encrypted memo. Phase 21 must encrypt `(value, nonce)` or `(value, owner_pubkey, nonce)` into `encrypted_memo` so that the recipient can reconstruct the witness. Without this, spending notes from other devices is architecturally impossible.

---

### [H-3] `executeUnshield` calls `generateTransferProof` instead of `generateUnshieldProof`

**File:** `ios/.../Core/WalletManager.swift` (executeUnshield, ~line 497)
**Impact:** The unshield flow uses the wrong FFI function and an incorrect payload type. `generateTransferProof` returns `TransferPayload{proof, nullifiers[], new_commitments[], fee, historic_root}`, but `unshield` on-chain expects a single `nullifier` felt (not an array) and no `new_commitments`. The calldata built from the TransferPayload will cause the unshield transaction to revert.

Additionally, `generateTransferProof` requires `leaf_position` and `merkle_path` which are `nil` in the proof input note constructed in `executeUnshield`.

**Patch:**
```swift
// Replace in executeUnshield:
let unshieldResult = try await StarkVeilProver.generateUnshieldProof(
    note: proofInputNote,
    amountLow:     amountLow,
    amountHigh:    "0x0",
    recipient:     recipient,
    asset:         safeAssetId,
    historicRoot:  currentMerkleRoot   // fetch from RPCClient or note witness
)
// Then build calldata using unshieldResult.proof, unshieldResult.nullifier, unshieldResult.historic_root
```

---

### [H-4] `isPendingSpend` crash during proof generation orphans the UTXO

**File:** `ios/.../Core/WalletManager.swift` (loadNotes, executeUnshield, executePrivateTransfer)
**Impact:** If the app is force-killed after `isPendingSpend = true` is saved to SwiftData but before the signed transaction is submitted, `loadNotes()` at next launch deletes the flagged note permanently. The user loses the note from their UTXO set. The on-chain note still exists, but there is no recovery path in the app.

```swift
// loadNotes() — deletes any isPendingSpend=true note unconditionally on boot
let pending = all.filter { $0.isPendingSpend }
if !pending.isEmpty {
    pending.forEach { ctx.delete($0) }  // NOTE: crashes during proof generation lose UTXOs here
    do { try ctx.save() } catch { ... }
}
```

**Patch:** On reboot, attempt to verify on-chain whether the nullifier for the pending note was actually spent before deleting it:

```swift
func recoverPendingNotes(rpcUrl: URL, contractAddress: String) async {
    let ctx = persistence.context
    let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.isPendingSpend == true })
    guard let pending = try? ctx.fetch(desc), !pending.isEmpty else { return }
    for note in pending {
        guard !note.commitment.isEmpty else { ctx.delete(note); continue }
        guard let seed = KeychainManager.masterSeed(),
              let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else { break }
        let sk = WalletManager.clampToFelt252(keys.privateKey.hexString)
        guard let nullifier = try? StarkVeilProver.noteNullifier(commitment: note.commitment, spendingKey: sk) else {
            note.isPendingSpend = false; continue  // can't verify — keep note
        }
        let spent = await RPCClient().isNullifierSpent(rpcUrl: rpcUrl, contractAddress: contractAddress, nullifier: nullifier)
        if spent {
            ctx.delete(note)  // confirmed spent on-chain, safe to remove
        } else {
            note.isPendingSpend = false  // spend never landed, restore note
        }
    }
    try? ctx.save()
}
```

---

### [H-5] 32-bit compact memo auth tag is brute-forceable

**File:** `ios/.../Core/NoteEncryption.swift:165–169`
**Impact:** An adversary who knows a recipient's IVK (e.g., from a watch-only wallet share) can forge compact memo payloads with ~1/2³² success probability per attempt. With ~4 billion candidates, a motivated attacker can inject phantom notes (wrong value) into the wallet at ~1 note per 4B attempts.

```swift
// CURRENT — 4-byte truncation (32-bit security)
let authFull = HMAC<SHA256>.authenticationCode(for: Data(payload), using: aesKey)
let auth = Array(authFull.prefix(4))   // only 32 bits
```

**Patch:**
```swift
// Increase to 8 bytes (64-bit security) — requires adjusting compactPayloadSize from 27 to 23
// to keep the total at 31 bytes: auth(8) + payload(23) = 31 bytes
static let compactPayloadSize = 23   // 31 - 8 (auth tag)
static let authTagSize        = 8    // 64-bit security (was 4)

// In encryptCompact / decryptCompact: replace prefix(4) with prefix(authTagSize)
let auth = Array(authFull.prefix(authTagSize))
```

---

## MEDIUM (4 findings)

---

### [M-1] Nullifier double-spend check placed after `verify_proof` in Cairo

**File:** `contracts/src/privacy_pool.cairo:298–308`
**Impact:** When a nullifier is already spent, the contract still executes `verify_proof` (all its Poseidon hashes) before hitting the cheap `assert(!spent)` check. For a malicious front-run (attacker pre-spends the same nullifier in a prior block), the victim's transaction wastes gas on proof verification before reverting on the nullifier check. Correct ordering is: check nullifiers → verify proof → write nullifiers.

```cairo
// CURRENT (wrong order — proof check before nullifier check)
assert(self.verify_proof(proof.span(), public_inputs.span()), 'Invalid proof');
loop { // nullifier check happens here, AFTER proof
    assert(!self.nullifiers.read(nf), 'Note already spent');
    ...
};
```

**Patch:**
```cairo
fn private_transfer(ref self: ContractState, ...) {
    assert(self.historic_roots.read(historic_root), 'Invalid historic root');

    // 1. CHECK all nullifiers first (cheap storage reads — early revert)
    let mut check_i: u32 = 0;
    loop {
        if check_i == nullifiers.len() { break; }
        assert(!self.nullifiers.read(*nullifiers.at(check_i)), 'Note already spent');
        check_i += 1;
    };

    // 2. Build public inputs and verify proof
    let mut public_inputs = ArrayTrait::new();
    // ... build public_inputs as before ...
    assert(self.verify_proof(proof.span(), public_inputs.span()), 'Invalid proof');

    // 3. WRITE nullifiers (post-verification to prevent TOCTOU on single-tx reuse)
    let mut write_i: u32 = 0;
    loop {
        if write_i == nullifiers.len() { break; }
        self.nullifiers.write(*nullifiers.at(write_i), true);
        write_i += 1;
    };
    // ... insert commitments ...
}
```

---

### [M-2] HKDF extraction with empty salt weakens encryption key derivation

**File:** `ios/.../Core/NoteEncryption.swift:67`
**Impact:** RFC 5869 §3.1 states that when the IKM is not uniformly random (a felt252 has structural zeros), an empty salt reduces the HKDF extract phase to `HMAC-SHA256(0^32, ikm)`, which is less than ideal. A fixed non-zero salt provides free domain separation.

```swift
// CURRENT — empty salt
let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: Data())
```

**Patch:**
```swift
// Use a fixed domain salt (free domain separation, no secret needed)
let salt = Data("StarkVeil-NoteEnc-v1".utf8)
let prk  = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
```

This change is a breaking change to existing encrypted memos — all users must re-encrypt their note memos (or retain the old key derivation for decrypting legacy memos during a migration period).

---

### [M-3] RFC-6979 k generation creates a new DRBG per attempt — non-standard retry

**File:** `prover/src/lib.rs:199–238`
**Impact:** The retry loop re-instantiates `HmacDrbg` with `&extra = [attempt as u8]` for each failed attempt. This deviates from RFC 6979 §3.4, which specifies a single DRBG instance with repeated `generate` calls. The current approach is deterministic and secure, but:

1. It is **not** RFC-6979 compliant, which may cause interoperability issues with external tools that verify the nonce determinism.
2. `attempt` is a `u16` cast to `u8` — attempts 256–511 would overflow to the same byte as attempts 0–255, creating collision in additional data (unreachable in practice since 256 iterations is the hard cap).

```rust
// CURRENT
let extra = [attempt as u8];   // u16 → u8, wraps at 256 (unreachable limit)
let mut drbg = HmacDrbg::<Sha256>::new(&pk_bytes, &msg_bytes, &extra);
```

**Patch:** Follow RFC 6979 §3.4 exactly — single DRBG, loop on `generate` calls:

```rust
use rfc6979::generate_k;  // use the high-level API if available
// OR manually:
let k = generate_k::<Sha256, _>(&pk_bytes, &stark_order_bytes, &msg_bytes, b"");
```

If the `rfc6979` crate's `generate_k` function is available, it handles the retry loop internally per spec and is the preferred approach.

---

### [M-4] `encryptCompact` HMAC computed on plaintext, not ciphertext (encrypt-then-MAC violation)

**File:** `ios/.../Core/NoteEncryption.swift:164–169`
**Impact:** The 4-byte auth tag is computed on the **plaintext** payload (before XOR), not on the ciphertext. This is MAC-then-Encrypt order, which is the weaker construction. An attacker who observes multiple ciphertexts and performs a padding oracle can potentially recover plaintext bits incrementally without triggering auth failures in some edge cases. While the XOR stream cipher does not have a traditional padding oracle, MAC-then-Encrypt is considered deprecated (cf. TLS BEAST/POODLE).

**Patch:**
```swift
// Compute auth on the CIPHERTEXT, not the plaintext (Encrypt-then-MAC)
let cipherPayload = zip(payload, keystreamBytes).map { $0 ^ $1 }
let authFull = HMAC<SHA256>.authenticationCode(for: Data(cipherPayload), using: aesKey)
let auth = Array(authFull.prefix(authTagSize))
let result = auth + cipherPayload
```

Update `decryptCompact` to verify the tag against the ciphertext before XOR-decrypting.

---

## LOW (4 findings)

---

### [L-1] IVK printed in plaintext to debug console in production builds

**File:** `ios/.../Core/SyncEngine.swift:196`
**Impact:** The IVK is a sensitive value — it allows detection and decryption of all incoming notes. Logging it to the device console exposes it to anyone with physical or tooling access to the device.

```swift
print("[SyncEngine] decryptIVK=\(ivkHex)")  // leaks IVK on all builds
```

**Patch:**
```swift
#if DEBUG
print("[SyncEngine] decryptIVK=\(ivkHex.prefix(10))…")  // truncated in debug
#endif
```

---

### [L-2] `performRequestWithFallback` missing explicit timeout interval

**File:** `ios/.../Core/RPCClient.swift:88`
**Impact:** Unlike `performRequest` (which sets `timeoutInterval = 15`), `performRequestWithFallback` creates a bare `URLRequest` with no timeout. If the primary node hangs, the fallback never triggers within a reasonable time.

**Patch:**
```swift
var req = URLRequest(url: url)
req.httpMethod       = "POST"
req.httpBody         = body
req.timeoutInterval  = 15   // add explicit timeout, matching performRequest
req.setValue("application/json", forHTTPHeaderField: "Content-Type")
req.setValue("application/json", forHTTPHeaderField: "Accept")
```

---

### [L-3] `saveCheckpoint` silently swallows SwiftData errors

**File:** `ios/.../Core/SyncEngine.swift:111`
**Impact:** A SwiftData write failure leaves the checkpoint un-persisted. On next launch, the full 500-block re-scan executes and all events are re-emitted, potentially creating duplicate notes (mitigated but not fully eliminated by `addNote`'s dedup logic).

```swift
try? ctx.save()  // CURRENT — silent failure
```

**Patch:**
```swift
do {
    try ctx.save()
} catch {
    print("[SyncEngine] CRITICAL: checkpoint save failed for block \(block): \(error)")
}
```

---

### [L-4] Nullifier scheme changed from original spec without migration note

**File:** `prover/src/lib.rs:301–302`; `MEMORY.md`
**Impact:** The MEMORY.md architectural note states `Nullifier = Poseidon(spending_key, note_position)`. The Phase 15 implementation uses `Poseidon(commitment, spending_key)`. These are different schemes. Any tooling, audit tools, or external integrations that reference the MEMORY.md spec will derive wrong nullifiers.

**Patch:** Update MEMORY.md to reflect the implemented scheme and remove the stale reference:
```markdown
- Nullifier = Poseidon(commitment, spending_key)
  (Phase 15 implementation — changed from original Poseidon(spending_key, note_position) design)
```

---

## Summary

| ID  | Severity | Component          | Status |
|-----|----------|--------------------|--------|
| C-1 | CRITICAL | Cairo contract     | Open — deploy blocker |
| C-2 | CRITICAL | RPCClient.swift    | Open — fund-loss risk |
| C-3 | CRITICAL | SyncEngine.swift   | Open — fund-loss risk |
| C-4 | CRITICAL | StoredNote + WalletManager | Open — 100% spend failure |
| C-5 | CRITICAL | WalletManager.swift| Open — invalid felt252 keys |
| H-1 | HIGH     | TransactionBuilder | Open — all txs rejected |
| H-2 | HIGH     | SyncEngine.swift   | Open — proofs fail |
| H-3 | HIGH     | WalletManager.swift| Open — unshield broken |
| H-4 | HIGH     | WalletManager.swift| Open — UTXO orphaning |
| H-5 | HIGH     | NoteEncryption.swift| Open — forgeable memos |
| M-1 | MEDIUM   | Cairo contract     | Open |
| M-2 | MEDIUM   | NoteEncryption.swift| Open |
| M-3 | MEDIUM   | prover/src/lib.rs  | Open |
| M-4 | MEDIUM   | NoteEncryption.swift| Open |
| L-1 | LOW      | SyncEngine.swift   | Open |
| L-2 | LOW      | RPCClient.swift    | Open |
| L-3 | LOW      | SyncEngine.swift   | Open |
| L-4 | LOW      | MEMORY.md          | Open |

**Pre-mainnet blockers: C-1, C-2, C-3, C-4, H-1, H-2, H-3**

All CRITICAL and HIGH items must be resolved before any mainnet deployment or real-funds testnet exposure.
