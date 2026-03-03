# Phase 7 Security Audit — StarkVeil iOS (Phase 15 Privacy Primitives)

## Audit Prompt

Perform a comprehensive security, privacy, and correctness audit of the StarkVeil iOS wallet,
focusing on Phase 15 privacy primitives.

1. **Note Commitment Scheme** (lib.rs, StarkVeilProver.swift, NoteEncryption.swift)
   - Verify Poseidon(value, asset_id, owner_pubkey, nonce) matches the Cairo PrivacyPool contract spec
   - Verify nullifier = Poseidon(commitment, spending_key) is the correct scheme
   - Confirm the domain separator in stark_derive_ivk is collision-resistant and doesn't conflict with other Poseidon usages
   - Check IVK = Poseidon(sk, domain) can't be inverted to recover sk

2. **Note Encryption** (NoteEncryption.swift)
   - Verify HKDF-SHA256 key derivation is domain-separated correctly ("note-enc-v1")
   - Verify AES-256-GCM nonces are random (not derived from plaintext or key)
   - Confirm decryptMemo returns nil (not throws) on GCM auth failure
   - Check Data(hexString:) handles odd-length hex strings safely

3. **Double-Spend Prevention** (RPCClient.swift, WalletManager.swift)
   - Verify isNullifierSpent is called before proof generation, not after
   - Confirm storedNote.isPendingSpend is reset to false if the nullifier check fails
   - Check that the fail-open behavior (return false on RPC error) is documented and intentional

4. **Private Transfer** (WalletManager.executePrivateTransfer, PrivateTransferView.swift)
   - Verify the recipient IVK seed derivation won't collide with a real IVK
   - Confirm the output nonce is generated with SecRandomCopyBytes and clamped to STARK_PRIME
   - Check that removeNote() is only called after a successful broadcastedHash
   - Verify the transferSelector constant matches the deployed Cairo contract ABI

5. **SyncEngine Trial-Decryption** (SyncEngine.swift)
   - Confirm StarknetAccount.deriveAccountKeys is called off the main thread safely
   - Verify the continue (skip) on decryption failure doesn't cause owned notes to be silently dropped
   - Check the fallback to KeychainManager.ownerIVK() is correct

6. **FFI Memory Safety** (lib.rs, StarkVeilProver.swift)
   - Verify the new 4-arg stark_note_commitment and 2-arg stark_note_nullifier pointer lifetimes
   - Confirm free_rust_string is called exactly once per returned pointer

Files audited:
- prover/src/lib.rs
- prover/src/types.rs
- ios/StarkVeil/StarkVeil/Core/NoteEncryption.swift
- ios/StarkVeil/StarkVeil/Core/StarkVeilProver.swift
- ios/StarkVeil/StarkVeil/Core/RPCClient.swift
- ios/StarkVeil/StarkVeil/Core/WalletManager.swift
- ios/StarkVeil/StarkVeil/Core/SyncEngine.swift
- ios/StarkVeil/StarkVeil/Views/PrivateTransferView.swift

---

## Findings Summary

| ID | Severity | Location | Description |
|---|---|---|---|
| C-DOMAIN-SPACE | CRITICAL | lib.rs:264 | Literal space in IVK domain separator hex → always uses "IVK" fallback |
| C-COMMITMENT-MISMATCH | CRITICAL | WalletManager.swift | Shield uses Poseidon(ivk, nonce); transfer uses Poseidon(value,asset,pubkey,nonce) → impossible to spend |
| C-RECIPIENT-PRIVACY | CRITICAL | WalletManager.swift:692 | Recipient IVK seed = Poseidon([publicAddress]) — anyone can decrypt note memos |
| C-TRANSFER-SELECTOR | CRITICAL | WalletManager.swift:711 | transferSelector is a placeholder value, not a real Starknet keccak selector |
| H-PENDING-RESET | HIGH | WalletManager.swift:359–398 | isPendingSpend = true not reset on any error except alreadySpent → note purged on relaunch |
| H-SECRANDOM-UNCHECKED | HIGH | WalletManager.swift:694 | SecRandomCopyBytes return not checked → all-zero nonce on failure → deterministic commitment |
| H-IVK-FAIL-DROPS-NOTES | HIGH | SyncEngine.swift:187 | deriveIVK failure → ivkHex = "" → all encrypted notes silently dropped |
| H-NULLIFIER-ORDER | HIGH | WalletManager.swift:368–394 | isNullifierSpent called AFTER generateTransferProof → wasted proof generation |
| M-NONCE-REDERVIED-WRONG | MEDIUM | WalletManager.swift:677 | Input note nonce re-derived as Poseidon(ivk,value,asset) — mismatch with shield's random nonce |
| M-SELECTOR-WRONG-ALGO | MEDIUM | RPCClient.swift:403 | isNullifierSpent selector computed with wrong algorithm → always returns fail-open false |
| M-IVK-LOOP-PERF | MEDIUM | SyncEngine.swift:185 | deriveAccountKeys called O(N) times per tick inside event loop |
| M-DECRYPTED-UTF8 | MEDIUM | NoteEncryption.swift:95 | Non-UTF8 decrypted plaintext → decryptMemo returns nil → owned note silently dropped |
| M-TRANSFER-NO-PENDING | MEDIUM | WalletManager.swift:660 | executePrivateTransfer doesn't set isPendingSpend → crash risk between submit and removeNote |
| L-NOTE-STRUCT-MISMATCH | LOW | types.rs:8 / StarkVeilProver.swift:9 | Rust Note has owner_pubkey, Swift Note has owner_ivk → Rust always sees owner_pubkey = None |
| L-OLD-TRANSFER-PRESENT | LOW | WalletManager.swift:217 | Old executePrivateTransfer(recipient:amount:) still present — dead code / confusion risk |
| L-CALLSINGLEARG-RETTYPE | LOW | StarkVeilProver.swift:142 | callSingleArg fn param returns UnsafePointer not UnsafeMutablePointer |
| L-NULL-SALT-HKDF | LOW | NoteEncryption.swift:60 | HKDF.extract with salt: nil uses zero-key HMAC; acceptable for high-entropy IVK |
| L-OLDIVK-FALLBACK | LOW | SyncEngine.swift:188 | KeychainManager.ownerIVK() fallback uses pre-Phase15 IVK format, incompatible with new encryption |

