# Phase 3 Security Audit — StarkVeil iOS (Comprehensive End-to-End Audit)

## Audit Prompt

You are a security and privacy auditor for StarkVeil, a Starknet shielded wallet based on STARK proofs and a privacy pool. Your job is to conduct a comprehensive end-to-end audit of the latest codebase changes.

SCOPE: Review the following files for security, privacy, correctness, and UX consistency:

Core:
- ios/StarkVeil/StarkVeil/Core/WalletManager.swift
- ios/StarkVeil/StarkVeil/Core/KeychainManager.swift
- ios/StarkVeil/StarkVeil/Core/AppSettings.swift
- ios/StarkVeil/StarkVeil/Core/RPCClient.swift

Views:
- ios/StarkVeil/StarkVeil/Views/ReceiveView.swift
- ios/StarkVeil/StarkVeil/Views/ShieldView.swift
- ios/StarkVeil/StarkVeil/Views/SwapView.swift
- ios/StarkVeil/StarkVeil/Views/ZKProofsView.swift
- ios/StarkVeil/StarkVeil/Views/SettingsView.swift
- ios/StarkVeil/StarkVeil/Views/WalletInfoView.swift
- ios/StarkVeil/StarkVeil/Views/VaultView.swift
- ios/StarkVeil/StarkVeil/Views/UnshieldFormView.swift
- ios/StarkVeil/StarkVeil/Views/Components/ShieldedBalanceCard.swift
- ios/StarkVeil/StarkVeil/Views/Components/VaultHeaderView.swift

AUDIT CRITERIA (priority order):
1. CRITICAL SECURITY: Are any private keys, seeds, spending keys, or mnemonics ever surfaced in the UI, logs, or exported data? Flag any violation immediately.
2. PRIVACY LEAKS: Does any operation reveal more than it should on-chain? Shield reveals sender+amount (expected). Transfers and unshields should be private. Flag any unexpected public data leakage.
3. MEMORY SAFETY: Are sensitive values (IVK, seed bytes) wiped from memory after use? Look for lingering String/Data references in @State variables or closures.
4. REENTRANCY / RACE CONDITIONS: Are there double-send, double-spend, or concurrent transfer bugs? Check isTransferInFlight guards and @MainActor isolation.
5. INPUT VALIDATION: Are all user-facing amount fields validated (overflow, negative, NaN, Infinity)? Is recipient address validated before submitting RPC?
6. UX SECURITY: Are destructive actions (Delete Wallet, Clear History) gated with biometric auth AND double confirmation?
7. ZODL PARITY: Does the privacy UX match ZODL/Zashi standards? Every transaction should be private by default. Check that no flow accidentally exposes the user publicly without warning.
8. COMPILE-TIME ISSUES: Are there any missing environment objects, broken bindings, or type errors you can spot from reading the code?

For each issue found, report:
- Severity: CRITICAL / HIGH / MEDIUM / LOW
- File + line number (approximate)
- Description of the problem
- Recommended fix

After the audit, provide a summary score (0-10) for: Security, Privacy, Code Quality, ZODL Parity.

---

## Audit Findings

I've now read all 14 files in full. Let me conduct the systematic audit.

---

# StarkVeil iOS — Comprehensive Security & Privacy Audit

---

## CRITICAL

---

### [C1] Runtime Crash: `AppSettings` Missing from Environment Chain
**File:** `VaultView.swift:8`, `StarkVeilApp.swift` (from prior session reads)
**Severity:** CRITICAL — instant crash on Settings tab

`VaultView` declares `@EnvironmentObject private var appSettings: AppSettings`, and `SettingsView` (a direct child) also requires it. `StarkVeilApp.swift` injects only `[themeManager, networkManager, walletManager, syncEngine]` into `VaultView`. `AppSettings` is never added to `AppCoordinator` and never injected into the environment. The app will crash with `"Fatal error: No ObservableObject of type AppSettings found"` the moment the Settings tab is selected.

**Fix:**
```swift
// AppCoordinator — add one line:
let appSettings = AppSettings()

// StarkVeilApp.swift — add one line to the environment chain:
VaultView()
    .environmentObject(coordinator.themeManager)
    .environmentObject(coordinator.networkManager)
    .environmentObject(coordinator.walletManager)
    .environmentObject(coordinator.syncEngine)
    .environmentObject(coordinator.appSettings)   // ← missing
    .transition(.opacity)
```

