# Phase 5 Security Audit — StarkVeil iOS (Account Abstraction — Phase 11)

## Audit Prompt

Conduct a Phase 5 security audit of the StarkVeil iOS wallet, focusing on the new Phase 11 Account Abstraction code.

FILES TO AUDIT:
1. ios/StarkVeil/StarkVeil/Core/StarknetAccount.swift
2. ios/StarkVeil/StarkVeil/Core/KeychainManager.swift
3. ios/StarkVeil/StarkVeil/Core/RPCClient.swift (new methods: deployAccount, isContractDeployed, getETHBalance)
4. ios/StarkVeil/StarkVeil/Views/AccountActivationView.swift
5. ios/StarkVeil/StarkVeil/StarkVeilApp.swift (3-state flow)

QUESTIONS:
1. STARK Private Key Derivation: Is HKDF(chainRoot, "starkveil-stark-pk-v1") with mod(STARK_ORDER) a safe method? Could it produce a weak key (e.g. if the output is close to STARK_ORDER)? Should rejection sampling be used instead of modular reduction?

2. BigUInt correctness: The custom BigUInt implementation is used for 252-bit arithmetic. Audit the +, -, mod operations for overflow, underflow, and off-by-one errors. Is the mod() loop correct for values up to 2x the modulus?

3. OZ Address computation: The SHA-256-based stub for Pedersen hash and the public key derivation are acknowledged approximations. Are they structurally safe as stubs (i.e., do they produce deterministic, consistent outputs that will work when replaced with real Pedersen)? Is there any risk that the address computed by the stub will differ from the address computed by real Pedersen, causing a permanent address mismatch?

4. AccountActivationView polling: The pollForDeployment() loop runs 20 iterations × 3 seconds. Is Task.sleep safe to use here? Is there a risk of the Task being cancelled between iterations, leaving deploymentState stuck in .confirming?

5. Keychain wipe: deleteWallet() now wipes accountAddress and accountDeployed. Is there a TOCTOU risk where the app reads isAccountDeployed between the masterSeed wipe and the accountDeployed wipe (e.g. on a background thread)?

6. isAccountDeployed bypass: Could a user manually create the accountDeployed Keychain entry (Data([1])) to skip the activation flow and enter VaultView with a non-deployed account? What are the consequences?

7. deploy tx signature: signature = ["0x0", "0x0"] is used for the deploy account transaction. Will the Starknet Sepolia sequencer accept a deploy tx with a zero signature? If not, what is the minimum viable signing implementation?

For every issue found, provide the exact Swift code fix.

---

## Audit Findings

Now I have all five files. Conducting the Phase 5 audit.

---

## Phase 5 Security Audit — Starknet Account Abstraction (Phase 11)

---

### Q1 — STARK Private Key Derivation: HKDF + mod(STARK_ORDER)

**Finding: MEDIUM — Modular reduction introduces measurable statistical bias**

`StarknetAccount.swift:162`:
```swift
let privateKey = (raw < order) ? raw : raw.mod(order)
```

HKDF produces 32 bytes = 256 bits. The STARK order is `P ≈ 2^251`. Since `2^256 / P ≈ 31.something`, there are 31 complete copies of `[0, P)` within `[0, 2^256)`, plus a partial copy `[0, 2^256 mod P)`. Values in that partial range are therefore sampled with probability `32/2^256` instead of `31/2^256` — a bias of ~3.2%.

starknet.js and starknet-rs use rejection sampling (`grindKey`) specifically to avoid this. The industry standard for non-power-of-2 curve orders is rejection sampling, not modular reduction.

The STARK order constant itself is **correct**: `0x0800000000000011000000000000000000000000000000000000000000000001` = 2^251 + 17·2^192 + 1. Correct.

**Fix — `StarknetAccount.swift` (replace lines 155-162):**

