# Phase 6 Security Audit — StarkVeil iOS (Rust FFI + TX Hash Builder + Nonce)

## Audit Prompt

Conduct a Phase 6 security audit of the StarkVeil iOS wallet, covering the new Phase 12 (Rust FFI cryptography) and Phase 13 (tx hash builder + nonce) code.

FILES TO AUDIT:
1. prover/src/lib.rs — 4 new FFI functions: stark_get_public_key, stark_pedersen_hash, stark_poseidon_hash, stark_sign_transaction
2. ios/StarkVeil/StarkVeil/Core/StarkVeilProver.swift — Swift bridge for the 4 FFI functions
3. ios/StarkVeil/StarkVeil/Core/StarknetAccount.swift — deriveAccountKeys (now throws), computeOZAccountAddress (real Pedersen)
4. ios/StarkVeil/StarkVeil/Core/StarknetTransactionBuilder.swift — INVOKE_V1 hash + buildAndSign
5. ios/StarkVeil/StarkVeil/Core/WalletManager.swift — executeShield, executeUnshield (Phase 13 signing)
6. ios/StarkVeil/StarkVeil/Core/RPCClient.swift — getNonce (new), addInvokeTransaction (updated signature)

QUESTIONS:

1. RUST FFI MEMORY SAFETY: stark_get_public_key, stark_pedersen_hash, stark_poseidon_hash, stark_sign_transaction all call CStr::from_ptr on raw pointers. Are there any cases where these pointers could alias, be freed twice, or be read after the Swift CString buffer goes out of scope during async dispatch?

2. SIGNING k NONCE: signTransaction in StarkVeilProver.swift derives k = SHA-256(privateKey || txHash). Is this collision-resistant enough to prevent k reuse across transactions? Specifically: if txHash is the same for two different transactions (e.g. due to nonce reuse), will k also be identical, breaking ECDSA? Should the Rust rfc6979 crate be used instead?

3. TX HASH BUILDER CORRECTNESS: StarknetTransactionBuilder.hashOnElements() chains Pedersen over [elements..., len]. Verify this matches Cairo's compute_hash_on_elements exactly (initial value, element order, length encoding). Is the length field encoding (hex string "0x3" etc.) correct? Should it be a felt252 hex or a decimal?

4. INVOKE PREFIX: The tx hash uses invokePrefix = "0x696e766f6b65" (felt252("invoke")). Verify this is the correct prefix for INVOKE_V1 — starknet spec uses different constants for v0 vs v1.

5. FFI EXCEPTION SAFETY: If starknet_crypto::sign() returns Err (e.g. k=0 or k≥order), the Rust code calls ffi_error(). Does the Swift caller correctly surface this as a thrown Swift Error? Trace the error path: Rust → CString JSON → Swift decodeOkString → NSError → WalletManager catch.

6. NONCE REPLAY: getNonce is called once per tx. Is there a TOCTOU window where a second concurrent transaction could fetch the same nonce (e.g. two rapid shield calls), causing one to be rejected by the sequencer?

7. ACCOUNT ADDRESS NULL CHECK: In executeShield and executeUnshield, KeychainManager.accountAddress() returns nil if the address hasn't been computed yet. What happens if a user somehow reaches the shield flow without going through AccountActivationView? Is the guard let the only protection?

8. POSEIDON COMMITMENT KEY: deriveNoteCommitmentKey now calls StarkVeilProver.poseidonHash. If the FFI call throws (e.g. Rust panic or bad input), the fallback is SHA-256. Could this fallback produce a commitment key that doesn't match what the Cairo contract expects, causing permanent fund loss?

For every issue found, provide the exact Swift or Rust code fix.

---

## Audit Findings

Now I have everything needed. Here is the complete **Phase 6 Security Audit**.

---

# Phase 6 Security Audit — Phase 12 (Rust FFI) + Phase 13 (TX Hash / Nonce)

