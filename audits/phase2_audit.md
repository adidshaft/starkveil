# Phase 2 Security Audit — StarkVeil iOS (Regression Audit After Phase 10 Patches)

## Audit Prompt

Please conduct a highly targeted, aggressive security regression audit on the recent fixes applied to the StarkVeil iOS project. We specifically patched 9 vulnerabilities in Phase 10 concerning UTXO consistency, RPC calldata, and secret lifecycles.

Please laser-focus your review on the exact changes made to WalletManager.swift (specifically `executePrivateTransfer` and `executeUnshield`), RPCClient.swift, and MnemonicSetupView.swift.

Your objective is to guarantee absolute privacy, security, and safety. You MUST look for the following potential regressions:

1. Data Loss / Phantom Balances (SwiftData UTXO Set):
- In WalletManager.swift, review how `executeUnshield` and `executePrivateTransfer` find and delete notes.
- We switched from `notes.removeAll { $0.value == spentValue }` to finding a specific index matching `(value, asset_id, memo, owner_ivk)`.
- Does this new value-matching logic guarantee that ONLY the single spent note is deleted from the `PersistenceController` context?
- What happens if there are two completely identical notes (same value, asset, memo, and IVK)? Will the `remove(at:)` logic gracefully delete exactly one, or does it risk a UTXO desync between the on-screen array and SwiftData?

2. RPC Calldata Ordering & Sequencing:
- Review the newly updated `calldata` payload in `executeUnshield()` mapped to the Starknet V1 `__execute__` invoke transaction.
- Is the sequence of `[call_array_len, to, selector, data_offset, data_len, calldata_len, ...data]` perfectly mapped?
- Does `RPCClient.addInvokeTransaction` safely inject the default `["0x0", "0x0"]` signature to appease the Starknet Sequencer?

3. Re-entrancy / State Leaks:
- Verify that moving the `ctx.delete` and `ctx.save` logic to occur strictly AFTER `starknet_addInvokeTransaction` means failed RPC calls cleanly revert with zero local data loss.
- In MnemonicSetupView.swift, verify that the main thread `removeAll(keepingCapacity: false)` adequately wipes the 12-word string array from RAM before returning to the Vault.

If you find ANY scenario where an attacker, a network partition, or a force-close could cause a user to permanently lose a note or accidentally leak their identity, provide the exact code to patch it.

---

## Audit Findings

Good. `StoredNote` has `owner_ivk: String` (line 11) — this is the key fact I needed. Now I have everything required for an exact, line-level audit. Here is the full regression report.

---

## Phase 10 Regression Audit — Findings

### What the Patches Got Right

Before the bugs: confirming the fixes that landed correctly.

| Fix | Location | Verdict |
|-----|----------|---------|
| Note deletion moved after RPC success | `executeUnshield:245–275` | Correct |
| `firstIndex + remove(at:)` in-memory single-deletion | `executeUnshield:252–256` | Correct |
| `first(where:) + ctx.delete` SwiftData single-deletion | `executeUnshield:261–266` | Correct (structure) |
| `do/catch` replacing `try?` on every `ctx.save()` | All three callers | Correct |
| Signature default changed to `["0x0","0x0"]` | `RPCClient:144` | Improvement |
| Selector stored as string literal (not `%llx` overflow) | `executeUnshield:228` | Correct |
| `mnemonic.removeAll(keepingCapacity: false)` + `confirmedWords` | `MnemonicSetupView:222–223` | Correct (with caveat below) |

---

### Bug 1 — CRITICAL: `owner_ivk` Is Missing from Both SwiftData Predicates

This is the most serious surviving defect. The in-memory deletion uses a 4-field identity tuple `(value, asset_id, memo, owner_ivk)`. The SwiftData predicate uses only 3 fields and silently drops `owner_ivk`:

**`executeUnshield` — `WalletManager.swift:260–265`:**
```swift
// CURRENT — BUG: owner_ivk ignored in DB match
if let allStored = try? ctx.fetch(desc),
   let stored = allStored.first(where: {
       $0.value == inputNote.value && $0.asset_id == inputNote.asset_id && $0.memo == inputNote.memo
       // ← owner_ivk absent
   }) {
    ctx.delete(stored)
}
```