---

## Q1 — Note Commitment Scheme

### BUG C-DOMAIN-SPACE — CRITICAL

**File:** `prover/src/lib.rs:264`

```rust
// BROKEN: literal ASCII space (0x20) inside the hex string
let domain = FieldElement::from_hex_be("0x537461726b5665696c20494b562076 31")
    .unwrap_or(FieldElement::from(0x494b56_u64));  // "IVK" fallback
```

`FieldElement::from_hex_be` rejects the string the moment it encounters the space character between `76` and `31`. The `unwrap_or` fallback silently substitutes `0x494b56` ("IVK" as ASCII). **Every IVK ever derived by this function is computed with the wrong domain constant.** Furthermore the intended string itself has a byte-order error:

Intended: `"StarkVeil IVK v1"` → ASCII hex:
```
53 74 61 72 6b 56 65 69 6c 20  49 56 4b  20 76 31
S  t  a  r  k  V  e  i  l  sp  I  V  K  sp  v  1
```
= `0x537461726b5665696c2049564b207631`

The code has `...20 49 4b 56 20 76 31` = "IKV v1" (bytes transposed: 4b=K before 56=V, not I-V-K).

**Fix — `prover/src/lib.rs`:**
```rust
// Correct ASCII hex for "StarkVeil IVK v1" with proper byte order
let domain = FieldElement::from_hex_be("0x537461726b5665696c2049564b207631")
    .expect("hardcoded IVK domain constant is always valid");
```

---

### BUG C-COMMITMENT-MISMATCH — CRITICAL

**File:** `WalletManager.swift`

`executeShield` sends the following as the on-chain commitment:
```swift
// WalletManager.swift:573 — 2-element scheme
let commitmentKey = try deriveNoteCommitmentKey(ivkHex: ivkHex, nonce: noteNonce)
// = StarkVeilProver.poseidonHash(elements: [ivkHex, noteNonce])
// = Poseidon(ivk, nonce)
```

But `executePrivateTransfer` recomputes the commitment for the same note as:
```swift
// WalletManager.swift:678 — 4-element scheme
let commitment = try StarkVeilProver.noteCommitment(
    value: inputNote.value,
    assetId: inputNote.asset_id,
    ownerPubkey: keys.publicKey.hexString,
    nonce: nonceFelt
)
// = Poseidon(value, asset_id, owner_pubkey, nonce)
```

These two computations produce **different values for the same note**. The Cairo contract stores the 2-element commitment from `shield()`. When `transfer()` or `unshield()` is called, the client derives a nullifier from the 4-element commitment — a commitment that was never inserted into the Merkle tree. Every spend of a shielded note will be permanently rejected by the contract verifier.

Additionally, `executePrivateTransfer` re-derives the nonce deterministically:
```swift
let nonceFelt = try StarkVeilProver.poseidonHash(elements: [ivkHex, inputNote.value, inputNote.asset_id])
```
The original note was shielded with a random 32-byte nonce (`noteNonce`). The re-derived nonce `Poseidon(ivk, value, asset)` is completely different. Even if the commitment scheme were unified, the nonces would not match.

**Fix** — Unify on the 4-element scheme everywhere. `executeShield` must compute and send `Poseidon(value, asset_id, owner_pubkey, nonce)` as the on-chain commitment, and the `StoredNote` must persist both the nonce and the owner_pubkey so `executePrivateTransfer` can reconstruct the exact same commitment.