---

### [C2] STARK Proof Bytes Printed to Console in Production
**File:** `WalletManager.swift:204`
**Severity:** CRITICAL (information leak in production builds)

```swift
print("STARK Proof generated: \(result.proof)")
```

This emits the full proof payload to `stderr`. On a developer-attached device the console is readable by any process with the right entitlement. In production, iOS system logs are uploaded to Apple, aggregated by crash reporters, and visible in `Console.app`. Proof elements are public inputs but they contain nullifiers and note commitments that reveal the user's UTXO structure.

**Fix:**
```swift
#if DEBUG
print("[DEBUG] STARK Proof generated: \(result.proof.prefix(3))… (\(result.proof.count) elements)")
#endif
```

---

## HIGH

---

### [H1] IVK Transmitted as Raw On-Chain Calldata — Links All Deposits to One Identity
**File:** `WalletManager.swift:452–454`
**Severity:** HIGH — core privacy architecture flaw

```swift
let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x3", "0x3",
                amountLow, amountHigh, ivkHex]   // ← IVK is public on-chain
```

Every `shield()` call broadcasts `ivkHex` in transaction calldata. Because a single IVK is derived deterministically from the master seed and reused for every deposit, **any blockchain observer can enumerate all shield transactions that share the same IVK and attribute them to a single wallet**, regardless of which public Starknet address initiated each deposit. The documented privacy model states *"the deposit amount is visible on-chain. Everything after is private"* — this is incomplete. The IVK is also visible, which contradicts the IVK docstring in `ReceiveView.swift` that claims it *"cannot link to past transactions."*

The fix follows Zcash's diversified address model: derive a one-time subkey per deposit rather than passing the root IVK.

**Fix — `WalletManager.executeShield`:**
```swift
// Replace the raw ivkHex in calldata with a nonce-derived one-time viewing key.
// HKDF(ikm=ivkData, info="shield-nonce-v1" || nonce, length=32)
let shieldNonce = UUID().uuidString
guard let ivkData = KeychainManager.ownerIVK() else {
    throw NSError(domain: "StarkVeil", code: 1,
                  userInfo: [NSLocalizedDescriptionKey: "Wallet not initialised."])
}
let infoData = Data(("shield-nonce-v1" + shieldNonce).utf8)
let oneTimeKey = HKDF<SHA256>.deriveKey(
    inputKeyMaterial: SymmetricKey(data: ivkData),
    info: infoData,
    outputByteCount: 32
)
let oneTimeKeyHex = "0x" + oneTimeKey.withUnsafeBytes {
    $0.map { String(format: "%02x", $0) }.joined()
}

// Use oneTimeKeyHex in calldata instead of ivkHex.
// The note locally still records ivkHex so SyncEngine can detect it.
let calldata = ["0x1", contractAddress, shieldSelector, "0x0", "0x3", "0x3",
                amountLow, amountHigh, oneTimeKeyHex]
```

---

### [H2] Biometric Lock Setting Is Stored But Never Enforced
**File:** `AppSettings.swift:9–11`, `VaultView.swift`
**Severity:** HIGH — advertised security feature is non-functional

`AppSettings.isBiometricLockEnabled` is a `@Published` property persisted to `UserDefaults`. There is no `LAContext.evaluatePolicy` call anywhere that gates access to `VaultView` when this setting is `true`. A user who enables "Biometric Lock" in Settings reasonably believes their wallet is protected — it is not.

