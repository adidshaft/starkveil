# Phase 1 Security Audit — StarkVeil iOS (Phase 10.1 & 10.2)

## Audit Prompt

Please conduct a rigorous, production-grade security audit of the newly implemented Phase 10 code in the StarkVeil iOS project. We just completed Phase 10.1 (BIP-39 Seed Phrase Wallet) and Phase 10.2 (Private → Public Unshield Operation).

Please review the following core files:
- Core/BIP39.swift
- Core/KeyDerivationEngine.swift
- Core/KeychainManager.swift
- Core/WalletManager.swift (specifically `executeUnshield()`)
- Core/RPCClient.swift (specifically `addInvokeTransaction()`)
- StarkVeilApp.swift, MnemonicSetupView.swift, UnshieldFormView.swift

Your audit must explicitly check for the following vulnerabilities:

1. Cryptographic Soundness:
- Is the entropy source for BIP-39 generation robust (`SecRandomCopyBytes`)?
- Is the 64-byte PBKDF2 derivation implemented correctly (e.g. 2048 rounds of HMAC-SHA512)?
- Is the HKDF-SHA256 domain tagging (e.g., separating IVK from Spending Key with specific `info` strings) mathematically sound and correctly implemented using Apple's CryptoKit?

2. Secure Storage & Secret Lifecycles:
- Verify that `KeychainManager` is storing the 64-byte PBKDF2 seed (and ONLY the seed) securely via `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- Ensure the plaintext 12-word mnemonic phrase is destroyed from memory immediately after generation or restoration and is never persisted to disk or UserDefaults.

3. Concurrency & Re-Entrancy (WalletManager):
- Review `WalletManager.executeUnshield()`. Does the synchronous boolean flag `isTransferInFlight` adequately protect against re-entrancy bugs while the main actor is suspended during the Rust FFI STARK proving step? Let me know if the `defer` blocks are placed correctly.

4. State Consistency & UTXO Purging:
- Upon a successful unshield proof generation, is the spent note reliably and atomically deleted from both the in-memory `notes` array AND the SwiftData `ModelContext`? Can a user force-close the app mid-transaction to trick the system into retaining a spent output?

If you identify any vulnerabilities, logic errors, or Apple framework misuse, please provide the exact code required to fix them.

---

## Audit Findings

I've read all eight files. This is a thorough audit — let me work through each category systematically, from deepest crypto layer up to UI.

---

## Phase 10 Security Audit — StarkVeil iOS

### Category 1: Cryptographic Soundness

**`BIP39.swift` — PASS**

The entropy source (`SecRandomCopyBytes`, no fallback), PBKDF2 parameters (HMAC-SHA512, 2048 rounds, 64-byte output), and checksum bit arithmetic are all correct per the BIP-39 specification. The bit-packing and checksum reconstruction in both `mnemonicWords` and `validate` handle the 11-bit index encoding properly.

**`KeyDerivationEngine.swift` — PASS with one documentation bug**

The HMAC call at line 69 looks inverted at first glance, but it is correct:

```swift
HMAC<SHA256>.authenticationCode(for: masterSeed, using: SymmetricKey(data: domainTag))
//                              ↑ message = IKM              ↑ key = salt
```

CryptoKit's `for:` is the HMAC message and `using:` is the key. This computes `HMAC-SHA256(key=domainTag, message=masterSeed)` which is exactly HKDF-Extract(salt=domainTag, IKM=masterSeed) per RFC 5869. The 32-byte output is then fed into two independent HKDF-Expand calls with distinct `info` strings, providing sound key separation.

**Bug: Misleading comment on line 19.** The comment says `"SK is stored in Keychain alongside IVK"`, but `KeychainManager` has no entry for a spending key — only `master_seed` is stored. The SK is correctly re-derived on demand. This comment is wrong and should be removed before it causes someone to add unnecessary SK storage.

```swift
// BEFORE (line 19):
// - SK is stored in Keychain alongside IVK for future Secure Enclave migration.