```swift
static func deriveAccountKeys(fromSeed seed: Data) -> AccountKeys {
    let chainRoot = hmacSHA256(key: Data("Starknet seed v0".utf8), data: seed)
    let order = StarknetCurve.order

    // Rejection sampling (grindKey): hash seed+counter until result is in [1, order).
    // Eliminates the ~3.2% bias introduced by modular reduction on a non-power-of-2 order.
    // Expected iterations ≈ 1.03 (reject probability ≈ 1/32 per attempt).
    // 64 attempts is an astronomically safe bound (2^-250 probability of exhausting it).
    var privateKey = BigUInt.zero
    var counter: UInt32 = 0
    repeat {
        var material = chainRoot
        withUnsafeBytes(of: counter.bigEndian) { material.append(contentsOf: $0) }
        let digest = Data(HMAC<SHA256>.authenticationCode(
            for: material,
            using: SymmetricKey(data: Data("starkveil-stark-pk-v1".utf8))
        ))
        privateKey = BigUInt(hex: digest.map { String(format: "%02x", $0) }.joined())!
        counter += 1
        guard counter < 64 else {
            preconditionFailure("[StarknetAccount] grindKey exhausted 64 iterations — should never happen.")
        }
    } while privateKey >= order || privateKey == .zero

    let publicKey = starkPublicKey(privateKey: privateKey)
    let address = computeOZAccountAddress(publicKey: publicKey)
    return AccountKeys(privateKey: privateKey, publicKey: publicKey, address: address)
}
```

**Migration note:** This changes the derived private key for any seed that previously produced `raw >= order`. Existing wallets using the old `mod()` path would get a different address. Pair this change with a migration that checks `isAccountDeployed` and re-derives/re-stores the address before next launch.

---

### Q2 — BigUInt Arithmetic Correctness

**Addition (+): CORRECT**

The carry is always 0 or 1, never 2. Proof: if `o1 = true` (overflow from `l + r`), then `s1 = l + r - 2^64 <= 2^64 - 2`. With `carry <= 1`, `s1 + carry <= 2^64 - 1`, which never overflows → `o2 = false`. So `carry = o1 + o2 <= 1` by induction. Correct.

**Subtraction (−): LATENT BUG — silent underflow when lhs < rhs**

`StarknetAccount.swift:113`: The loop only iterates `lhs.words.count` times. If `rhs` has more words than `lhs`, the high-order words of `rhs` are silently ignored. When `lhs < rhs`, the result wraps to a huge value rather than trapping:

```swift
// Bug: rhs words beyond lhs.words.count are ignored
for i in 0..<lhs.words.count {  // ← stops at lhs boundary regardless of rhs size
```

**In production, this bug is not triggered** because the only call site is `mod()`, which guards `r >= m` before every subtraction. But the operator is unsafe as a public API.

**Fix — add a precondition:**

```swift
static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
    precondition(lhs >= rhs, "[BigUInt] Subtraction underflow: \(lhs.hexString) - \(rhs.hexString)")
    var result = [UInt64]()
    var borrow: UInt64 = 0
    for i in 0..<lhs.words.count {
        let l = lhs.words[i]
        let r = i < rhs.words.count ? rhs.words[i] : 0
        let (s1, o1) = l.subtractingReportingOverflow(r)
        let (s2, o2) = s1.subtractingReportingOverflow(borrow)
        result.append(s2)
        borrow = (o1 ? 1 : 0) + (o2 ? 1 : 0)
    }
    return BigUInt(words: result)
}
```

**mod() loop: CORRECT but documentation is wrong**

`StarknetAccount.swift:124-128`: The `while r >= m { r = r - m }` loop is correct. However, the class comment says "sufficient for 252-bit Starknet scalars" implying O(1) iterations, while for the private key derivation use case (`raw` is 256-bit, `order` is 252-bit), the loop runs up to **32 iterations** worst case. This is still correct and terminates, but the comment is wrong.

With the Q1 rejection-sampling fix the `mod()` loop is no longer called on 256-bit inputs for key derivation. For address masking (Q3 fix below), it will be called with values close to the modulus and run 0–1 iterations. The performance is fine.

---

### Q3 — OZ Address Computation: Stub Safety

**CRITICAL-1 — Hash collision in `pedersenHash` stub due to unpadded string concatenation**

`StarknetAccount.swift:251-254`:
```swift
data.append(Data(aHex.utf8))  // e.g., "1"
data.append(Data(bHex.utf8))  // e.g., "23"
// SHA256("123") == SHA256(pedersenHash(0x12, 0x3)) — SAME HASH
```

Different `(a, b)` pairs produce identical outputs. This violates the preimage-resistance property Pedersen requires for the multi-step address chaining:

- `pedersenHash(0x1, 0x23)` = SHA256("1" + "23") = SHA256("123")
- `pedersenHash(0x12, 0x3)` = SHA256("12" + "3") = SHA256("123") — **collision**