**Fix — Add a `BiometricLockView` gate in `StarkVeilApp.swift`:**
```swift
@main
struct StarkVeilApp: App {
    @StateObject private var coordinator = AppCoordinator()
    @StateObject private var appSettings = AppSettings()
    @State private var isWalletSetUp = KeychainManager.hasWallet
    @State private var isUnlocked = false

    var body: some Scene {
        WindowGroup {
            if isWalletSetUp {
                if appSettings.isBiometricLockEnabled && !isUnlocked {
                    BiometricGateView(onUnlock: { isUnlocked = true })
                        .environmentObject(coordinator.themeManager)
                } else {
                    VaultView()
                        .environmentObject(coordinator.themeManager)
                        .environmentObject(coordinator.networkManager)
                        .environmentObject(coordinator.walletManager)
                        .environmentObject(coordinator.syncEngine)
                        .environmentObject(appSettings)
                        .onReceive(NotificationCenter.default.publisher(
                            for: UIApplication.willResignActiveNotification)
                        ) { _ in
                            if appSettings.autoLockTimeout.rawValue > 0 {
                                isUnlocked = false
                            }
                        }
                }
            } else {
                WalletOnboardingView { ... }
            }
        }
    }
}

struct BiometricGateView: View {
    let onUnlock: () -> Void
    var body: some View {
        // LAContext.evaluatePolicy(.deviceOwnerAuthentication, ...) on appear
    }
}
```

---

### [H3] Delete Wallet Leaves Notes for Non-Active Networks in SwiftData
**File:** `SettingsView.swift:281–286`, `WalletManager.swift:140–158`
**Severity:** HIGH — private data survives wallet deletion

`performWalletDeletion()` calls `walletManager.clearStore()`, which only fetches and deletes `StoredNote` records matching `activeNetworkId`. If the user was on Sepolia when they deleted, all Mainnet notes remain in SwiftData on disk. The Keychain seed is wiped, making the notes unspendable, but they are still readable from the device's SwiftData store — a forensic privacy violation.

**Fix — `SettingsView.swift:281`:**
```swift
private func performWalletDeletion() {
    KeychainManager.deleteWallet()

    // Wipe ALL notes and events across ALL networks, not just activeNetworkId.
    let ctx = PersistenceController.shared.context
    if let allNotes = try? ctx.fetch(FetchDescriptor<StoredNote>()) {
        allNotes.forEach { ctx.delete($0) }
    }
    if let allEvents = try? ctx.fetch(FetchDescriptor<ActivityEvent>()) {
        allEvents.forEach { ctx.delete($0) }
    }
    do { try ctx.save() }
    catch { print("[Settings] CRITICAL: SwiftData wipe failed: \(error)") }

    walletManager.notes.removeAll()
    walletManager.activityEvents.removeAll()
    onWalletDeleted?()
}
```

---

### [H4] Private Transfer Recipient Partially Stored in Activity Log
**File:** `WalletManager.swift:255–261`
**Severity:** HIGH — privacy violation in local persistent store

```swift
logEvent(
    kind: .transfer,
    amount: String(format: "%.6f", amount),
    assetId: inputNotes.first?.asset_id ?? "0xETH",
    counterparty: String(recipient.prefix(20)) + "…",  // ← 20 chars of private recipient
    txHash: lastProvedTxHash
)
```

`ActivityEvent.counterparty` is persisted to SwiftData and surfaced in the ZK Proofs tab. Even a 20-character prefix of a private recipient address is a meaningful correlation anchor. `counterparty` for the `unshield` event (line 385-388) correctly includes the recipient (which is already public on-chain), but for private transfers the recipient should be opaque.

**Fix — `WalletManager.swift:259`:**
```swift
counterparty: "Private",   // Never log even partial private recipients
```

---

## MEDIUM

---

### [M1] Optimistic `addNote` Creates Duplicate UTXO When SyncEngine Fires
**File:** `WalletManager.swift:462–471`
**Severity:** MEDIUM — phantom double balance

`executeShield` calls `addNote(note)` immediately after the RPC transaction is confirmed. The `SyncEngine` will later detect the on-chain `Shielded` event and call `addNote` again with the same note. `addNote` has no deduplication check — it always appends to the array and inserts a new `StoredNote` row. Since each `StoredNote` gets a fresh `UUID` for `id`, the SwiftData `@Attribute(.unique)` constraint does not catch the duplicate. The user's balance doubles.

**Fix — `WalletManager.addNote`:**
```swift
func addNote(_ note: Note) {
    // Deduplicate by value + asset + ivk + memo before inserting.
    let isDuplicate = notes.contains {
        $0.value == note.value && $0.asset_id == note.asset_id &&
        $0.owner_ivk == note.owner_ivk && $0.memo == note.memo
    }
    guard !isDuplicate else { return }
    notes.append(note)
    recomputeBalance()
    let ctx = persistence.context
    ctx.insert(StoredNote(from: note, networkId: activeNetworkId))
    do { try ctx.save() }
    catch { print("[WalletManager] CRITICAL: SwiftData save failed in addNote: \(error)") }
    logEvent(kind: .deposit, amount: note.value, assetId: note.asset_id, counterparty: "Shielded Deposit")
}
```