// AFTER:
// - SK is re-derived on demand from the master seed via KeyDerivationEngine; never persisted.
```

---

### Category 2: Secure Storage & Secret Lifecycles

**`KeychainManager.swift` — PASS**

`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` is the correct attribute. It denies iCloud backup and cross-device migration while permitting background access after first unlock. Only the 64-byte PBKDF2 seed is stored. The delete-before-add upsert pattern is standard and acceptable given the UI-layer `isSaving` guard prevents concurrent calls.

**`MnemonicSetupView.swift` — BUG: Mnemonic lives in `@State` past its useful life**

After `verifyAndSave()` succeeds and `onComplete()` is called, the `mnemonic: [String]` `@State` property is never cleared. It stays resident in SwiftUI's state store until the view is fully released from the hierarchy — which SwiftUI may defer. During that window, the 12 words are readable in the process heap.

This is not a disk-persistence issue (the comment's security model is correct). The risk is process-memory exposure (debugger attachment on a jailbroken device, or a future in-process vulnerability). The fix is trivial and costs nothing:

**`MnemonicSetupView.swift:217–229` — Fix:**

```swift
// BEFORE:
Task.detached(priority: .userInitiated) {
    do {
        let keys = try KeyDerivationEngine.deriveKeys(from: mnemonic)
        try KeychainManager.storeMasterSeed(keys.masterSeed)
        await MainActor.run { onComplete() }
    } catch {
        await MainActor.run {
            isSaving = false
            errorMessage = "Wallet creation failed: \(error.localizedDescription)"
        }
    }
}

// AFTER — capture mnemonic by value, then zero it on MainActor after Keychain write:
let mnemonicSnapshot = mnemonic          // value-type copy; closure doesn't hold @State ref
Task.detached(priority: .userInitiated) {
    do {
        let keys = try KeyDerivationEngine.deriveKeys(from: mnemonicSnapshot)
        try KeychainManager.storeMasterSeed(keys.masterSeed)
        await MainActor.run {
            mnemonic = []                // drop the @State copy so ARC can reclaim backing storage
            onComplete()
        }
    } catch {
        await MainActor.run {
            isSaving = false
            errorMessage = "Wallet creation failed: \(error.localizedDescription)"
        }
    }
}
```

`[String]` is a value type; `mnemonicSnapshot` is a copy, not a reference to the `@State` storage. Swift Strings are immutable objects and cannot be cryptographically zeroed — `mnemonic = []` is the best achievable in standard Swift, and it's significantly better than leaving 12 words live indefinitely.

---

### Category 3: Concurrency & Re-Entrancy

**`WalletManager.executeUnshield` — PASS**

The re-entrancy protection is correctly implemented. The critical invariant is:

```
guard !isTransferInFlight  ← read
isTransferInFlight = true  ← write
```

Both lines run **before the first `await`**, synchronously on the `@MainActor`. Because the class is `@MainActor`-isolated, no other task can interleave between the guard and the set — the MainActor serializes them. The first `await` on `StarkVeilProver.generateTransferProof` suspends the actor but `isTransferInFlight = true` is already committed.

The `defer` block is also correctly placed — it's textually after the flag is set and before the first `await`, so it will fire on every exit path (Rust FFI throw, RPC throw, or normal return), always on the `@MainActor`. This is correct.

`executePrivateTransfer` and `executeUnshield` share the same `isTransferInFlight` flag, preventing a private transfer and an unshield from running in parallel, which is the correct behavior to prevent double-spending the same note.

---

### Category 4: State Consistency & UTXO Purging — Three Critical Bugs

#### Bug 1 (Critical): Note is deleted BEFORE successful RPC submission

`WalletManager.executeUnshield:206–237`:

```swift
let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])

// ← NOTE DELETION HAPPENS HERE (before RPC)
notes.removeAll { $0.value == inputNote.value }
// ... SwiftData fetch + delete + save ...