**`WalletManager.swift` — executeShield, replace commitmentKey derivation:**
```swift
// Derive keys for commitment (needed for owner_pubkey)
guard let seed = KeychainManager.masterSeed() else {
    throw NSError(domain: "StarkVeil", code: 11,
                  userInfo: [NSLocalizedDescriptionKey: "Master seed not found."])
}
let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)

// 4-element canonical commitment matching the contract spec
let commitmentKey = try NoteEncryption.computeCommitment(
    valueFelt:      amountFeltHex,      // encode amount as felt252 hex
    assetIdFelt:    "0x5354524b",       // felt252("STRK")
    ownerPubkeyFelt: keys.publicKey.hexString,
    nonceFelt:      noteNonce
)
```

Persist `noteNonce` and `keys.publicKey.hexString` in `StoredNote` so `executePrivateTransfer` can look them up instead of re-deriving.

---

### Nullifier Scheme Analysis — SAFE ✓

`nullifier = Poseidon(commitment, spending_key)` (lib.rs:243) is sound:
- **Unique per note**: commitment is unique per shield operation ✓
- **Hiding**: without knowing `spending_key`, the nullifier is unlinkable to the commitment ✓
- **Not invertible**: Poseidon is a one-way function; 252-bit `sk` space makes brute force infeasible ✓
- **Not front-runnable**: the contract checks `!nullifier_set.contains(nullifier)` before accepting a spend ✓

---

### IVK Pre-image Security — SAFE ✓ (once C-DOMAIN-SPACE is fixed)

`IVK = Poseidon(sk, domain)`. With correct domain:
- One-way: cannot recover `sk` from `IVK` — Poseidon has no known inversion ✓
- Commitment-hiding: `IVK` does not reveal `sk` when shared with watch-only nodes ✓
- Domain-separated from nullifier (`Poseidon(commitment, sk)`) because the domain constant distinguishes the second input ✓

---

## Q2 — Note Encryption

### HKDF Domain Separation — SAFE ✓

```swift
// NoteEncryption.swift:58-61
let info = Data("note-enc-v1".utf8)
let prk  = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: nil)
let okm  = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: info, outputByteCount: 32)
```

`info = "note-enc-v1"` correctly domain-separates this key from any other HKDF usage. The IVK is a Poseidon hash output (252 bits of pseudo-random data), providing sufficient entropy as IKM even with `salt: nil`. ✓

**LOW note (L-NULL-SALT-HKDF):** RFC 5869 §2.2 recommends providing a salt when one is available; `salt: nil` causes HKDF-Extract to use HMAC with a zero-filled key. This is cryptographically acceptable for high-entropy IKM but non-ideal. A fixed salt like `Data("starkveil-note-enc-salt-v1".utf8)` would strengthen the extract step at no cost.

---

### AES-256-GCM Nonce Randomness — SAFE ✓

```swift
// NoteEncryption.swift:75
let sealedBox = try AES.GCM.seal(plaintext, using: key)
```

`AES.GCM.seal` with no `nonce:` parameter internally calls `AES.GCM.Nonce()`, which generates a cryptographically random 96-bit nonce using `SecRandomCopyBytes` on Apple platforms. The nonce is prepended to `sealedBox.combined` and recovered on decryption. ✓

---

### decryptMemo nil vs throw on GCM Auth Failure — SAFE ✓

```swift
// NoteEncryption.swift:92-99
do {
    let sealedBox = try AES.GCM.SealedBox(combined: combined)
    let plaintext = try AES.GCM.open(sealedBox, using: key)
    return String(data: plaintext, encoding: .utf8)
} catch {
    return nil  // GCM authentication failure = not addressed to us
}
```

Both `SealedBox(combined:)` and `AES.GCM.open` throw on MAC failure; both are caught and converted to `nil`. SyncEngine wraps calls in `try?` as an additional guard. ✓

### BUG M-DECRYPTED-UTF8 — MEDIUM

```swift
return String(data: plaintext, encoding: .utf8)  // returns Optional<String>
```

If the decrypted plaintext is valid AES-GCM (authentication succeeds) but contains non-UTF8 bytes, `String(data:encoding:)` returns `nil`. The caller receives `nil` → `try?` turns to `nil` → SyncEngine `continue` → **our own note is silently dropped.**

This can occur if a sender constructs the memo from binary data, or if a future note format stores a binary field as the "memo". The correct approach for this case is to use a base64 or hex fallback for non-UTF8 content.

**Fix — `NoteEncryption.swift`:**
```swift
// After successful AES.GCM.open:
if let text = String(data: plaintext, encoding: .utf8) {
    return text
}
// Valid decryption but non-UTF8 content — return a hex representation
// so SyncEngine doesn't drop the note
return "hex:" + plaintext.hexString
```

---

### Data(hexString:) Odd-Length Safety — SAFE ✓

```swift
// NoteEncryption.swift:136
guard clean.count % 2 == 0 else { return nil }
```