In the address computation chain, a collision at step `h = pedersenHash(h, deployer)` could make two entirely different deployer/salt combinations produce the same intermediate hash, leading to address aliasing.

**Fix — zero-pad both operands to exactly 64 hex chars (32 bytes) before concatenation:**

```swift
static func pedersenHash(a: BigUInt, b: BigUInt) -> BigUInt {
    // STUB: Replace with native Pedersen EC hash when Rust FFI is wired.
    // Collision-resistant via fixed-width 32-byte encoding of each operand.
    let aHex = a.hexString.replacingOccurrences(of: "0x", with: "")
    let bHex = b.hexString.replacingOccurrences(of: "0x", with: "")
    // Pad each to exactly 64 hex chars (256 bits / 32 bytes):
    let aPad = String(repeating: "0", count: max(0, 64 - aHex.count)) + aHex
    let bPad = String(repeating: "0", count: max(0, 64 - bHex.count)) + bHex
    var combined = Data(aPad.utf8)
    combined.append(Data(bPad.utf8))
    let digest = SHA256.hash(data: combined)
    let raw = BigUInt(hex: digest.map { String(format: "%02x", $0) }.joined())!
    return raw.mod(StarknetCurve.order)
}
```

**CRITICAL-2 — Stub address WILL differ from real Pedersen address → permanent fund loss**

The stub `starkPublicKey` and `pedersenHash` are explicitly not the real STARK EC operations. This is documented in comments. **The critical operational risk is**: users told to send ETH to the stub-computed address would suffer permanent fund loss once real Pedersen is substituted — the address changes.

The comment at `StarknetAccount.swift:248` says "safe to substitute until FFI is wired." This is **false for any mainnet or testnet deployment where real ETH is sent.** The AccountActivationView must prominently warn users that the address is a dev stub and must not be funded with real assets until the Rust FFI is wired.

**Fix — add a compile-time gate that cannot be silently skipped:**

```swift
// In StarknetAccount.swift, at top of starkPublicKey and pedersenHash:
#if !DEBUG
#error("STUB CRYPTO: starkPublicKey() and pedersenHash() are SHA-256 approximations. " +
       "Wire StarkVeilProver.starkPublicKey() and StarkVeilProver.pedersenHash() before " +
       "any release build. Deploying with stubs causes permanent address mismatch.")
#endif
```

And in `AccountActivationView`:

```swift
// In activateButton, before launching deployAccount:
#if !DEBUG
// Production build: verify real crypto is in place before allowing deployment
fatalError("Cannot deploy: stub crypto functions not replaced. " +
           "Wire Rust FFI before enabling release builds.")
#endif
```

**HIGH-1 — `calldataHash` missing the length term**

`StarknetAccount.swift:188`:
```swift
let calldataHash = pedersenHash(a: BigUInt.zero, b: publicKey)
// MISSING: calldataHash = pedersenHash(a: calldataHash, b: BigUInt(1))  // length=1
```

The real Starknet `compute_hash_on_elements([pubkey])` formula is:
```
h = pedersen(0, pubkey)
hash = pedersen(h, 1)   ← append the element count
```

**Fix:**
```swift
// Correct calldataHash = compute_hash_on_elements([pubkey])
var calldataHash = pedersenHash(a: BigUInt.zero, b: publicKey)
calldataHash = pedersenHash(a: calldataHash, b: BigUInt(1))  // length = 1 element
```

**HIGH-2 — Address hash missing the length term**

`StarknetAccount.swift:192-196`:
```swift
var h = pedersenHash(a: BigUInt.zero, b: prefix)
h = pedersenHash(a: h, b: deployer)
h = pedersenHash(a: h, b: salt)
h = pedersenHash(a: h, b: classHash)
h = pedersenHash(a: h, b: calldataHash)
// MISSING: h = pedersenHash(a: h, b: BigUInt(5))  // 5 elements
```

The `compute_hash_on_elements` spec appends the element count as the final hash:

**Fix (replace lines 192-196):**
```swift
var h = pedersenHash(a: BigUInt.zero, b: prefix)
h = pedersenHash(a: h, b: deployer)
h = pedersenHash(a: h, b: salt)
h = pedersenHash(a: h, b: classHash)
h = pedersenHash(a: h, b: calldataHash)
h = pedersenHash(a: h, b: BigUInt(5))  // 5 = element count (prefix, deployer, salt, classHash, calldataHash)
```