---

### [M2] Swap Permanently Burns Notes Without AMM Execution
**File:** `SwapView.swift:335–354`
**Severity:** MEDIUM — user loses funds, success banner is misleading

```swift
try await walletManager.executePrivateTransfer(
    recipient: "0xSHIELDED_POOL_ROUTER",   // ← stub address, no router exists
    amount: amount
)
// Shows: "Swap submitted via shielded proof!" ← FALSE
```

`executePrivateTransfer` removes the STRK notes from the UTXO set. No `toToken` notes are created. The user sees a success banner and an empty balance where their STRK was. Until AMM integration is real, this button should be disabled.

**Fix — `SwapView.swift:145`:**
```swift
Button(action: executeSwap) { ... }
.disabled(true)  // Re-enable when AMM integration is complete
.overlay(
    Text("Coming soon")
        .font(.caption)
        .foregroundStyle(themeManager.textSecondary)
        .padding(.top, 60),
    alignment: .top
)
```

---

### [M3] Note Visual Selection Compares Only by `.value`
**File:** `UnshieldFormView.swift:62`
**Severity:** MEDIUM — user may believe wrong note is selected

```swift
isSelected: selectedNote?.value == note.value
```

If two notes share the same `value` string, both highlight simultaneously. The correct note is passed to `executeUnshield` (via the `selectedNote` object), but the visual state is misleading — users in a multi-note wallet cannot reliably see which note is selected.

**Fix:**
```swift
isSelected: selectedNote?.value    == note.value    &&
            selectedNote?.owner_ivk == note.owner_ivk &&
            selectedNote?.memo      == note.memo
```

---

### [M4] Activity Export Includes Shielded Transfer Amounts
**File:** `ZKProofsView.swift:240–254`
**Severity:** MEDIUM — private amounts leave the device

The export produces:
```json
{ "type": "transfer", "amount": "1.234560", "tx_hash": "...", "timestamp": "..." }
```

Shield and unshield amounts are already on-chain (acceptable). Private transfer amounts are supposed to be entirely private — they should never appear in any exported record.

**Fix — `ZKProofsView.swift:242`:**
```swift
"amount": event.kind == .transfer ? "private" : event.amount,
```

---

### [M5] `executeShield` Guard Order Inverted vs All Other Operations
**File:** `WalletManager.swift:409–410`
**Severity:** MEDIUM — inconsistency invites future re-entrancy bugs

```swift
// executeShield (WRONG ORDER):
guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
guard !isTransferInFlight else { throw ProverError.transferInProgress }

// executePrivateTransfer / executeUnshield (CORRECT ORDER):
guard !isTransferInFlight else { throw ProverError.transferInProgress }
guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
```

The re-entrancy flag should always be checked **first**, before any other logic, to make the serialization contract clear. While `@MainActor` prevents true concurrent interleaving, the inverted order is a maintenance hazard.

**Fix — `WalletManager.swift:409`:**
```swift
guard !isTransferInFlight else { throw ProverError.transferInProgress }
guard amount > 0, amount.isFinite else { throw ProverError.invalidAmount }
```

---

### [M6] Missing Recipient Format Validation in `executePrivateTransfer`
**File:** `WalletManager.swift:179`, `VaultView.swift:194`
**Severity:** MEDIUM — malformed calldata submitted silently

`SendSheetView.canSend` checks `!recipientAddress.isEmpty` but allows any non-empty string. `WalletManager.executePrivateTransfer` has no recipient validation at all. A user who accidentally enters a display name, ENS handle, or whitespace-only address will pass the guard and produce invalid calldata.

**Fix — `WalletManager.swift:182`:**
```swift
guard !recipient.isEmpty, recipient.hasPrefix("0x"), recipient.count >= 18 else {
    throw ProverError.invalidAmount  // or add ProverError.invalidRecipient
}
```

---

### [M7] ZKProofsView Double-Reverses the Activity Array
**File:** `ZKProofsView.swift:58`
**Severity:** MEDIUM — UX bug, oldest proofs shown at top