Odd-length hex strings return `nil`, not a crash. SyncEngine wraps in `try?` so `invalidCiphertext` throws are also swallowed. ✓

---

## Q3 — Double-Spend Prevention

### BUG H-NULLIFIER-ORDER — HIGH

**File:** `WalletManager.swift:368–394`

```swift
// Phase 15: isNullifierSpent is called AFTER the expensive proof generation
let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])  // line 368
// ...
let nullifier = result.nullifiers.first ?? "0x0"           // line 386

// Phase 15 Item 3: Check nullifier on-chain before building tx   // line 389 (comment is wrong)
let alreadySpent = await RPCClient().isNullifierSpent(...)  // line 390
```

The code comment says "before building tx" but proof generation has already happened. `generateTransferProof` is a blocking Rust FFI call (or will be when real proofs are integrated) — wasting potentially seconds of computation on a note that was already spent.

**Fix — `WalletManager.swift` — move nullifier check before proof generation:**
```swift
// Mark pending FIRST
storedNote.isPendingSpend = true
try ctx.save()

// Compute nullifier independently (no proof needed for the check)
let preCheckNullifier = try StarkVeilProver.noteNullifier(
    commitment: /* commitment from stored note */ storedNote.commitment,
    spendingKey: keys.privateKey.hexString
)
let alreadySpent = await RPCClient().isNullifierSpent(
    rpcUrl: rpcUrl, contractAddress: contractAddress, nullifierHex: preCheckNullifier
)
if alreadySpent {
    storedNote.isPendingSpend = false
    try? ctx.save()
    throw ProverError.noteAlreadySpent
}

// Only THEN generate proof
let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])
```

---

### BUG H-PENDING-RESET — HIGH

**File:** `WalletManager.swift:359–480`

`storedNote.isPendingSpend = true` is set at line 359. It is only reset to `false` in one path: the explicit `alreadySpent` check at line 396. Every other error path (proof generation throws, signing throws, network timeout, `getNonce` throws, `addInvokeTransaction` throws) exits through the `defer` block which only resets `isTransferInFlight` and `isUnshielding` — **not** `isPendingSpend`.

On the next app launch, `loadNotes` at line 77–85:
```swift
let pending = all.filter { $0.isPendingSpend }
if !pending.isEmpty {
    pending.forEach { ctx.delete($0) }  // permanently deleted
    ...
}
```
Any note that was mid-flight when a transient error occurred is **permanently destroyed** on the next launch — even though the on-chain nullifier was never published.

**Fix — `WalletManager.swift` — add a cleanup closure:**
```swift
// After storedNote.isPendingSpend = true and ctx.save():
// Use a local variable to track whether we successfully submitted
var didSuccessfullySubmit = false
defer {
    if !didSuccessfullySubmit {
        storedNote.isPendingSpend = false
        try? ctx.save()
    }
}

// ... proof generation, signing, RPC ...
let txHash = try await RPCClient().addInvokeTransaction(...)
didSuccessfullySubmit = true  // only set here — after confirmed broadcast

// ... delete storedNote and save normally ...
```

---

### isPendingSpend Reset on alreadySpent — SAFE ✓

```swift
if alreadySpent {
    storedNote.isPendingSpend = false
    try? ctx.save()
    throw ProverError.noteAlreadySpent
}
```

The reset does happen for the double-spend path. ✓

---

### Fail-Open Behavior — DOCUMENTED ✓

```swift
/// Returns false on any RPC error so we don't silently block legitimate spends;
/// the contract's on-chain check is the authoritative guard.
func isNullifierSpent(...) async -> Bool {
```

The intent is correctly documented. ✓

---

### BUG M-SELECTOR-WRONG-ALGO — MEDIUM

**File:** `RPCClient.swift:401–403`

```swift
// python3: hex(int(hashlib.sha3_256(b'is_nullifier_spent').hexdigest(),16) & ((1<<250)-1))
let selector = "0x1f2b8e3c2f4a9d3e7c8b1a0f6e5d4c3b2a190807060504030201009988776655"
```

Two problems:
1. The comment uses `hashlib.sha3_256` masked to 250 bits. Starknet function selectors use **`starknet_keccak`** — defined as `keccak256(name) & ((1<<250)-1)` — not SHA3-256.
2. The trailing bytes `...0302010099887766**55**` look like a sequential placeholder, not a real hash output.

Since the selector is wrong, every `isNullifierSpent` call queries a non-existent function selector. The contract returns an error → `try? await performRequest` returns `nil` → function returns `false` (fail-open). Double-spend prevention on the client side is **permanently disabled** — the contract is still the authoritative guard, but the client's pre-flight check never fires.

**Fix:** Compute the real selector offline. Using Python:
```python
from eth_hash.auto import keccak
name = b"is_nullifier_spent"
selector = int.from_bytes(keccak(name), 'big') & ((1 << 250) - 1)
print(hex(selector))
```
Substitute the result. Same correction needed for `transferSelector` and `shieldSelector` in `WalletManager.swift`.