**MEDIUM — Wrong modulus: `mask251` ≠ STARK field prime**

`StarknetAccount.swift:199-200`:
```swift
let mask251 = BigUInt(hex: "07ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")!
let masked = h.mod(mask251)
```

`mask251 = 2^251 - 1`. The STARK field prime is `P = 2^251 + 17·2^192 + 1 = StarknetCurve.order`. These are different: `P > mask251`, so `h.mod(mask251) ≠ h.mod(P)` for many values of `h`. Contract addresses must be elements of the STARK field (i.e., < P), not merely < 2^251 - 1.

**Fix:**
```swift
// Replace mask251 with the actual STARK field prime (== StarknetCurve.order)
let masked = h.mod(StarknetCurve.order)
return masked.hexString
```

---

### Q4 — `pollForDeployment` Task Cancellation Safety

**Finding: SAFE — CancellationError transitions to `.error`, not stuck in `.confirming`**

`AccountActivationView.swift:375-376`:
```swift
for _ in 0..<20 {
    try await Task.sleep(nanoseconds: 3_000_000_000)
```

`Task.sleep` is a cancellation point — it throws `CancellationError` when the Task is cancelled. This propagates up through `pollForDeployment` → `deployAccount` → the catch block:
```swift
} catch {
    await MainActor.run { deploymentState = .error(error.localizedDescription) }
}
```

**State is never stuck in `.confirming`** — cancellation moves it to `.error`. Correct.

**MEDIUM — Confirmation gap: if tx confirmed during cancellation window, user must re-activate manually**

If the deploy tx is confirmed on-chain between the last `isContractDeployed` poll (returned false) and the Task cancellation, `markAccountDeployed()` is never called. On the next app launch, `KeychainManager.isAccountDeployed` returns false, `AccountActivationView` shows again, and "Check Balance" reports 0 ETH (the gas ETH was consumed by the deploy). The user appears stuck.

**Fix — add an `isContractDeployed` check at startup in `AccountActivationView`:**

```swift
// In computeKeys(), after deriving accountKeys, add a deployment recheck:
private func computeKeys() {
    Task {
        guard let seed = KeychainManager.masterSeed() else { return }
        let keys = StarknetAccount.deriveAccountKeys(fromSeed: seed)
        if KeychainManager.accountAddress() == nil {
            try? KeychainManager.storeAccountAddress(keys.address)
        }
        await MainActor.run { accountKeys = keys }

        // Recheck deployment status on every activation screen entry.
        // Handles the case where the app was killed after broadcast but before markAccountDeployed().
        let rpcUrl = networkManager.activeNetwork.rpcUrl
        let alreadyDeployed = await RPCClient().isContractDeployed(rpcUrl: rpcUrl, address: keys.address)
        if alreadyDeployed {
            try? KeychainManager.markAccountDeployed()
            await MainActor.run {
                deploymentState = .deployed
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            await MainActor.run { onActivated() }
        }
    }
}
```

**LOW — The 1.5-second cosmetic sleep before `onActivated()` is a cancellation point**

`AccountActivationView.swift:381-382`:
```swift
try await Task.sleep(nanoseconds: 1_500_000_000)  // ← can throw CancellationError
await MainActor.run { onActivated() }
```

If cancelled here, `markAccountDeployed()` has already been called (correct Keychain state), but `onActivated()` is skipped. On next launch, `isAccountDeployed = true`, so the app correctly enters VaultView via BiometricGateView. This is safe. But for clarity, use `try?` on the cosmetic sleep so `onActivated()` always fires:

```swift
try? await Task.sleep(nanoseconds: 1_500_000_000)   // cosmetic pause — cancellation is OK
await MainActor.run { onActivated() }
```

---

### Q5 — Keychain Wipe TOCTOU

**Finding: LOW — Theoretical window exists, not exploitable**

`KeychainManager.swift:79-87`: `deleteWallet()` deletes in order: `masterSeed → accountAddress → accountDeployed`. Between the `masterSeed` deletion and the `accountDeployed` deletion, a background Task could theoretically read `isAccountDeployed == true` while `masterSeed()` returns `nil`.