Files audited: `prover/src/lib.rs`, `StarkVeilProver.swift`, `StarknetAccount.swift`, `StarknetTransactionBuilder.swift`, `WalletManager.swift`, `RPCClient.swift`.

---

## Q1 — FFI Memory Safety: Are all C string lifetimes safe across the boundary?

**Verdict: SAFE**

All four patterns are correct:

- **`callSingleArg`**: `fn(base)` executes *inside* `buf.withUnsafeBufferPointer`, so the `utf8CString` ContiguousArray is alive for the entire Rust call.
- **`pedersenHash`**: Triple-nested `withUnsafeBufferPointer` — `aBuf` and `bBuf` are alive simultaneously when `stark_pedersen_hash(aBase, bBase)` is called.
- **`signTransaction`**: Triple-nested closures — `txBuf`, `pkBuf`, `kBuf` all live concurrently while `stark_sign_transaction(tx, pk, kp)` runs.
- **Rust side**: All four FFI functions null-check their inputs before calling `CStr::from_ptr`. `free_rust_string` guards the null case and calls `CString::from_raw` which is the correct paired deallocator for `CString::into_raw`.
- **`String(cString: rawPtr)` + `free_rust_string`**: Copy is made before free in all call sites. Correct.

No aliasing, no use-after-free, no double-free.

---

## Q2 — Signing k Nonce: Is the k derivation safe against ECDSA nonce reuse?

**Two bugs — one CRITICAL, one HIGH.**

### BUG C-K-DOMAIN: SHA-256 output may exceed STARK_PRIME (~6.25% failure rate)

```swift
// StarkVeilProver.swift:252-254
let combined = Data((privateKey + txHash).utf8)
let hash = SHA256.hash(data: combined)
kValue = "0x" + hash.map { String(format: "%02x", $0) }.joined()
```

SHA-256 produces a 256-bit value. The STARK field prime is `P = 2^251 + 17·2^192 + 1`. Values with bits 252-255 set exceed P (roughly the top 6.25% of the 256-bit space). When Rust's `felt_from_hex` tries to parse such a value as a `FieldElement`, it returns `Err` → `ffi_error` → the signing call throws. One-in-sixteen shield/unshield calls will fail with no user-visible explanation.

### BUG C-K-RETRY: k reuse on transaction retry leaks the private key

If a shield or unshield RPC call times out and the user retries, `getNonce` returns the same value (the on-chain nonce has not changed), producing the same `txHash`. `k = SHA-256(privateKey || txHash)` is then identical for both signing calls. An attacker who observes both `(r, s₁)` and `(r, s₂)` with the same `k` can extract the private key:

```
k = (z₁ - z₂) · (s₁ - s₂)⁻¹  mod N
privkey = r⁻¹ · (s·k - z)  mod N
```

**Fix — `StarkVeilProver.swift` + `prover/src/lib.rs`:**

Remove the Swift k-derivation entirely and add a Rust-side RFC 6979 k-generation function. The `starknet-crypto` crate exposes `rfc6979_generate_k` exactly for this.

**Rust — add to `prover/src/lib.rs`:**

```rust
use starknet_crypto::rfc6979_generate_k;

/// Signs using a deterministic RFC 6979 k — k is NEVER passed from Swift.
#[no_mangle]
pub unsafe extern "C" fn stark_sign_rfc6979(
    tx_hash_hex: *const c_char,
    private_key_hex: *const c_char,
) -> *mut c_char {
    if tx_hash_hex.is_null() || private_key_hex.is_null() {
        return ffi_error("null pointer");
    }
    let hash_str = match CStr::from_ptr(tx_hash_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 hash") };
    let pk_str   = match CStr::from_ptr(private_key_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 pk") };
    let msg_hash = match felt_from_hex(hash_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let pk       = match felt_from_hex(pk_str)   { Ok(f) => f, Err(e) => return ffi_error(&e) };

    // RFC 6979 deterministic k — unique per (privkey, message) pair, always in [1, N)
    let k = rfc6979_generate_k(&msg_hash, &pk, None);
    match sign(&pk, &msg_hash, &k) {
        Ok(sig) => {
            let result = serde_json::json!({
                "Ok": { "r": felt_to_hex(&sig.r), "s": felt_to_hex(&sig.s) }
            }).to_string();
            CString::new(result)
                .unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap())
                .into_raw()
        }
        Err(e) => ffi_error(&format!("ECDSA sign failed: {:?}", e)),
    }
}
```