**`executePrivateTransfer` — `WalletManager.swift:150–155`:**
```swift
// CURRENT — BUG: owner_ivk ignored in DB match
if let dbIdx = remainingStored.firstIndex(where: {
    $0.value == inputNote.value && $0.asset_id == inputNote.asset_id && $0.memo == inputNote.memo
    // ← owner_ivk absent
}) {
```

**Attack/failure scenario:** A user receives two notes from different senders — both for `"1.0"` STRK with memo `"payment"` but different `owner_ivk` values (representing two independently detected commitments). The in-memory array has `noteA (ivk=0xAAA)` at index 0 and `noteB (ivk=0xBBB)` at index 1. The user selects and spends `noteA`.

- In-memory: `firstIndex(where: { ... && $0.owner_ivk == "0xAAA" })` → finds index 0. `noteA` removed. Correct.
- SwiftData: `first(where: { $0.value == "1.0" && ... })` — no `owner_ivk` filter — returns **whichever `StoredNote` was inserted first**, which may be `noteB`. `noteB` deleted from disk. Wrong.

After the next app launch, `loadNotes()` fetches from SwiftData. `noteA` is still there (the wrong one was deleted) and `noteB` is gone. The in-memory UTXO set now shows the spent note as unspent, and the legitimate unspent note has vanished. This is both a phantom balance and a permanent note loss in a single operation.

The field exists in `StoredNote` (`var owner_ivk: String`, line 11) — it was simply never included in the predicates.

**Exact fix — `WalletManager.swift`:**

```swift
// executeUnshield: replace lines 261–266
if let allStored = try? ctx.fetch(desc),
   let stored = allStored.first(where: {
       $0.value      == inputNote.value   &&
       $0.asset_id   == inputNote.asset_id &&
       $0.memo       == inputNote.memo     &&
       $0.owner_ivk  == inputNote.owner_ivk   // ← add this field
   }) {
    ctx.delete(stored)
}

// executePrivateTransfer: replace lines 150–155
if let dbIdx = remainingStored.firstIndex(where: {
    $0.value      == inputNote.value    &&
    $0.asset_id   == inputNote.asset_id &&
    $0.memo       == inputNote.memo     &&
    $0.owner_ivk  == inputNote.owner_ivk    // ← add this field
}) {
    let stored = remainingStored.remove(at: dbIdx)
    ctx.delete(stored)
}
```

---

### Bug 2 — HIGH: Force-Close After RPC Success Creates a Phantom Note

This is the residual half of the original Bug 1 that the fix did not fully eliminate. Moving the deletion to *after* RPC success protects against note loss on RPC failure, but it creates the inverse window:

```
addInvokeTransaction → returns txHash  ← (A) sequencer has the nullifier
notes.remove(at: memIdx)               ← (B) in-memory
ctx.delete(stored)                     ← (C) SwiftData context marked
try ctx.save()                         ← (D) flushed to disk
```

A force-close anywhere between (A) and (D) leaves the `StoredNote` intact on disk. On the next launch, `loadNotes()` fetches it from SwiftData and it re-enters the UTXO set as if unspent. The on-chain nullifier set already contains its nullifier. Any attempt to spend it again will be rejected by the contract with a nullifier collision, giving the user a permanent phantom balance.

The root cause is the absence of a "pending spend" state. The complete fix requires adding a `isPendingSpend: Bool` column to `StoredNote`, which is persisted to disk *before* the RPC call and then drives cleanup on the next launch:

**`StoredNote.swift` — add pending-spend flag:**
```swift
@Model
final class StoredNote {
    @Attribute(.unique) var id: UUID
    var value: String
    var asset_id: String
    var owner_ivk: String
    var memo: String
    var createdAt: Date
    var networkId: String
    var isPendingSpend: Bool = false   // ← new field

    // init unchanged
}
```