**Why this is safe:** `isAccountDeployed` is only consumed by the `@State` in `StarkVeilApp`, which is already set to `false` via `onWalletDeleted()` before this Keychain state is inspected again. The `SyncEngine`'s background Task reads `KeychainManager.ownerIVK()` (derived from masterSeed) — it gets `nil` and calls `continue`, never touching `isAccountDeployed`. No code path reads `isAccountDeployed` without first requiring `hasWallet` to be true.

The deletion order (masterSeed first) is the safest ordering — once the cryptographic root is gone, all key derivations fail gracefully.

**Fix (cosmetic, improves clarity):** Delete all three Keychain items atomically by wrapping in a single `SecItemDelete` batch, or at minimum add an inline comment explaining the ordering invariant:

```swift
static func deleteWallet() {
    // Deletion order matters: masterSeed is deleted FIRST so that any concurrent
    // key-derivation attempt (e.g. SyncEngine polling) fails safely (ownerIVK returns nil).
    // accountDeployed is deleted LAST so no partial-state reader sees isAccountDeployed=true
    // without a valid masterSeed — but this is currently safe because callers always set
    // @State isAccountDeployed = false via onWalletDeleted() before any re-read.
    for account in [Account.masterSeed, .accountAddress, .accountDeployed] {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }
}
```

---

### Q6 — `isAccountDeployed` Bypass via Manual Keychain Entry

**Finding: LOW — Requires jailbreak; consequences are benign**

An attacker would need to write:
- Service: `io.starkveil`, Account: `account_deployed`, Value: `Data([1])`

This requires either:
1. A jailbroken device (Keychain sandbox bypassed)
2. An app sharing the same Keychain Access Group entitlement (not configured here)
3. Physical access to the device with an MDM/device-management certificate

**If the bypass is achieved**, the attacker reaches `BiometricGateView → VaultView` with:
- Balance: $0 (no UTXO notes)
- All RPC submits fail: `executeShield` uses `senderAddress = ivkHex` (not a real Starknet account) → sequencer rejects with `INVALID_CONTRACT_ADDRESS`
- `executePrivateTransfer` generates a local proof but never submits to RPC — no on-chain effect
- No funds can be moved; no data is exposed beyond what's already accessible to a device-level attacker

**The bypass grants zero capabilities beyond device access.** No fix required beyond the existing Keychain sandboxing.

---

### Q7 — Deploy TX Signature `["0x0", "0x0"]` on Sepolia

**Finding: CRITICAL — Sepolia sequencer WILL reject a zero signature**

`RPCClient.swift:183`: `signature: [String] = ["0x0", "0x0"]`

Katana (local devnet) skips signature verification in default configuration. Starknet Sepolia (and Mainnet) run full STARK ECDSA verification:

1. Sequencer reads `constructor_calldata = [pubkey]` from the deploy tx
2. Computes the deploy transaction hash over: `(TX_PREFIX, version, contract_address, 0, calldata_hash, max_fee, chain_id, nonce)`
3. Verifies `ECDSA_verify(tx_hash, sig=(r=0, s=0), pubkey)` — **this fails because `s = 0` has no modular inverse**. The sequencer returns `INVALID_TRANSACTION_SIGNATURE`.

**Minimum viable signing implementation:**

The Rust `StarkVeilProver` FFI must expose two new functions:

```rust
// In prover/src/lib.rs — add these exports:

/// Computes the Starknet STARK-curve ECDSA signature.
/// Returns JSON: {"r": "0x...", "s": "0x..."} or {"error": "..."}
#[no_mangle]
pub extern "C" fn stark_sign(
    private_key_hex: *const c_char,
    message_hash_hex: *const c_char,
) -> *mut c_char { ... }

/// Computes the Pedersen hash of two field elements.
/// Returns hex string of result.
#[no_mangle]
pub extern "C" fn pedersen_hash(a_hex: *const c_char, b_hex: *const c_char) -> *mut c_char { ... }
```

**Fix — `AccountActivationView.swift` (add network guard blocking Sepolia deployment until FFI is wired):**