**Bridging header — add declaration:**
```c
extern char* stark_sign_rfc6979(const char* tx_hash_hex, const char* private_key_hex);
```

**Swift `StarkVeilProver.swift` — replace `signTransaction`:**

```swift
/// Signs a transaction hash using RFC 6979 deterministic k (no k parameter).
/// The k is derived entirely in Rust — never reused across (key, message) pairs.
static func signTransaction(txHash: String, privateKey: String) throws -> ECDSASignature {
    let txBuf = txHash.utf8CString
    let pkBuf = privateKey.utf8CString
    return try txBuf.withUnsafeBufferPointer { txPtr in
        try pkBuf.withUnsafeBufferPointer { pkPtr in
            guard let tx = txPtr.baseAddress, let pk = pkPtr.baseAddress else {
                throw NSError(domain: "FFIError", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Null C string buffer"])
            }
            guard let rawPtr = stark_sign_rfc6979(tx, pk) else {
                throw NSError(domain: "FFIError", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Rust returned null"])
            }
            let json = String(cString: rawPtr)
            free_rust_string(UnsafeMutablePointer(mutating: rawPtr))
            guard let data = json.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = dict["Ok"] as? [String: String],
                  let r = ok["r"], let s = ok["s"] else {
                let errMsg = (try? JSONSerialization.jsonObject(with: json.data(using: .utf8) ?? Data())
                    as? [String: Any])?["Error"] as? String ?? json
                throw NSError(domain: "CryptoFFI", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: errMsg])
            }
            return ECDSASignature(r: r, s: s)
        }
    }
}
```

Also update `StarknetTransactionBuilder.buildAndSign` to drop the `k:` parameter from its internal `signTransaction` call — it already passes none, so no caller changes are needed beyond updating the function signature.

---

## Q3 — hashOnElements: Does it match Cairo's `compute_hash_on_elements`?

**Verdict: CORRECT**

```swift
// StarknetTransactionBuilder.swift:94-102
static func hashOnElements(_ elements: [String]) throws -> String {
    var h = "0x0"
    for element in elements {
        h = try StarkVeilProver.pedersenHash(a: h, b: element)
    }
    h = try StarkVeilProver.pedersenHash(a: h, b: "0x\(String(elements.count, radix: 16))")
    return h
}
```

This exactly matches the Cairo spec: `H(H(H(0, e₀), e₁)…, n)` where `n` is the element count. The length is encoded as `"0x\(count.hex)"`, producing valid felt252 strings like `"0x8"`. Empty-array case gives `H(0x0, 0x0)` which is correct. The INVOKE_V1 outer elements array has 8 entries; the inner calldata hash is computed separately before being passed as one element — both are correct.

---

## Q4 — invoke Prefix: Is `"0x696e766f6b65"` correct for INVOKE_V1?

**Verdict: CORRECT**

ASCII encoding of `"invoke"`:
```
i=0x69  n=0x6e  v=0x76  o=0x6f  k=0x6b  e=0x65
→ 0x696e766f6b65  (correct)
```

The INVOKE_V1 spec uses the raw string `"invoke"` (not `"invoke_v1"` or `"INVOKE"`). Likewise `"0x6465706c6f795f6163636f756e74"` for `"deploy_account"` is correct. Chain ID hex strings also check out (felt252 ASCII of `"SN_SEPOLIA"` and `"SN_MAIN"`).

---

## Q5 — FFI Exception Path: Do Rust errors surface correctly in Swift?

**Two bugs — one HIGH, one HIGH.**

### BUG H-ERR-KEY: JSON key mismatch — `"Error"` vs `"Err"` — all Rust errors silent