`activityEvents` is loaded with `order: .reverse` (newest first) and new events are inserted at index 0. `ForEach(walletManager.activityEvents.reversed())` then reverses this again — oldest proofs appear at the top of the list.

**Fix — `ZKProofsView.swift:58`:**
```swift
ForEach(walletManager.activityEvents) { event in   // already newest-first; remove .reversed()
```

---

## LOW

---

### [L1] "Public Address" in ReceiveView Is a Fabricated IVK Substring
**File:** `ReceiveView.swift:31–34`
**Severity:** LOW — potentially misleading to users

```swift
private var publicAddress: String {
    return "0x" + ivkHex.dropFirst(2).prefix(10) + "…" + ivkHex.suffix(8)
}
```

This is explicitly commented as "not a real spending address", but presenting it under the heading "Public Address (for reference)" could lead users to share it as a Starknet L1 address, causing lost funds from external senders. Remove this card until a real account address derivation is implemented.

---

### [L2] Info Buttons Are No-Ops
**File:** `ReceiveView.swift:109, 212`
**Severity:** LOW — dead UI, reduces trust

```swift
Button(action: {}) { Image(systemName: "info.circle") }
```

Both info buttons do nothing on tap. Either implement them (explain what IVK is, explain what the public address card means) or remove them.

---

### [L3] Private Transfer Proofs Labelled "VERIFIED ✓"
**File:** `ZKProofsView.swift:144`
**Severity:** LOW — misrepresents on-chain finality

Private transfers use a nullifier-derived mock tx hash and are never submitted on-chain. Labelling them "VERIFIED ✓" implies sequencer confirmation that has not occurred.

**Fix:**
```swift
Text(event.kind == .transfer
     ? "PROVED (local)"
     : (event.txHash != nil ? "VERIFIED ✓" : "PENDING"))
```

---

### [L4] Payment Request URL Encodes Requested Amount in Clipboard
**File:** `ReceiveView.swift:251`
**Severity:** LOW — amount privacy via pasteboard

```swift
let request = "starkveil://receive?ivk=\(ivkHex)&amount=\(requestAmount)"
UIPasteboard.general.string = request
```

Any app with pasteboard access can read the requested amount. Add a clipboard expiry.

**Fix:**
```swift
UIPasteboard.general.setItems(
    [[UIPasteboard.typeAutomatic: request]],
    options: [.expirationDate: Date().addingTimeInterval(120)]
)
```

---

### [L5] TextField Placeholder Reads "ZEC" in Send Sheet
**File:** `VaultView.swift:255`
**Severity:** LOW — copy-paste artifact from Zcash reference

```swift
TextField("ZEC", text: $transferAmount)
```

Should read `"STRK"` or `"0.0"`.

---

## Summary Scores

| Category | Score | Notes |
|---|---|---|
| **Security** | **4.5 / 10** | Re-entrancy guards and Keychain are correct. Biometric lock entirely unenforced. AppSettings crash on Settings tab. Proof logged to console. |
| **Privacy** | **4 / 10** | IVK broadcast in shield calldata links all deposits. Recipient partially stored in activity log. Transfer amounts exportable. Privacy model comments are inaccurate. |
| **Code Quality** | **6.5 / 10** | @MainActor isolation, isPendingSpend two-phase commit, and defer placement are solid. Duplicate isShielding state, inverted guard order, double-reversed ForEach, and dead UI buttons are rough edges. |
| **ZODL Parity** | **6 / 10** | Visual language closely mirrors ZODL (dashes, shield-first UX, purple card, privacy banners, four-action grid). Gaps: Swap destroys notes without AMM, "VERIFIED ✓" misrepresents private transfers, biometric lock is decorative. |

### Priority Order for Fixes
1. **C1** — AppSettings crash (one line, ship today)
2. **H2** — Biometric enforcement (blocks any production release)
3. **H3** — Delete Wallet wipes wrong networks (data retention risk)
4. **H1** — IVK in shield calldata (architectural privacy flaw)
5. **H4** — Recipient in activity log (privacy violation in persisted store)
6. **M2** — Swap destroys notes (user fund loss, even if only proving-layer today)
7. **C2** — Remove proof print statement before any TestFlight build