---

## Q4 — Private Transfer

### BUG C-RECIPIENT-PRIVACY — CRITICAL

**File:** `WalletManager.swift:692, 705–708`

```swift
// "IVK seed" for recipient = Poseidon of their PUBLIC address
let recipientIVKSeed = try StarkVeilProver.poseidonHash(elements: [recipientAddress])

// Memo encrypted with this seed as the IVK
let encryptedMemo = (try? NoteEncryption.encryptMemo(memo, ivkHex: recipientIVKSeed))
    ?? Data(memo.utf8).hexString
```

`recipientAddress` is a public Starknet address — visible to every full-node operator and any blockchain scanner. Anyone who knows the recipient's address can compute `Poseidon([recipientAddress])` and use it to derive the exact same AES key, decrypting every encrypted note memo sent to that address.

This is a **complete break of note confidentiality** for private transfers. A private transfer memo is supposed to be readable only by the recipient. Instead, it is readable by anyone.

The correct scheme is: the sender must derive the recipient's actual IVK using a Diffie-Hellman-style shared secret. In Zcash/AZTEC-style protocols, this is done via an ephemeral keypair (the sender generates `ephemeral_sk`, computes `shared_secret = ECDH(ephemeral_sk, recipient_pubkey)`, and includes `ephemeral_pubkey` in the note ciphertext so the recipient can recompute the shared secret).

**Fix — High-level architecture (requires protocol change):**
```
sender generates: ephemeral_sk (random), ephemeral_pk = ephemeral_sk * G
shared_secret = stark_scalar_mult(ephemeral_sk, recipient_public_key)
enc_key = HKDF(shared_secret, info="note-enc-v1")
encrypted_note = AES-GCM(enc_key, plaintext)
calldata includes: ephemeral_pk || encrypted_note

recipient decryption:
shared_secret = stark_scalar_mult(recipient_sk, ephemeral_pk)
enc_key = HKDF(shared_secret, info="note-enc-v1")
plaintext = AES-GCM-decrypt(enc_key, encrypted_note)
```

This requires exposing a scalar multiply function in the Rust FFI. The `stark_get_public_key` function already does `privkey * G`; a 2-point function `scalar_mult(scalar, point_x)` is the additional primitive needed.

---

### BUG C-TRANSFER-SELECTOR — CRITICAL

**File:** `WalletManager.swift:711`

```swift
let transferSelector = "0x3a9b23a4e0c7d2b1f8e6d5c4b3a2918070605040302010099887766554433"
// keccak("transfer")
```

The trailing bytes `...0302010099887766554433` are sequential — this is clearly a placeholder and not a real Starknet selector. Any transaction submitted with this selector will call the wrong function on the contract (or revert with "entry point not found").

This renders `executePrivateTransfer` completely non-functional on any live network.

**Fix:** Compute with the correct algorithm:
```python
from eth_hash.auto import keccak
selector = int.from_bytes(keccak(b"transfer"), 'big') & ((1 << 250) - 1)
print(hex(selector))
```

---

### BUG H-SECRANDOM-UNCHECKED — HIGH

**File:** `WalletManager.swift:693–696`

```swift
var randomBytes = [UInt8](repeating: 0, count: 32)
SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)  // return value IGNORED
randomBytes[0] &= 0x07
let outputNonce = "0x" + randomBytes.map { String(format: "%02x", $0) }.joined()
```

If `SecRandomCopyBytes` fails (returns anything other than `errSecSuccess`), `randomBytes` stays all-zero. After the clamp mask, `outputNonce = "0x00...00"`. Two different transfers with the same `(value, asset_id, recipientAddress)` will produce the **same output commitment** — violating note uniqueness and causing the second one to be rejected by the contract's duplicate leaf check.

Compare with `executeShield` which correctly guards:
```swift
let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
guard status == errSecSuccess else {
    throw NSError(domain: "StarkVeil", code: 20, ...)
}
```

**Fix — `WalletManager.swift:693`:**
```swift
var randomBytes = [UInt8](repeating: 0, count: 32)
let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
guard status == errSecSuccess else {
    throw NSError(domain: "StarkVeil", code: 20,
                  userInfo: [NSLocalizedDescriptionKey: "SecRandomCopyBytes failed — cannot generate safe output nonce"])
}
randomBytes[0] &= 0x07
let outputNonce = "0x" + randomBytes.map { String(format: "%02x", $0) }.joined()
```

---

### removeNote() After Broadcast — SAFE ✓

```swift
// WalletManager.swift:737–748
let broadcastedHash = try await RPCClient().addInvokeTransaction(...)
// 7. Optimistically remove spent note
removeNote(inputNote)
```

`removeNote` is only reached if `addInvokeTransaction` returns without throwing. Any error from `getNonce`, `estimateInvokeFee` (never throws), `buildAndSign`, or `addInvokeTransaction` propagates up and `removeNote` is not called. ✓