`ffi_error` in Rust serialises via `FFIResult::Error(msg)` which produces:
```json
{"Error": "message"}
```

But `decodeOkString` in Swift checks:
```swift
let errMsg = dict["Err"] as? String ?? "Unknown Rust error"
//                  ^^^^ "Err" ≠ "Error"
```

And `signTransaction` also checks `dict["Err"]`. In every error path for all four Phase 12 functions, the real error message is discarded and replaced with the hardcoded string `"Unknown Rust error"`. This makes every FFI failure look identical regardless of cause (null private key, overflow, invalid felt, etc.).

**Fix — `StarkVeilProver.swift` — change one line in `decodeOkString`:**

```swift
// Before:
let errMsg = dict["Err"] as? String ?? "Unknown Rust error"

// After:
let errMsg = (dict["Err"] ?? dict["Error"]) as? String ?? "Unknown Rust error (raw: \(json))"
```

And in `signTransaction`'s error branch:
```swift
// Before:
let errMsg = ... ?["Err"] as? String ?? json

// After:
let errMsg = ... .flatMap { ($0["Err"] ?? $0["Error"]) as? String } ?? json
```

### BUG H-TRY-SWALLOW: `try?` on `deriveAccountKeys` swallows signing-key errors

In both `executeShield` and `executeUnshield`:
```swift
// WalletManager.swift:539-543 (shield) / :407-411 (unshield)
guard let seed = KeychainManager.masterSeed(),
      let keys = try? StarknetAccount.deriveAccountKeys(fromSeed: seed) else {
    throw NSError(domain: "StarkVeil", code: 11,
                  userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key."])
}
```

If `StarkVeilProver.starkPublicKey` throws (e.g., because `stark_get_public_key` returned `{"Error": "..."}` which becomes "Unknown Rust error" due to H-ERR-KEY above), the real error is swallowed and the user sees only "Could not derive signing key." — indistinguishable from a missing Keychain entry.

**Fix — `WalletManager.swift`** (apply to both shield and unshield):

```swift
// Replace the try? pattern:
guard let seed = KeychainManager.masterSeed() else {
    throw NSError(domain: "StarkVeil", code: 11,
                  userInfo: [NSLocalizedDescriptionKey: "Could not derive signing key: seed not in Keychain."])
}
let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)  // throws — propagates real error
```

---

## Q6 — Nonce Replay TOCTOU: Can two concurrent transactions share a nonce?

**Verdict: SAFE**

`isTransferInFlight = true` is set synchronously on the main actor *before* the first `await` (before `getNonce`). Because `WalletManager` is `@MainActor`-isolated, no other transfer can begin between the guard check and the flag being set — there is no suspension point between them. Only one `getNonce` call runs at a time. The sequencer would reject a duplicate nonce anyway, but the guard ensures the app never produces one intentionally.

---

## Q7 — Account Address Null Check: Is `guard let senderAddress = KeychainManager.accountAddress()` sufficient?

**Verdict: SAFE** (with one style note)

If `accountAddress()` returns nil, the error is thrown before any RPC call or note mutation. The `note` object created earlier in `executeShield` (line 498) is a local variable — it is never inserted into SwiftData or the in-memory `notes` array until `addNote(note)` on line 571, which is only reached after a successful broadcast. The `defer` block correctly resets `isTransferInFlight` and `isShielding` even on throw path.

**Style note** (LOW): The `note` object is constructed 35 lines before the `senderAddress` guard. Moving the guard to immediately after the `ivkData` guard would make the fail-fast ordering visually clearer, but there is no functional consequence.

---

## Q8 — Poseidon Commitment Key Fallback: Can the SHA-256 fallback cause permanent fund loss?

**CRITICAL — This bug makes every shield call produce a permanently unspendable note.**

### Root cause: UUID is not a valid felt252