```swift
private func deployAccount(keys: StarknetAccount.AccountKeys) async {
    // SAFETY GATE: Zero signatures are only accepted on local Katana devnet.
    // Sepolia/Mainnet require real STARK ECDSA via StarkVeilProver.stark_sign().
    // Remove this guard once the Rust FFI signing is implemented and tested.
    #if !DEBUG
    let network = networkManager.activeNetwork
    guard network == .localKatana else {
        await MainActor.run {
            deploymentState = .error(
                "Real STARK signing required for \(network.name). " +
                "Complete Rust FFI integration before deploying to testnet/mainnet."
            )
        }
        return
    }
    #endif
    // ... rest of function unchanged
```

**Fix — `RPCClient.swift` (document the signing gap with a structured TODO):**

```swift
/// Minimum viable signing for production deployment:
///
/// 1. Fetch nonce:   starknet_getNonce(contract_address: senderAddress)
/// 2. Build tx hash: compute_deploy_account_tx_hash(
///                       class_hash, salt, calldata, max_fee, nonce, chain_id)
///                   using real Pedersen (StarkVeilProver.pedersen_hash FFI)
/// 3. Sign:          r, s = StarkVeilProver.stark_sign(privateKey, tx_hash)
/// 4. Submit:        signature = [r, s]
///
/// Until step 3 is implemented, only local Katana (skipValidation=true) will accept this.
@discardableResult
func deployAccount(
    rpcUrl: URL,
    classHash: String,
    constructorCalldata: [String],
    contractAddressSalt: String,
    maxFee: String = "0x2386f26fc10000",
    signature: [String] = ["0x0", "0x0"],   // Katana-only placeholder
    nonce: String = "0x0"
) async throws -> String {
    // ... existing body unchanged
```

---

### Additional Bugs Found During Audit

**CRITICAL-COMPILE — `getETHBalance` has a dead struct and wrong result handling**

`RPCClient.swift:261-263`:
```swift
struct CallResult: Decodable { let result: [String]? }   // ← defined but never used
let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
return response.result?.first ?? "0x0"
```

The `CallResult` struct is declared and then immediately ignored — `RPCResponse<[String]>` is used instead. This works by accident: `starknet_call` returns `{ "result": ["0x...", "0x..."] }`, so `RPCResponse<[String]>` decodes correctly. The dead struct is a code smell but not a correctness issue. Remove it:

```swift
func getETHBalance(rpcUrl: URL, address: String) async throws -> String {
    // ... params setup unchanged ...
    let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
    if let error = response.error {
        throw RPCClientError.serverError(code: error.code, message: error.message)
    }
    // result[0] = low 128 bits of u256 balance; sufficient for > 0 check
    return response.result?.first ?? "0x0"
}
```

**MEDIUM — `checkBalance` parses ETH balance as `UInt64`, truncating to 64 bits**

`AccountActivationView.swift:329`:
```swift
let balanceInt = UInt64(balance.replacingOccurrences(of: "0x", with: ""), radix: 16) ?? 0
```

The ETH balance `result[0]` is the low 128 bits of a u256. For any balance where the low-128-bit word overflows `UInt64` (i.e., > ~18.44 ETH in the low word alone), this returns `nil` → `0`, causing the UI to show "No ETH detected" even when the address is heavily funded.

For detecting any balance > 0, comparing the raw hex string to "0x0" is simpler and correct:

```swift
private func checkBalance(keys: StarknetAccount.AccountKeys) async {
    await MainActor.run { deploymentState = .checkingFunds }
    let rpcUrl = networkManager.activeNetwork.rpcUrl
    do {
        let balance = try await RPCClient().getETHBalance(rpcUrl: rpcUrl, address: keys.address)
        // Compare as string: avoid UInt64 truncation for balances > 18.44 ETH in low word
        let hasBalance = balance != "0x0" && balance != "0x00" && !balance.isEmpty
        await MainActor.run {
            ethBalance = balance
            deploymentState = hasBalance ? .funded : .idle
            errorMessage = hasBalance ? nil : "No ETH detected yet. Check your transfer and try again."
        }
    } catch {
        await MainActor.run { deploymentState = .idle; errorMessage = error.localizedDescription }
    }
}
```

**LOW — `computeKeys()` re-derives keys even when a cached address exists**

`AccountActivationView.swift:311-313`:
```swift
if let cached = KeychainManager.accountAddress(),
   let seed = KeychainManager.masterSeed() {
    let keys = StarkntAccount.deriveAccountKeys(fromSeed: seed)  // ignores `cached`
```