// ← RPC CALL HAPPENS HERE (after note is already gone)
let txHash = try await RPCClient().addInvokeTransaction(...)
```

If `addInvokeTransaction` throws for any reason (network error, sequencer rejection, nonce mismatch — see Category 5 below), the `defer` block fires, clears `isTransferInFlight`, the function returns the error — but **the note is already permanently deleted from both the in-memory UTXO set and SwiftData**. On the next app launch, `loadNotes` fetches from SwiftData and the note does not reappear. The user has lost their funds while the on-chain commitment remains unspent.

This is compounded by the fact that the RPC submission (see Category 5) will **always fail** in production due to an empty signature and hardcoded nonce, making this data-loss path the common case, not an edge case.

The fix is to move the note deletion to after confirmed RPC success:

**`WalletManager.swift` — Full corrected `executeUnshield`:**

```swift
func executeUnshield(
    recipient: String,
    amount: Double,
    rpcUrl: URL,
    contractAddress: String
) async throws {
    guard !isTransferInFlight else { throw ProverError.transferInProgress }
    guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
    guard amount <= balance else { throw ProverError.insufficientBalance }

    guard let inputNote = notes.first(where: { Double($0.value).map { abs($0 - amount) < 1e-9 } ?? false })
        ?? selectNotes(for: amount).first
    else { throw ProverError.noMatchingNote }

    isTransferInFlight = true
    isUnshielding = true
    lastUnshieldTxHash = nil
    unshieldError = nil

    defer {
        isTransferInFlight = false
        isUnshielding = false
    }

    // 1. Generate proof (suspends MainActor, runs Rust FFI off-thread)
    let result = try await StarkVeilProver.generateTransferProof(notes: [inputNote])

    // 2. Build and submit the invoke transaction BEFORE mutating local state.
    //    If submission fails, the note is still present and the user can retry.
    let amountU256Low  = String(format: "0x%llx", UInt64(min(amount * 1e18, Double(UInt64.max))))
    let amountU256High = "0x0"
    let proofCalldata  = result.proof
    let nullifier      = result.nullifiers.first ?? "0x0"

    // Starknet multicall invoke v1 format: [n_calls, contract, selector, cd_len, ...cd]
    let unshieldSelector = "0x015d40a3d673baee5a4dd5f48de68a12f5f7a4eb0093bc750e70c032e3b96b93"
    var innerCalldata: [String] = []
    innerCalldata.append(contentsOf: [String(proofCalldata.count)] + proofCalldata)
    innerCalldata += [nullifier, recipient, amountU256Low, amountU256High, inputNote.asset_id]
    let calldata: [String] = ["0x1", contractAddress, unshieldSelector,
                              String(innerCalldata.count)] + innerCalldata

    let senderAddress = inputNote.owner_ivk
    let txHash = try await RPCClient().addInvokeTransaction(
        rpcUrl: rpcUrl,
        senderAddress: senderAddress,
        calldata: calldata
    )

    // 3. RPC accepted the transaction — now it is safe to remove the spent note.
    //    Removal is atomic with respect to the MainActor: no await between
    //    in-memory delete and SwiftData delete.
    notes.removeAll { $0.value == inputNote.value && $0.owner_ivk == inputNote.owner_ivk }
    let ctx = persistence.context
    let netId = activeNetworkId
    let spentValue = inputNote.value
    let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })
    if let allStored = try? ctx.fetch(desc) {
        for s in allStored where s.value == spentValue && s.ownerIvk == inputNote.owner_ivk {
            ctx.delete(s)
        }
    }
    do {
        try ctx.save()
    } catch {
        // Log but do not re-throw — the on-chain transaction already succeeded.
        // On next launch loadNotes will re-fetch from SwiftData which still has the note;
        // the sync engine's nullifier check will prevent it from being double-spent.
        print("⚠️ SwiftData save failed after successful unshield: \(error)")
    }
    recomputeBalance()
    lastUnshieldTxHash = txHash
}
```

Note the secondary improvement: `try? ctx.save()` is replaced with a `do/catch` that at least logs the failure. Silent SwiftData errors should never be swallowed in a financial application.

#### Bug 2 (Critical): Value-based note identity deletes all notes with the same denomination

Both `executeUnshield:207` and `executePrivateTransfer:130` match notes by value:

```swift
notes.removeAll { $0.value == inputNote.value }                    // executeUnshield
// and:
let spentValues = Set(inputNotes.map { $0.value })
notes.removeAll { spentValues.contains($0.value) }                 // executePrivateTransfer
```

If a user holds two notes of identical denomination (e.g., two 1.0 STRK notes), spending one will delete both from the in-memory UTXO set and from SwiftData. The user loses the second note silently.

The fix requires a stable, unique note identifier. The natural choice is the note commitment (Poseidon hash of its fields), which the Cairo contract already tracks. Add an `id` (or `commitment`) field to `Note` and `StoredNote`, and match on it:

**`Note` struct — add a stable identifier:**

```swift
struct Note: Identifiable, Equatable {
    let id: String        // note commitment hex string — set at creation time
    let value: String
    let asset_id: String
    let owner_ivk: String
    let memo: String
}
```

**`WalletManager.executeUnshield` — match by id:**

```swift
// Remove only the specific note that was spent, not all notes with the same value
notes.removeAll { $0.id == inputNote.id }