```swift
// WalletManager.swift:497, 527
let nonce = UUID().uuidString   // e.g. "6E7D9E98-4CA4-4B58-B46E-E75C46C16F23"
// ...
let commitmentKey = deriveNoteCommitmentKey(ivkHex: ivkHex, nonce: nonce)
```

Inside `deriveNoteCommitmentKey`, `poseidonHash(elements: [ivkHex, nonce])` calls Rust's `felt_from_hex("6E7D9E98-...")`. Because the UUID contains hyphens and letters beyond `f`, `FieldElement::from_hex_be` returns `Err` → `ffi_error` → Swift catches it via `try?` → **falls back to SHA-256 on every single call.**

### Effect: permanent fund loss in production

The PrivacyPool Cairo contract stores and verifies note commitment keys using `poseidon_hash_span`. When the on-chain commitment key is `SHA-256(ivkHex || nonceUUID)` but the contract expects `Poseidon([ivkHex, nonceHex])`, the unshield proof will never be accepted. Every shielded deposit creates a note that can never be spent. The shield transaction succeeds on-chain (the contract stores any felt252 as a commitment key), the ETH/STRK is deducted from the user's public balance, and it is permanently locked in the pool.

### Fix — `WalletManager.swift`:

Convert the nonce to a felt252 hex string using random bytes, and remove the SHA-256 fallback entirely:

```swift
// Replace the nonce + deriveNoteCommitmentKey logic in executeShield:

// Generate a cryptographically random 31-byte nonce (< STARK_PRIME).
// 31 bytes = 248 bits, which is always < 2^251 = STARK_PRIME lower bound.
var nonceBytes = [UInt8](repeating: 0, count: 31)
guard SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes) == errSecSuccess else {
    throw NSError(domain: "StarkVeil", code: 12,
                  userInfo: [NSLocalizedDescriptionKey: "Failed to generate random nonce."])
}
let nonceHex = "0x" + nonceBytes.map { String(format: "%02x", $0) }.joined()

let note = Note(
    value: String(format: "%.6f", amount),
    asset_id: "STRK",
    owner_ivk: ivkHex,
    memo: memo.isEmpty ? "shielded deposit" : memo
)

// Commitment key = Poseidon(ivkHex, nonceHex) — matches Cairo PrivacyPool contract.
// This MUST NOT fall back: if FFI fails, throw rather than silently corrupt the note.
let commitmentKey = try deriveNoteCommitmentKey(ivkHex: ivkHex, nonce: nonceHex)
```

Update `deriveNoteCommitmentKey` to `throws` and remove the fallback:

```swift
// Replace the entire function:
private func deriveNoteCommitmentKey(ivkHex: String, nonce: String) throws -> String {
    // MUST match Cairo PrivacyPool: poseidon_hash_span([ivk, nonce])
    // No fallback — a wrong commitment key permanently locks the shielded funds.
    return try StarkVeilProver.poseidonHash(elements: [ivkHex, nonce])
}
```

Also store `nonceHex` alongside the note (in `StoredNote`) so the unshield path can reconstruct the commitment for the proof. Currently the note's `memo` field is the only user-set string — add a `commitmentNonce: String` column to `StoredNote` (a separate Phase 9 fix).

---

## Additional Finding A — Hardcoded Chain ID

**Severity: MEDIUM**

Both `executeShield` and `executeUnshield` hardcode:
```swift
chainID: StarknetTransactionBuilder.ChainID.sepolia,
```

When `activeNetworkId` is mainnet, the tx hash will be computed with the Sepolia chain ID and the Starknet mainnet sequencer will reject it with `Invalid transaction nonce` (actually, tx hash mismatch — the computed hash won't match the sequencer's re-computation).

**Fix — `WalletManager.swift`:**

```swift
// Add a computed property:
private var currentChainID: String {
    activeNetworkId == NetworkEnvironment.mainnet.rawValue
        ? StarknetTransactionBuilder.ChainID.mainnet
        : StarknetTransactionBuilder.ChainID.sepolia
}

// Replace both hardcoded uses:
chainID: currentChainID,
```

---