**`WalletManager.executeUnshield` — two-phase state machine:**
```swift
// ── Phase 1: Mark as pending BEFORE the RPC call ──────────────────────────
let ctx = persistence.context
let netId = activeNetworkId
let desc = FetchDescriptor<StoredNote>(predicate: #Predicate { $0.networkId == netId })

// Find the exact StoredNote that corresponds to inputNote (4-field match)
guard let storedNote = (try? ctx.fetch(desc))?.first(where: {
    $0.value     == inputNote.value    &&
    $0.asset_id  == inputNote.asset_id &&
    $0.memo      == inputNote.memo     &&
    $0.owner_ivk == inputNote.owner_ivk
}) else {
    // Note vanished (e.g. network switch fired clearStore during proof generation)
    throw ProverError.noMatchingNote
}
storedNote.isPendingSpend = true
do {
    try ctx.save()  // durably mark as pending BEFORE the network call
} catch {
    print("[WalletManager] CRITICAL: Could not mark note as pending: \(error)")
    throw error     // do not proceed — we can't guarantee safe cleanup
}

// ── Phase 2: Submit RPC ───────────────────────────────────────────────────
let txHash = try await RPCClient().addInvokeTransaction(
    rpcUrl: rpcUrl,
    senderAddress: senderAddress,
    calldata: calldata
)

// ── Phase 3: RPC confirmed — delete note from both stores ─────────────────
if let memIdx = notes.firstIndex(where: {
    $0.value == inputNote.value && $0.asset_id == inputNote.asset_id &&
    $0.memo  == inputNote.memo  && $0.owner_ivk == inputNote.owner_ivk
}) {
    notes.remove(at: memIdx)
}
ctx.delete(storedNote)
do {
    try ctx.save()
} catch {
    print("[WalletManager] CRITICAL: SwiftData delete failed after successful unshield: \(error)")
}
recomputeBalance()
lastUnshieldTxHash = txHash
```

**`WalletManager.loadNotes` — scrub pending-spend notes on cold start:**

Any note still marked `isPendingSpend = true` on launch means the app was killed after the sequencer received the nullifier but before local cleanup. These notes should be scrubbed immediately rather than re-entering the UTXO set:

```swift
func loadNotes(for networkId: String) {
    let ctx = persistence.context
    let allDescriptor = FetchDescriptor<StoredNote>(
        predicate: #Predicate { $0.networkId == networkId },
        sortBy: [SortDescriptor(\.createdAt)]
    )
    guard let all = try? ctx.fetch(allDescriptor) else {
        notes = []; recomputeBalance(); return
    }

    // Purge any note that was mid-spend when the process was killed.
    // The sequencer already holds its nullifier; retaining it would create a phantom balance.
    let pending = all.filter { $0.isPendingSpend }
    if !pending.isEmpty {
        pending.forEach { ctx.delete($0) }
        do { try ctx.save() }
        catch { print("[WalletManager] CRITICAL: Could not purge pending-spend notes: \(error)") }
    }

    notes = all.filter { !$0.isPendingSpend }.map { $0.toNote() }
    recomputeBalance()
}
```

This converts the phantom-note scenario into a clean, safe "note consumed" outcome on the next launch at the cost of a possible over-eager deletion if the app crashes before the sequencer received the transaction — which is acceptable because the on-chain state (which nullifiers exist) is always the authoritative ground truth, and the proof must be regenerated anyway.

---

### Bug 3 — HIGH: `UInt64` Conversion Traps for Amounts Above ~18.44 Tokens

`WalletManager.swift:224`:
```swift
let amountU256Low = String(format: "0x%llx", UInt64(amount * 1e18) & 0xFFFFFFFFFFFFFFFF)
```

In Swift, `UInt64(someDouble)` is **not** a wrapping or saturating conversion — it calls a trapping initializer. If `amount * 1e18 >= 2^64` (i.e., `amount > 18.44` for an 18-decimal token), the process terminates with `EXC_BAD_INSTRUCTION`. The `& 0xFFFFFFFFFFFFFFFF` mask is applied after the `UInt64()` call, so it cannot prevent the trap.

The guards at lines 200–201 only check `amount > 0` and `amount.isFinite` — they do not bound the upper value. The `insufficientBalance` guard (line 201) only fires if `amount > balance`, but if the user's balance itself exceeds 18.44 tokens, the trap occurs during the conversion, not earlier.