---

### BUG M-NONCE-REDERIVED-WRONG — MEDIUM

**File:** `WalletManager.swift:677`

```swift
// "We use a nonce derived from the note's value + asset for determinism"
let nonceFelt = try StarkVeilProver.poseidonHash(elements: [ivkHex, inputNote.value, inputNote.asset_id])
```

The original note's commitment was created in `executeShield` with a **cryptographically random** 32-byte nonce:
```swift
// executeShield:
var randomBytes = [UInt8](repeating: 0, count: 32)
let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
...
let noteNonce = "0x" + randomBytes.map { ... }
```

The re-derived nonce `Poseidon(ivk, value, asset)` will be a completely different value from the original random nonce. Even after fixing C-COMMITMENT-MISMATCH (unifying on the 4-field scheme), the nonce mismatch means the recomputed commitment will differ from the on-chain commitment, producing a wrong nullifier that the contract rejects.

**Fix:** Persist the original nonce in `StoredNote` and look it up when building the nullifier:
```swift
// StoredNote needs a 'nonce' field (felt252 hex String)
// In executePrivateTransfer:
guard let storedNote = fetchStoredNote(matching: inputNote) else {
    throw ProverError.noMatchingNote
}
let commitment = try StarkVeilProver.noteCommitment(
    value: inputNote.value,
    assetId: inputNote.asset_id,
    ownerPubkey: keys.publicKey.hexString,
    nonce: storedNote.nonce  // use persisted nonce, NOT re-derived
)
```

---

### BUG M-TRANSFER-NO-PENDING — MEDIUM

**File:** `WalletManager.swift:660–749`

`executePrivateTransfer` does not set `isPendingSpend = true` before submitting the transaction. If the app is killed between `addInvokeTransaction` returning success and `removeNote(inputNote)` executing, the note remains in the UTXO set on next launch — but the nullifier has already been published on-chain. The next spend attempt for that note will be rejected by the contract.

**Fix:** Apply the same `isPendingSpend` two-phase commit pattern used in `executeUnshield`.

---

### Recipient IVK Collision Analysis

`recipientIVKSeed = Poseidon([recipientAddress])` (1-element input) vs real IVK `= Poseidon([sk, domain])` (2-element input). The Poseidon sponge absorbs inputs sequentially; different input lengths produce different internal state. A 1-element Poseidon hash cannot collide with a 2-element Poseidon hash. ✓ (Collision-free from the security perspective — the privacy problem is unrelated to collisions.)

---

## Q5 — SyncEngine Trial-Decryption

### StarknetAccount.deriveAccountKeys Thread Safety — SAFE ✓

```swift
// SyncEngine.swift:185–187 — inside Task { } (cooperative thread pool)
if let seed = KeychainManager.masterSeed(),
   let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) {
    ivkHex = (try? StarkVeilProver.deriveIVK(spendingKeyHex: keys.privateKey.hexString)) ?? ""
```

`deriveAccountKeys` is a pure function with no shared mutable state. `StarkVeilProver.starkPublicKey` and `StarkVeilProver.pedersenHash` use `utf8CString.withUnsafeBufferPointer` which is thread-safe. `KeychainManager.masterSeed()` calls `SecItemCopyMatching` which is documented thread-safe by Apple. ✓

---

### BUG H-IVK-FAIL-DROPS-NOTES — HIGH

**File:** `SyncEngine.swift:185–192`

```swift
if let seed = KeychainManager.masterSeed(),
   let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) {
    ivkHex = (try? StarkVeilProver.deriveIVK(spendingKeyHex: keys.privateKey.hexString)) ?? ""
    //                                                                                     ^^
    // If deriveIVK throws, ivkHex = "" — an empty string, NOT a fallback to ownerIVK
} else if let ivkData = KeychainManager.ownerIVK() {
    ivkHex = "0x" + ...
} else {
    continue
}
```

If `deriveIVK` throws (e.g., due to C-DOMAIN-SPACE causing the Rust fallback to produce an unexpected result, or any transient FFI error), `try?` converts the failure to `nil` and `ivkHex` becomes `""`. The `else if` branch is **not** reached because `masterSeed()` and `deriveAccountKeys` succeeded — only `deriveIVK` failed.

With `ivkHex = ""`, `encryptionKey(from: "")` derives a deterministic AES key from zero bytes. Decryption will fail GCM authentication → `catch` → `nil` → `continue`. Every encrypted note is silently dropped. The wallet shows zero shielded balance despite having shielded funds.

**Fix — `SyncEngine.swift`:**
```swift
let derivedIVK = try? StarkVeilProver.deriveIVK(spendingKeyHex: keys.privateKey.hexString)

if let derived = derivedIVK {
    ivkHex = derived
} else if let ivkData = KeychainManager.ownerIVK() {
    // FFI failure: fall back to legacy Keychain IVK
    ivkHex = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()
} else {
    // No IVK available at all — skip this event
    continue
}
```