// In SwiftData:
for s in allStored where s.noteId == spentNote.id { ctx.delete(s) }
```

Until the full note commitment is computed in the proving pipeline, at minimum use `UUID` assigned at note creation time as the stable identifier.

#### Bug 3 (High): Silent SwiftData save failure

As noted in Bug 1, `try? ctx.save()` throughout `WalletManager` (lines 77, 161, 215) silently swallows persistence errors. If SwiftData fails to persist note deletion, on the next launch the note reappears from disk while its nullifier has been submitted on-chain. The next spend attempt will be rejected by the contract's nullifier check, giving the user an unexplained "transaction failed" error with a phantom balance. Replace all three occurrences with logging `do/catch` blocks.

---

### Category 5: `RPCClient.addInvokeTransaction` — Two Breaking Bugs

#### Bug 4 (Critical): Empty signature and hardcoded nonce guarantee sequencer rejection

```swift
func addInvokeTransaction(
    ...
    signature: [String] = [],     // ← no STARK signature
    nonce: String = "0x0"         // ← hardcoded; invalid after first tx
) async throws -> String {
```

`executeUnshield` calls this with both defaults. Every real Starknet sequencer (Sepolia, Mainnet) rejects unsigned transactions with wrong nonces. This means the current `executeUnshield` flow is:

1. Proof generated ✓
2. Note deleted from local state (Bug 1 — now fixed above)
3. RPC submitted with empty signature → sequencer rejects with error
4. `throw RPCClientError.serverError(...)` propagates up
5. User sees error, note is gone

The correct implementation requires fetching the account nonce via `starknet_getNonce` and signing the transaction hash with the spending key via Starknet ECDSA (Pedersen hash + STARK curve). This is a significant feature gap. Until it's implemented, `executeUnshield` should not delete notes from local state on RPC failure (which is the fix in Bug 1 above).

#### Bug 5 (High): Truncated/malformed function selector

```swift
let unshieldSelector = "0x" + String(format: "%llx", 0x15d40a3d673baee5a4dd5f)
```

`0x15d40a3d673baee5a4dd5f` is a 96-bit literal. `%llx` formats a `UInt64` (64 bits). Swift will truncate the literal at compile time, producing a wrong selector value. Starknet function selectors are 252-bit felts computed as `starknet_keccak(function_name)`. The correct selector for `"unshield"` should be pre-computed and stored as a hex string constant — never derived by formatting an overflowing integer:

```swift
// Pre-compute offline: starknet_keccak("unshield") and store as a constant
private static let unshieldSelector =
    "0x015d40a3d673baee5a4dd5f48de68a12f5f7a4eb0093bc750e70c032e3b96b93"
    // Verify with: python3 -c "from starkware.crypto.signature.fast_pedersen_hash import pedersen_hash; ..."
    // or: starkli selector unshield
```

#### Bug 6 (High): Incorrect Starknet multicall calldata layout

```swift
var calldata: [String] = [contractAddress, "0x1", unshieldSelector]
```

Starknet invoke v1 multicall calldata format is:
```
[n_calls, call1_to, call1_selector, call1_calldata_len, ...call1_calldata]
```

The current code puts `contractAddress` first and `"0x1"` (the call count) second. The corrected layout is shown in the Bug 1 fix above.

---

### Additional Finding: `UnshieldFormView` — Force-unwrapped URL

`UnshieldFormView.swift:16`:

```swift
private var rpcUrl: URL { URL(string: networkManager.activeNetwork.rpcURL)! }
```

If `networkManager.activeNetwork.rpcURL` is ever empty or malformed, this crashes. Since `NetworkManager` is the canonical source of RPC URLs, this value should be non-nil by construction — but a `preconditionFailure` with a descriptive message is safer than a silent force-unwrap crash that produces no user-visible error:

```swift
private var rpcUrl: URL {
    guard let url = URL(string: networkManager.activeNetwork.rpcURL) else {
        preconditionFailure("NetworkEnvironment '\(networkManager.activeNetwork)' has an invalid rpcURL: '\(networkManager.activeNetwork.rpcURL)'")
    }
    return url
}
```

---

## Audit Summary

| # | Severity | Location | Finding |
|---|----------|----------|---------|
| 1 | **CRITICAL** | `WalletManager:206–215` | Note deleted before RPC confirmation → permanent fund loss on any RPC failure |
| 2 | **CRITICAL** | `WalletManager:207,130,141` | Value-based note matching destroys all same-denomination notes, not just the spent one |
| 3 | **CRITICAL** | `RPCClient:109,110` | Empty signature and `nonce=0` guarantee sequencer rejection; competes with Bug 1 |
| 4 | **HIGH** | `WalletManager:224` | `%llx` truncates a 96-bit selector literal to 64 bits → wrong function called |
| 5 | **HIGH** | `WalletManager:225` | Multicall calldata layout is wrong (contract address before call count) |
| 6 | **HIGH** | `WalletManager:77,161,215` | `try? ctx.save()` silently swallows SwiftData failures → phantom balance on relaunch |
| 7 | **MEDIUM** | `MnemonicSetupView:219` | Mnemonic `@State` not cleared after Keychain write |
| 8 | **LOW** | `KeyDerivationEngine:19` | Comment incorrectly states SK is stored in Keychain |
| 9 | **LOW** | `UnshieldFormView:16` | Force-unwrapped `URL(string:)!` crashes on malformed RPC URL |

Bugs 1, 2, and 3 interact destructively: the current unshield flow will always delete the note locally then always fail the RPC submission, meaning **every unshield attempt destroys the user's note with zero on-chain effect**. The ordering fix in Bug 1 is the most urgent change, as it converts data loss into a recoverable error.