## Additional Finding B — `deployAccount` Still Uses Zero Signature

**Severity: MEDIUM** (production-blocking on Sepolia)

```swift
// RPCClient.swift:200
signature: [String] = ["0x0", "0x0"],
```

Phase 13 wired real ECDSA for invoke transactions but `deployAccount` retains the placeholder. Sepolia rejects any deploy account transaction whose signature does not validate against the DEPLOY_ACCOUNT_V1 transaction hash. `AccountActivationView.deployAccount()` will always fail on live networks.

**Fix — `AccountActivationView.swift`** — compute the real deploy signature before calling `deployAccount`:

```swift
// In deployAccount() task, after computing keys and before RPC call:
let deployHash = try StarknetTransactionBuilder.deployAccountHash(
    contractAddress: address,
    constructorCalldata: [keys.publicKey.hexString],
    classHash: StarknetCurve.ozAccountClassHash,
    salt: keys.publicKey.hexString,
    maxFee: "0x2386f26fc10000",
    nonce: "0x0",
    chainID: StarknetTransactionBuilder.ChainID.sepolia
)
let deploySig = try StarkVeilProver.signTransaction(
    txHash: deployHash,
    privateKey: keys.privateKey.hexString
)
try await RPCClient().deployAccount(
    rpcUrl: rpcUrl,
    classHash: StarknetCurve.ozAccountClassHash,
    constructorCalldata: [keys.publicKey.hexString],
    contractAddressSalt: keys.publicKey.hexString,
    signature: [deploySig.r, deploySig.s]
)
```

---

## Phase 6 Findings Summary

| ID | Severity | File | Description |
|---|---|---|---|
| C-NONCE-UUID | **CRITICAL** | WalletManager.swift:497 | `UUID().uuidString` is not a valid felt252 → poseidonHash always fails → SHA-256 fallback always used → every shield creates permanently unspendable note |
| C-POSEIDON-FALLBACK | **CRITICAL** | WalletManager.swift:588-596 | SHA-256 fallback in `deriveNoteCommitmentKey` silently produces wrong commitment → fund loss |
| C-K-RETRY | **CRITICAL** | StarkVeilProver.swift:252 | Same `txHash` on retry → same `k` → ECDSA nonce reuse → private key extraction |
| C-K-DOMAIN | **HIGH** | StarkVeilProver.swift:254 | SHA-256 output exceeds STARK_PRIME ~6.25% of the time → `sign` returns Err → 1-in-16 signing failures |
| H-ERR-KEY | **HIGH** | StarkVeilProver.swift:168 | Rust sends `{"Error": "..."}`, Swift checks `dict["Err"]` → all Rust errors become "Unknown Rust error" |
| H-TRY-SWALLOW | **HIGH** | WalletManager.swift:539,407 | `try?` on `deriveAccountKeys` swallows real FFI errors |
| M-CHAIN-ID-HARDCODED | **MEDIUM** | WalletManager.swift:418,557 | Chain ID hardcoded to Sepolia regardless of `activeNetworkId` |
| M-DEPLOY-ZERO-SIG | **MEDIUM** | RPCClient.swift:200 | `deployAccount` default signature is `["0x0","0x0"]` → rejected by Sepolia |
| Q1 FFI memory | SAFE | — | All C string lifetimes correctly scoped |
| Q3 hashOnElements | CORRECT | — | Matches Cairo compute_hash_on_elements |
| Q4 invoke prefix | CORRECT | — | 0x696e766f6b65 = felt252("invoke") |
| Q6 nonce TOCTOU | SAFE | — | @MainActor + isTransferInFlight prevent concurrent nonce fetch |
| Q7 address null | SAFE | — | Guard throws before any mutation |

The **three CRITICALs** (C-NONCE-UUID, C-POSEIDON-FALLBACK together, and C-K-RETRY) are all production-blocking: the first two mean every single shield on a live network permanently locks funds; the third means a patient attacker can extract the private key from a user who retries a failed transaction. Address these before any Sepolia deployment.