**Fix — `WalletManager.swift:224`:**
```swift
// Replace the single UInt64 conversion with a clamped, crash-safe version
let amountWei = amount * 1e18
// U256 split: low 64 bits and high bits. For amounts ≤ 18.44 tokens, high = 0.
// For larger amounts we carry into the high word rather than trapping.
let amountU256Low: String
let amountU256High: String
if amountWei < Double(UInt64.max) {
    amountU256Low  = String(format: "0x%llx", UInt64(amountWei))
    amountU256High = "0x0"
} else {
    // Full 128-bit split for amounts > 18.44 tokens
    let highPart = UInt64(amountWei / Double(UInt64.max))
    let lowPart  = UInt64(amountWei.truncatingRemainder(dividingBy: Double(UInt64.max)))
    amountU256Low  = String(format: "0x%llx", lowPart)
    amountU256High = String(format: "0x%llx", highPart)
}
```

---

### Bug 4 — MEDIUM: The Starknet Function Selector Is Still Wrong

`WalletManager.swift:228`:
```swift
let unshieldSelector = "0x15d40a3d673baee5a4dd5f" // selectors.unshield (Audit Bug 4 fixed)
```

The `%llx` truncation from the previous version is gone — that specific bug is fixed. But the *value* itself is wrong. A Starknet selector is `starknet_keccak(function_name) mod 2^250`, which produces a 252-bit felt. The correct representation is a 63-hex-digit string (with leading zeros). `0x15d40a3d673baee5a4dd5f` is only 23 hex digits (92 bits). The comment says "Audit Bug 4 fixed" but the value has not changed at all from the original buggy version — only the formatting call was removed.

The correct selector for `"unshield"` must be computed offline and stored as a full-width constant. Using `starkli`:

```bash
starkli selector unshield
# Expected output: 0x0nnnnn...nnnnn (63 hex digits)
```

Until you have the real value, the unshield RPC call will target a nonexistent entry point and the sequencer will return `ENTRY_POINT_NOT_FOUND_IN_CONTRACT`. Replace the placeholder with a properly commented TODO so this is not silently shipped:

```swift
// TODO: Replace with the output of `starkli selector unshield` against your deployed contract.
// This value is WRONG — 0x15d40a3d673baee5a4dd5f is 92 bits; a valid Starknet felt is 252 bits.
// All unshield transactions will be rejected by the sequencer until this is corrected.
let unshieldSelector = "0x__REPLACE_WITH_starkli_selector_unshield__"
```

---

### Bug 5 — MEDIUM: Mnemonic Captured Copy Outlives `removeAll()`

`MnemonicSetupView.swift:217–225`:

```swift
Task.detached(priority: .userInitiated) {
    do {
        let keys = try KeyDerivationEngine.deriveKeys(from: mnemonic)  // (A) reads copy
        try KeychainManager.storeMasterSeed(keys.masterSeed)
        await MainActor.run {
            mnemonic.removeAll(keepingCapacity: false)   // (B) clears @State
            confirmedWords.removeAll(keepingCapacity: false)
            onComplete()
        }
    } ...
}
```

`[String]` is a value type. The `Task.detached` closure captures `mnemonic` **by value** at the moment the closure is created — it holds an independent copy of the 12-word array. When `removeAll()` runs at (B), it clears the `@State` storage, but the closure's own captured copy is a separate allocation. That copy remains live in the closure's stack frame until the `do { }` block exits, which happens *after* `MainActor.run` returns. The copy is therefore still readable in process memory during the brief window when `MainActor.run` is executing.

The improvement over the original (which never cleared at all) is real, but the copy in the Task frame is not covered by the `removeAll()`. The fix is to capture an explicit snapshot and explicitly nil it after use, while also zeroing `confirmedWords`:

```swift
private func verifyAndSave() {
    errorMessage = nil
    for (qi, idx) in quizIndices.enumerated() {
        let entered = confirmedWords.indices.contains(qi) ? confirmedWords[qi] : ""
        guard entered == mnemonic[idx] else {
            errorMessage = "Word #\(idx + 1) is incorrect. Please check your backup."
            return
        }
    }

    isSaving = true
    // Capture by value so the Task has its own copy independent of @State.
    // We will clear BOTH the @State copy and this local copy after use.
    var mnemonicSnapshot = mnemonic

    Task.detached(priority: .userInitiated) {
        defer {
            // Zero the local snapshot regardless of success or failure.
            // This is the best achievable erasure for Swift Strings: drop all
            // ARC references so the backing String objects can be reclaimed.
            mnemonicSnapshot.removeAll(keepingCapacity: false)
        }
        do {
            let keys = try KeyDerivationEngine.deriveKeys(from: mnemonicSnapshot)
            try KeychainManager.storeMasterSeed(keys.masterSeed)
            await MainActor.run {
                // Zero the @State copy on the main actor.
                mnemonic.removeAll(keepingCapacity: false)
                confirmedWords.removeAll(keepingCapacity: false)
                onComplete()
            }
        } catch {
            await MainActor.run {
                isSaving = false
                errorMessage = "Wallet creation failed: \(error.localizedDescription)"
            }
        }
        // defer fires here — mnemonicSnapshot is zeroed in both success and error paths.
    }
}
```

The `defer { mnemonicSnapshot.removeAll() }` runs after the `do/catch` block exits but before the Task closure's stack frame is released. This is the earliest point at which the captured copy can be cleared. Swift `String` objects are heap-allocated and immutable — `removeAll` drops the array's references to them, allowing ARC to reclaim the backing memory. Cryptographic zeroing of the raw bytes requires a custom `SecureBytes` type and is out of scope for standard Swift, but this is the tightest achievable lifecycle.

---

### Bug 6 — LOW: `["0x0", "0x0"]` Signature Still Not a Real Signature

`RPCClient.swift:144`:
```swift
signature: [String] = ["0x0", "0x0"],
```

This is better than `[]` (which some sequencers immediately reject on schema validation), but it is not a cryptographically valid STARK signature over the transaction hash. Real Starknet sequencers running signature verification will reject it with `INVALID_TRANSACTION_NONCE` or `TRANSACTION_HASH_NOT_FOUND` (depending on the ECDSA library's failure mode). It will work on a local Katana devnet where `--no-mining` or `--disable-fee` modes may bypass signature checks. This is documented below as a known MVP limitation rather than a regression:

```swift
// NOTE: ["0x0", "0x0"] is a placeholder. Katana (local devnet) accepts this.
// Production requires: STARK-curve ECDSA signature over the Pedersen hash of the
// transaction fields using the account's spending key.
// Implement starknet_getNonce + sign(tx_hash, spendingKey) before Sepolia deployment.
signature: [String] = ["0x0", "0x0"],
```

---

## Summary Table

| # | Severity | File | Location | Status |
|---|----------|------|----------|--------|
| 1 | **CRITICAL** | WalletManager | `executeUnshield:263`, `executePrivateTransfer:151` | `owner_ivk` absent from SwiftData predicate → wrong note deleted |
| 2 | **HIGH** | WalletManager | `executeUnshield` post-RPC window | Force-close after RPC success creates phantom note; requires `isPendingSpend` state |
| 3 | **HIGH** | WalletManager | Line 224 | `UInt64(amount * 1e18)` traps for amounts > 18.44 tokens |
| 4 | **HIGH** | WalletManager | Line 228 | Selector `0x15d40a3d673baee5a4dd5f` is 92 bits, not a valid Starknet felt |
| 5 | **MEDIUM** | MnemonicSetupView | `verifyAndSave:217` | `Task.detached` captured mnemonic copy outlives `removeAll()` on @State |
| 6 | **LOW** | RPCClient | Line 144 | `["0x0","0x0"]` signature accepted by Katana, rejected by any production sequencer |

Bugs 1 and 3 are the only ones that can silently destroy user funds without any visible error. Bug 1's fix is a one-line addition of `&& $0.owner_ivk == inputNote.owner_ivk` in two places. Bug 3's fix is the clamped conversion shown above. Both should be applied before any further testing.
