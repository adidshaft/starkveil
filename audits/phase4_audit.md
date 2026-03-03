# Phase 4 Security Audit — StarkVeil iOS (Deep Audit of Modified Files)

## Audit Prompt

Conduct a deep security and correctness audit of the following recently modified StarkVeil iOS Swift files. Focus entirely on real-world attack surfaces and implementation flaws — not style issues.

Files to audit:
1. WalletManager.swift (executeShield, executeUnshield, executePrivateTransfer, logEvent, deleteAllNetworksData)
2. SyncEngine.swift (event decoder loop — verify the new Keychain IVK fetch path)
3. StarkVeilApp.swift (BiometricGateView — LAContext usage)
4. ActivityEvent.swift (SwiftData model)

Specific questions to answer:
1. **Shield Selector**: Is `0x224a8f74e6fd7a11ab9e36f7742dd64470a7b2e3541b802eb7ed24087db909` the correct Starknet Keccak-250 selector for function name "shield"? Cross-check with Python: `int(hashlib.sha3_256(b"shield").hexdigest(), 16) & ((1<<250)-1)`.
2. **Unshield Selector**: Same check for `0x21eefa4f46062f7986b501187c7684110faa0fa374c2819584d21a92ace0fac` against "unshield".
3. **SyncEngine IVK**: The SyncEngine now calls `KeychainManager.ownerIVK()` inside an async background loop. Is it safe to call a Keychain API from a background thread? Can IVK be nil between app launch and wallet setup?
4. **BiometricGateView**: Does `.deviceOwnerAuthentication` fall back gracefully to passcode when Face ID/Touch ID is not enrolled? Is there any bypass path (e.g. swipe dismiss) that skips the gate?
5. **ActivityEvent privacy**: Does storing `counterparty: "shielded-recipient"` and `counterparty: "public-unshield"` adequately protect unlinkability? Is any other field in `ActivityEvent` a de-anonymization risk?
6. **deleteAllNetworksData**: Does the function properly wipe ALL networks' notes and events? Is there any race condition if called while a transfer is in-flight?

For every issue found, provide the exact Swift code fix.

---

## Audit Findings

Good, I have all four files. Now conducting the structured Phase 4 audit.

---

## Phase 4 Deep Security Audit

### Q1 & Q2 — Selector Correctness

**Shield:** `0x224a8f74e6fd7a11ab9e36f7742dd64470a7b2e3541b802eb7ed24087db909` (62 hex chars = 248 bits)
**Unshield:** `0x21eefa4f46062f7986b501187c7684110faa0fa374c2819584d21a92ace0fac` (63 hex chars = 250 bits)

Both values have the correct **format** for a Starknet keccak-250 selector: top nibble <= `0x3` (the 250-bit mask zeroes the top 6 bits), which both satisfy (`0x2...`). **However, I cannot verify the actual hash value without executing the computation.** You must cross-check before production:

```python
from starknet_py.hash.selector import get_selector_from_name
print(hex(get_selector_from_name("shield")))    # must equal 0x0224a8f7...
print(hex(get_selector_from_name("unshield")))  # must equal 0x021eefa4...
```

If the selectors are wrong, the sequencer will reject every invoke with a `ENTRY_POINT_NOT_FOUND` error. **Flag: unverified — block production launch on this check.**

---

### Q3 — SyncEngine Keychain Access from Background Thread

`KeychainManager.ownerIVK()` at `SyncEngine.swift:182` runs inside a plain `Task {}` (cooperative thread pool, off main thread). The iOS Security framework serialises Keychain operations internally — this is **thread-safe at the OS level**.

The `nil → continue` guard is correct for the wallet-not-yet-set-up race. No threading bug here.

**However, while auditing this path I found two new bugs:**

---

### CRITICAL-NEW-1 — Phantom Random Balance in SyncEngine (`SyncEngine.swift:190`)

```swift
value: String(format: "%.9f", amountDouble > 0 ? amountDouble : Double.random(in: 0.1...5.0)),
```

If any on-chain event has an amount of zero (or if the u128 low-limb is `0x0`), `amountDouble == 0.0` and a **random value between 0.1 and 5.0 STRK** is stored as the note's value. This:

1. Inflates the displayed balance with non-spendable phantom notes
2. Produces a different random value on every sync cycle — the deduplication check (when added) will never catch it because the `value` field changes each run
3. Is visible to the user as real balance

**Fix — `SyncEngine.swift:190`** (replace the note construction block):

```swift
guard amountDouble > 0 else { continue }   // drop zero-value events
let note = Note(
    value: String(format: "%.9f", amountDouble),
    asset_id: "0xSTRK",
    owner_ivk: ivkHex,
    memo: "Shielded: \(commitment.prefix(10))…"
)
```

---

### CRITICAL-NEW-2 — `addNote` Still Missing Deduplication (`WalletManager.swift:127-139`)

The M1 fix from Phase 3 was recommended but **never applied**. Current code:

```swift
func addNote(_ note: Note) {
    notes.append(note)    // ← always appends, no duplicate check
    recomputeBalance()
```

After a cold restart, `loadCheckpoint` may return a stale block, causing SyncEngine to re-scan blocks already credited. Every re-scanned event fires `noteDetected` → `addNote` → duplicate UTXO with inflated balance. Combined with CRITICAL-NEW-1 (random value), each duplicate also gets a new random amount, making reconciliation impossible.

**Fix — `WalletManager.swift:127`**:

```swift
func addNote(_ note: Note) {
    let isDuplicate = notes.contains {
        $0.value == note.value &&
        $0.asset_id == note.asset_id &&
        $0.owner_ivk == note.owner_ivk &&
        $0.memo == note.memo
    }
    guard !isDuplicate else { return }
    notes.append(note)
    recomputeBalance()
    // ... rest unchanged
```

---

### Q4 — BiometricGateView: LAContext Bypass Paths

**HIGH-1 — No auto-lock on backgrounding** (`StarkVeilApp.swift:119-129`)

`isAuthenticated` is a `@State` value. Once set to `true`, it persists for the entire app session even after the user backgrounds the app for hours. `AppSettings.autoLockTimeout` is stored in UserDefaults but **never enforced**. An attacker with brief physical access to an already-unlocked device has full wallet access.

**Fix — add scene-phase observer to `BiometricGateView`**:

```swift
@Environment(\.scenePhase) private var scenePhase

var body: some View {
    if !appSettings.isBiometricLockEnabled || isAuthenticated {
        VaultView(onWalletDeleted: onWalletDeleted)
            .onChange(of: scenePhase) { _, phase in
                if phase == .background, appSettings.isBiometricLockEnabled {
                    isAuthenticated = false   // re-arm on next foreground
                }
            }
    } else {
        lockScreen.onAppear(perform: authenticate)
    }
}
```

**LOW-1 — `canEvaluatePolicy` failure → unconditional unlock** (`StarkVeilApp.swift:167-170`)

```swift
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    isAuthenticated = true   // ← grants access when policy evaluation fails
    return
}
```

If `biometryNotEnrolled` is returned *and* no passcode is set, the gate opens without any challenge. This is a standard iOS constraint (you cannot force authentication on a device with no security), but the behaviour should be logged and the user warned:

```swift
guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
    // No authentication mechanism available — warn rather than silently unlock
    authError = "No device passcode or biometrics are set up. Set a passcode in iOS Settings to enable wallet lock."
    isAuthenticated = true   // still let through — cannot block
    return
}
```

**LOW-2 — Hardcoded Face ID icon** (`StarkVeilApp.swift:153`)

```swift
Image(systemName: "faceid")   // wrong on Touch ID devices
```

Fix: `Image(systemName: context.biometryType == .touchID ? "touchid" : "faceid")`

---

### Q5 — ActivityEvent Privacy Analysis

**Model fields and their risk profile:**

| Field | Transfer | Unshield | Deposit | Risk |
|-------|----------|----------|---------|------|
| `amount` | "1.500000" | "1.500000" | "1.500000" | **MEDIUM** — exact amount stored |
| `counterparty` | "shielded-recipient" | "public-unshield" | "Shielded Deposit" | PASS — opaque |
| `txHash` | fake UUID | real txHash | real txHash | LOW — UUID is not a real hash |
| `timestamp` | exact Date() | exact Date() | exact Date() | MEDIUM — timing correlation |
| `networkId` | "sepolia" | "sepolia" | "sepolia" | PASS |