---

### BUG M-IVK-LOOP-PERF — MEDIUM

**File:** `SyncEngine.swift:185`

`StarknetAccount.deriveAccountKeys` (which internally calls two Rust FFI functions: EC scalar multiply + Pedersen hash) is called inside the event loop — once per event. For a sync that covers many blocks, this can mean dozens or hundreds of key derivations per tick.

**Fix:** Derive once outside the loop:
```swift
// Before the for loop:
let ivkHex: String
if let seed = KeychainManager.masterSeed() {
    let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed)
    if let derived = keys.flatMap({ try? StarkVeilProver.deriveIVK(spendingKeyHex: $0.privateKey.hexString) }) {
        ivkHex = derived
    } else if let ivkData = KeychainManager.ownerIVK() {
        ivkHex = "0x" + ivkData.map { String(format: "%02x", $0) }.joined()
    } else {
        return  // No IVK — skip entire batch
    }
} else {
    return
}

for event in events {
    // Use ivkHex directly — no re-derivation
}
```

---

### L-OLDIVK-FALLBACK — LOW

The `KeychainManager.ownerIVK()` fallback provides raw bytes that may have been stored in a pre-Phase15 format (e.g., HKDF-derived 32 bytes, not a Poseidon-derived felt252). Notes encrypted under the new IVK scheme (via `stark_derive_ivk`) will use a different key than the legacy IVK bytes. The fallback may successfully trial-decrypt legacy notes but will fail on Phase 15-encrypted notes, causing them to be skipped. This is a compatibility issue, not a security vulnerability.

---

## Q6 — FFI Memory Safety (New Functions)

### stark_note_commitment (4-arg) — SAFE ✓

```rust
// lib.rs:200
if value_hex.is_null() || asset_id_hex.is_null() || owner_pubkey_hex.is_null() || nonce_hex.is_null() {
    return ffi_error("null pointer");
}
macro_rules! parse_felt { ($ptr:expr, $name:expr) => {
    match CStr::from_ptr($ptr).to_str() { ... }
}; }
```

All 4 pointers are null-checked. On the Swift side, `noteCommitment` uses 4-deep nested `withUnsafeBufferPointer`:
```swift
try v.withUnsafeBufferPointer { vp in
  try a.withUnsafeBufferPointer { ap in
    try o.withUnsafeBufferPointer { op in
      try n.withUnsafeBufferPointer { np in
        // stark_note_commitment(vb, ab, ob, nb) — all 4 buffers live
      }
    }
  }
}
```
All buffers are alive simultaneously when Rust runs. ✓

---

### stark_note_nullifier (2-arg) — SAFE ✓

```rust
// lib.rs:231
if commitment_hex.is_null() || spending_key_hex.is_null() { return ffi_error(...); }
```

Swift `noteNullifier` uses double-nested `withUnsafeBufferPointer`; both alive when Rust reads. ✓

---

### free_rust_string Called Exactly Once Per Pointer — SAFE ✓

All three new wrappers follow the correct pattern:
```swift
// noteCommitment, noteNullifier: direct pattern
let json = String(cString: rawPtr)
free_rust_string(UnsafeMutablePointer(mutating: rawPtr))  // exactly once ✓
return try decodeOkString(json: json)

// deriveIVK: via callSingleArg
let json = String(cString: rawPtr)
free_rust_string(UnsafeMutablePointer(mutating: rawPtr))  // exactly once ✓
```

No double-free, no leak paths. ✓

---

### L-CALLSINGLEARG-RETTYPE — LOW

**File:** `StarkVeilProver.swift:142`

```swift
private static func callSingleArg(
    _ fn: (UnsafePointer<CChar>?) -> UnsafePointer<CChar>?,  // ← incorrect
    arg: String
) throws -> String {
```

Rust FFI functions return `*mut c_char` which maps to `UnsafeMutablePointer<CChar>?` in Swift, not `UnsafePointer<CChar>?`. The `UnsafeMutablePointer(mutating: rawPtr)` cast in the body papers over this at runtime. The type should be corrected to avoid potential issues with Swift's strict concurrency checking in future Swift versions.

**Fix:**
```swift
private static func callSingleArg(
    _ fn: (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?,
    arg: String
) throws -> String {
    ...
    guard let rawPtr = fn(base) else { ... }
    let json = String(cString: rawPtr)
    free_rust_string(rawPtr)  // no cast needed
    ...
}
```

---

## Additional Finding: Note Struct Schema Mismatch

### L-NOTE-STRUCT-MISMATCH — LOW

**Files:** `prover/src/types.rs:8`, `StarkVeilProver.swift:9`

```rust
// types.rs — Phase 15 Rust Note
pub struct Note {
    pub owner_ivk: Option<String>,   // legacy
    pub owner_pubkey: Option<String>, // Phase 15 field
    ...
}
```