The cached value is used as a flag (was address ever computed?) but the address is always re-derived from seed. Since key derivation is deterministic, the result is always the same — this is correct but wasteful and confusing. The `cached` binding is unused. Either use the cached address directly or remove the caching entirely since it adds no value:

```swift
// Remove the Keychain caching from computeKeys() — it adds complexity without benefit.
// The address is always re-derived; it's deterministic and fast.
private func computeKeys() {
    Task {
        guard let seed = KeychainManager.masterSeed() else { return }
        let keys = StarknetAccount.deriveAccountKeys(fromSeed: seed)
        await MainActor.run { accountKeys = keys }
        // Cache address once for block explorer / external use
        if KeychainManager.accountAddress() == nil {
            try? KeychainManager.storeAccountAddress(keys.address)
        }
    }
}
```

**LOW — `balanceOfSelector` is unverified**

`RPCClient.swift:240`:
```swift
let balanceOfSelector = "0x02e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e"
```

Like the shield/unshield selectors, this must be cross-checked:
```python
from starknet_py.hash.selector import get_selector_from_name
print(hex(get_selector_from_name("balanceOf")))   # must equal 0x02e4263a...
```

---

## Phase 5 Complete Findings Summary

| ID | Sev | File | Description |
|----|-----|------|-------------|
| **C-STUB-COLLISION** | CRITICAL | StarknetAccount.swift:251 | `pedersenHash` concatenates unpadded hex → hash collisions |
| **C-STUB-FUNDLOSS** | CRITICAL | StarknetAccount.swift (all stubs) | Stub address differs from real Pedersen address → permanent ETH loss if funded |
| **C-ZERO-SIG** | CRITICAL | RPCClient.swift:183 | `["0x0","0x0"]` signature rejected by Sepolia sequencer |
| **H-CALLDATA-LEN** | HIGH | StarknetAccount.swift:188 | `calldataHash` missing final length term `pedersenHash(h, 1)` |
| **H-ADDR-LEN** | HIGH | StarknetAccount.swift:192-196 | Address hash missing final length term `pedersenHash(h, 5)` |
| **M-KEY-BIAS** | MEDIUM | StarknetAccount.swift:162 | `mod(order)` biases ~3.2% of keys; use rejection sampling (grindKey) |
| **M-WRONG-MASK** | MEDIUM | StarknetAccount.swift:199 | `mask251 = 2^251-1` but must use STARK prime `StarknetCurve.order` |
| **M-BALANCE-PARSE** | MEDIUM | AccountActivationView.swift:329 | `UInt64` parse truncates ETH balances > 18.44 ETH in low word → false "no balance" |
| **M-CANCEL-GAP** | MEDIUM | AccountActivationView.swift:375 | Task cancellation mid-poll leaves state in `.error` despite on-chain confirmation |
| **LOW-SUB-LATENT** | LOW | StarknetAccount.swift:110 | Subtraction silently wraps when lhs < rhs; safe only because `mod()` guards it |
| **LOW-TOCTOU** | LOW | KeychainManager.swift:79 | TOCTOU window between masterSeed and accountDeployed deletion; not exploitable |
| **LOW-BYPASS** | LOW | KeychainManager.swift:72 | `isAccountDeployed` bypassable via jailbreak; consequences are benign |
| **LOW-DEAD-STRUCT** | LOW | RPCClient.swift:261 | Dead `CallResult` struct declared and ignored |
| **LOW-SELECTORS** | LOW | RPCClient.swift:240 | `balanceOfSelector` unverified; must cross-check with starknet-py |
| **LOW-CACHE-FLAG** | LOW | AccountActivationView.swift:311 | Cached address used only as existence flag; re-derivation ignores it |

**Priority order before any testnet/mainnet use:**
1. **C-ZERO-SIG**: Add the network guard blocking non-Katana deployment (2 lines)
2. **C-STUB-FUNDLOSS + C-STUB-COLLISION**: Add `#if !DEBUG #error(...)` compile-time guard on all stub crypto functions so no release build can expose stub addresses to users
3. **H-CALLDATA-LEN + H-ADDR-LEN**: Apply the two missing `pedersenHash(h, length)` calls — these are needed even within the stub to maintain structural correctness when real Pedersen is substituted
4. **M-KEY-BIAS**: Apply the grindKey rejection-sampling fix before any real key material is generated for on-chain use
5. **M-WRONG-MASK**: Replace `mask251` with `StarknetCurve.order`