**MEDIUM — Timing + Amount Correlation**

For `unshield` events: the amount and timestamp are already public on-chain. The local log adds nothing new. For `transfer` events: the amount is **NOT** public (the whole point of STARK proofs is to hide it). A device-forensics attacker or a malicious backup can read every private transfer amount from the SwiftData store or the ZKProofsView export. This partially undermines the privacy model.

**LOW — txHash update race in `executeShield` (`WalletManager.swift:513-518`)**

```swift
if let last = activityEvents.first, last.txHash == nil, last.kind == .deposit {
    last.txHash = txHash
```

If SyncEngine fires between the RPC return and this line and inserts another deposit event, `activityEvents.first` would be the **SyncEngine's event**, not the one just created by `addNote()`. Wrong txHash is attached to wrong record. Low severity (cosmetic), but breaks the "Tx: ..." display in the Activity tab.

Fix: capture the event reference before the `await`:

```swift
// In executeShield, before the await RPCClient call:
let depositEvent = logEvent(kind: .deposit, amount: ..., ...)   // logEvent is @discardableResult, capture it

// After txHash is received:
depositEvent.txHash = txHash
try? persistence.context.save()
```

But this requires moving `addNote()` call to before the RPC submit, which conflicts with the audit requirement to not add notes before RPC confirmation. Safest fix is to pass `txHash` into `addNote` and have it call `logEvent` with the hash directly, removing the patch-up block entirely.

---

### Q6 — `deleteAllNetworksData` Race Conditions

**Verdict: No real race due to @MainActor serialisation.** Because `WalletManager` is `@MainActor`, `deleteAllNetworksData` and any in-flight transfer's resumption on the main actor are strictly serialised. The in-flight Task's `defer` block will eventually reset `isTransferInFlight = false` after the deletion completes — this is safe because the VaultView is already gone by then.

**LOW-MEDIUM — Silent data persistence on SwiftData fetch failure**

```swift
if let allNotes = try? ctx.fetch(FetchDescriptor<StoredNote>()) {   // try? silently swallows
    allNotes.forEach { ctx.delete($0) }
}
// Same for ActivityEvent
do { try ctx.save() }
```

If either `try? ctx.fetch` fails (returns `nil` due to a SwiftData error), the corresponding records are **never deleted** but the UI reports the wallet as deleted. On next launch, `KeychainManager.hasWallet` returns `false` (seed was wiped), but SwiftData still contains notes — a weird partial state where there's no wallet but there's balance data.

**Fix:**

```swift
func deleteAllNetworksData() {
    if isTransferInFlight { transferError = "Transfer cancelled: wallet was deleted." }
    notes.removeAll()
    activityEvents.removeAll()
    recomputeBalance()
    let ctx = persistence.context
    do {
        let allNotes   = try ctx.fetch(FetchDescriptor<StoredNote>())
        let allEvents  = try ctx.fetch(FetchDescriptor<ActivityEvent>())
        allNotes.forEach  { ctx.delete($0) }
        allEvents.forEach { ctx.delete($0) }
        try ctx.save()
    } catch {
        // Still wiped from memory; log the failure clearly
        print("[WalletManager] CRITICAL: deleteAllNetworksData SwiftData wipe failed: \(error). Manual clear required.")
    }
}
```

---

### CRITICAL-COMPILE — Duplicate `showSendSheet` in `VaultView.swift`

This was noted in the context but needs explicit confirmation — `VaultView.swift:22` and `VaultView.swift:28` both declare `@State private var showSendSheet = false`. **This is a compile error; the file cannot build.** The three orphaned state variables from the old inlined send sheet (`transferAmount`, `recipientAddress`, `errorMessage`) must also be removed since the send sheet was extracted:

```swift
// REMOVE these four (lines 22-25) — they belong to the extracted SendSheetView now:
@State private var showSendSheet = false      // ← duplicate & belongs to nested view
@State private var transferAmount = ""         // ← unused at VaultView scope
@State private var recipientAddress = ""       // ← unused at VaultView scope
@State private var errorMessage: String? = nil // ← unused at VaultView scope

// KEEP these two (lines 28-29):
@State private var showSendSheet     = false
@State private var showUnshieldSheet = false
```

**Fix — `VaultView.swift`:** Delete lines 22–25, keeping only the declarations at lines 28–29.

---

### MEDIUM — `executeShield` Silently Caps Large Amounts (`WalletManager.swift:477-482`)

```swift
if amountWei > Double(UInt64.max) {
    safeAmountWei = UInt64.max   // ← caps at ~18.44 STRK, no error thrown
} else {
    safeAmountWei = UInt64(amountWei)
}
let amountLow  = String(format: "0x%llx", safeAmountWei)
let amountHigh = "0x0"   // ← always 0, even for large amounts
```

For amounts > 18.44 STRK, the contract receives `UInt64.max` wei (≈18.44 STRK) with `amountHigh = "0x0"` — a silent truncation, not a thrown error. Users would lose the excess amount.

`executeUnshield` correctly splits into `(low, high)`. Apply the same pattern here:

```swift
let amountWei = amount * 1e18
let amountLow: String
let amountHigh: String
if amountWei < Double(UInt64.max) {
    amountLow  = String(format: "0x%llx", UInt64(amountWei))
    amountHigh = "0x0"
} else {
    let hi = UInt64(amountWei / Double(UInt64.max))
    let lo = UInt64(amountWei.truncatingRemainder(dividingBy: Double(UInt64.max)))
    amountLow  = String(format: "0x%llx", lo)
    amountHigh = String(format: "0x%llx", hi)
}
```

---

## Phase 4 Complete Findings Summary

| ID | Severity | File | Description |
|----|----------|------|-------------|
| **C-NEW-1** | CRITICAL | SyncEngine.swift:190 | `Double.random()` phantom balance for zero-amount events |
| **C-NEW-2** | CRITICAL | WalletManager.swift:127 | `addNote` missing deduplication (M1 fix was never applied) |
| **C-COMPILE** | COMPILE ERROR | VaultView.swift:22-28 | Duplicate `@State var showSendSheet` declaration |
| **H-LOCK** | HIGH | StarkVeilApp.swift:119 | No auto-lock on backgrounding — `isAuthenticated` persists all session |
| **M-SHIELD-AMOUNT** | MEDIUM | WalletManager.swift:477 | Shield silently caps amounts > 18.44 STRK, no error thrown |
| **M-AMOUNT-LOG** | MEDIUM | ActivityEvent.swift | Transfer amounts stored in local log, undermines ZK privacy on forensics |
| **M-TXHASH-RACE** | MEDIUM | WalletManager.swift:513 | txHash patched onto wrong deposit event if SyncEngine races |
| **L-SELECTORS** | UNVERIFIED | WalletManager.swift:374,493 | Selector values not independently verified — must run Python cross-check |
| **L-WIPE-SILENT** | LOW | WalletManager.swift:172 | `try?` on fetch in deleteAllNetworksData swallows errors, leaving stale data |
| **L-FACEID-ICON** | LOW | StarkVeilApp.swift:153 | Hardcoded `faceid` icon on Touch ID devices |
| **L-NO-PASSCODE-MSG** | LOW | StarkVeilApp.swift:167 | No user message when `canEvaluatePolicy` fails |

**Revised Scores (post Phase 4):**

| Dimension | Phase 3 | Phase 4 Delta | Current |
|-----------|---------|---------------|---------|
| Security | 4.5/10 | +0.5 (biometric gate added) | **5.0/10** |
| Privacy | 4.0/10 | +1.0 (IVK fix, counterparty fix) | **5.0/10** |
| Code Quality | 6.5/10 | -0.5 (compile error, random balance) | **6.0/10** |
| ZODL Parity | 6.0/10 | no change | **6.0/10** |

The two blocking issues before the next build can even run are **C-COMPILE** (VaultView won't build) and **C-NEW-1** (phantom balance corrupts every sync). Fix those two first, then **H-LOCK** (auto-lock), then verify the selectors offline.