```swift
// StarkVeilProver.swift — Phase 4 Swift Note
struct Note: Codable {
    let owner_ivk: String    // still "owner_ivk" — no "owner_pubkey"
    ...
}
```

When Swift serializes a `Note` to JSON for `generate_transfer_proof`, it produces `{"owner_ivk": "..."}`. Rust deserializes this into a `Note` struct where `owner_pubkey = None`, so `owner_str = note.owner_pubkey.as_deref().unwrap_or("0x0")` = `"0x0"` for every note. All commitments computed inside `generate_transfer_proof` use `owner_pubkey = 0x0`, diverging from the real commitments computed via `stark_note_commitment`.

This is masked by the mock proof being accepted regardless, but must be fixed before real proof verification.

---

## Complete Findings Table

| ID | Severity | File | Line | Description |
|---|---|---|---|---|
| C-DOMAIN-SPACE | **CRITICAL** | lib.rs | 264 | Space in hex domain string → always uses "IVK" fallback, wrong domain for every IVK |
| C-COMMITMENT-MISMATCH | **CRITICAL** | WalletManager.swift | 573 vs 678 | shield: Poseidon(ivk,nonce) ≠ transfer: Poseidon(value,asset,pubkey,nonce) → no note can ever be spent |
| C-RECIPIENT-PRIVACY | **CRITICAL** | WalletManager.swift | 692 | recipientIVKSeed = Poseidon([publicAddress]) → anyone can decrypt transfer memos |
| C-TRANSFER-SELECTOR | **CRITICAL** | WalletManager.swift | 711 | transferSelector is a placeholder → all private transfer txs revert on-chain |
| H-PENDING-RESET | **HIGH** | WalletManager.swift | 359 | isPendingSpend not reset on transient error → note purged on next launch |
| H-SECRANDOM-UNCHECKED | **HIGH** | WalletManager.swift | 694 | SecRandomCopyBytes return ignored → zero nonce → deterministic commitment on failure |
| H-IVK-FAIL-DROPS-NOTES | **HIGH** | SyncEngine.swift | 187 | deriveIVK failure → ivkHex="" → all encrypted notes silently dropped |
| H-NULLIFIER-ORDER | **HIGH** | WalletManager.swift | 368–390 | isNullifierSpent called AFTER proof generation → wasted computation |
| M-NONCE-REDERIVED-WRONG | **MEDIUM** | WalletManager.swift | 677 | Input nonce re-derived deterministically ≠ original random nonce → wrong commitment |
| M-SELECTOR-WRONG-ALGO | **MEDIUM** | RPCClient.swift | 403 | isNullifierSpent uses sha3_256 not starknet_keccak → selector always wrong → always fail-open |
| M-IVK-LOOP-PERF | **MEDIUM** | SyncEngine.swift | 185 | O(N) key derivations per sync tick — should derive once before loop |
| M-DECRYPTED-UTF8 | **MEDIUM** | NoteEncryption.swift | 95 | Non-UTF8 decrypted bytes → decryptMemo returns nil → owned note silently dropped |
| M-TRANSFER-NO-PENDING | **MEDIUM** | WalletManager.swift | 660 | No isPendingSpend guard in executePrivateTransfer → crash leaves double-spendable phantom |
| L-NOTE-STRUCT-MISMATCH | LOW | types.rs / StarkVeilProver.swift | 8 / 9 | Rust owner_pubkey vs Swift owner_ivk → Rust always uses 0x0 for owner in proofs |
| L-OLD-TRANSFER-PRESENT | LOW | WalletManager.swift | 217 | Old executePrivateTransfer(recipient:amount:) is dead code alongside new Phase 15 version |
| L-CALLSINGLEARG-RETTYPE | LOW | StarkVeilProver.swift | 142 | fn return type UnsafePointer instead of UnsafeMutablePointer — works but type-incorrect |
| L-NULL-SALT-HKDF | LOW | NoteEncryption.swift | 60 | HKDF.extract(salt: nil) uses zero-key HMAC; acceptable for high-entropy IVK but sub-optimal |
| L-OLDIVK-FALLBACK | LOW | SyncEngine.swift | 188 | Legacy ownerIVK() bytes incompatible with Phase 15-encrypted notes |

**Safe (no issues):**
- AES-256-GCM nonce randomness (CryptoKit internal random) ✓
- decryptMemo nil-on-auth-failure ✓
- Data(hexString:) odd-length guard ✓
- stark_note_commitment 4-pointer lifetime safety ✓
- stark_note_nullifier 2-pointer lifetime safety ✓
- free_rust_string called exactly once per pointer ✓
- fail-open behaviour documented ✓
- isPendingSpend reset on alreadySpent path ✓
- deriveAccountKeys thread safety in SyncEngine ✓
- HKDF domain separation with "note-enc-v1" ✓
- IVK pre-image security (post C-DOMAIN-SPACE fix) ✓
- nullifier not invertible to spending key ✓
- removeNote called only after successful broadcast ✓
