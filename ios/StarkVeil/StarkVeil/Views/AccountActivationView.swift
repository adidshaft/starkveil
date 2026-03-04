import SwiftUI
import CryptoKit

// MARK: - Account Activation View  (Phase 11)
//
// Shown whenever the wallet has been set up (seed phrase stored) but the
// Starknet account contract has not yet been deployed.
//
// Flow:
//  1. App computes the counterfactual address and displays it with a QR code.
//  2. User sends ETH or STRK to that address for deployment gas.
//     Both tokens work — Starknet v0.13.1+ supports dual gas payment.
//  3. App checks both token balances in parallel.
//  4. User taps "Activate Wallet" → starknet_addDeployAccountTransaction is broadcast.
//  5. App polls for tx confirmation → marks account deployed → navigates to VaultView.

struct AccountActivationView: View {
    @EnvironmentObject private var themeManager: AppThemeManager
    @EnvironmentObject private var networkManager: NetworkManager

    let onActivated: () -> Void   // Called when deploy is confirmed

    // Account keys computed once from seed
    @State private var accountKeys: StarknetAccount.AccountKeys? = nil
    @State private var deploymentState: DeploymentState = .idle
    @State private var ethBalance: String = "0x0"
    @State private var strkBalance: String = "0x0"
    @State private var detectedGasToken: String = ""   // "ETH" | "STRK" | "both"
    @State private var deployTxHash: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isCopied = false

    enum DeploymentState {
        case idle            // Showing address, waiting for funding
        case checkingFunds   // Polling ETH + STRK balances
        case funded          // Balance > 0 detected in at least one gas token
        case deploying       // Deploy tx in-flight
        case confirming      // Polling for confirmation
        case deployed        // Done
        case error(String)
    }

    var body: some View {
        ZStack {
            themeManager.bgColor.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 32) {
                    headerSection
                    if let keys = accountKeys {
                        addressCard(keys: keys)
                        statusSection(keys: keys)
                    } else {
                        ProgressView()
                            .tint(themeManager.textPrimary)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 48)
                .padding(.bottom, 60)
            }
        }
        .onAppear { computeKeys() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 12) {
            Image(systemName: "wallet.pass.fill")
                .font(.system(size: 48))
                .foregroundStyle(themeManager.textPrimary)
            Text("Activate Your Wallet")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(themeManager.textPrimary)
            Text("Your Starknet account is ready.\nSend **ETH or STRK** for gas, then tap **Activate**.")
                .font(.system(size: 14))
                .foregroundStyle(themeManager.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Address Card

    private func addressCard(keys: StarknetAccount.AccountKeys) -> some View {
        VStack(spacing: 16) {
            // Real QR code using CoreImage — scannable address, zero external deps
            QRCodeView(data: keys.address, size: 200)
                .padding(12)
                .background(Color.white)   // white border ensures scanner contrast on any bg
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            // Address display
            VStack(alignment: .leading, spacing: 8) {
                Text("YOUR STARKNET ADDRESS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(themeManager.textSecondary)
                HStack {
                    Text(keys.address)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(themeManager.textPrimary)
                        .lineLimit(3)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 8)
                    Button(action: { copyAddress(keys.address) }) {
                        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 14))
                            .foregroundStyle(themeManager.textSecondary)
                            .animation(.easeInOut, value: isCopied)
                    }
                }
                .padding(14)
                .background(themeManager.surface1)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(themeManager.surface2, lineWidth: 1))
            }

            // Public key (for verification — advanced users)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    infoRow(label: "Public Key", value: keys.publicKey.hexString)
                    infoRow(label: "Network", value: networkManager.activeNetwork.rawValue)
                    infoRow(label: "Class Hash", value: StarknetCurve.ozAccountClassHash)
                }
                .padding(.top, 8)
            } label: {
                Text("Advanced Details")
                    .font(.system(size: 13))
                    .foregroundStyle(themeManager.textSecondary)
            }
            .padding(14)
            .background(themeManager.surface1)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - Status + Action

    @ViewBuilder
    private func statusSection(keys: StarknetAccount.AccountKeys) -> some View {
        switch deploymentState {
        case .idle:
            stepsList()
            checkFundsButton(keys: keys)

        case .checkingFunds:
            loadingRow("Checking ETH balance…")

        case .funded:
            fundedBanner()
            activateButton(keys: keys)

        case .deploying:
            loadingRow("Broadcasting deploy transaction…")

        case .confirming:
            if let hash = deployTxHash {
                txHashBadge(hash)
            }
            loadingRow("Confirming on Starknet…")

        case .deployed:
            deployedBanner()

        case .error(let msg):
            Text(msg)
                .font(.system(size: 13))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
            retryButton(keys: keys)
        }

        if let err = errorMessage {
            Text(err).font(.caption).foregroundStyle(.red).multilineTextAlignment(.center)
        }
    }

    // MARK: - Sub-views

    private func stepsList() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            stepRow(num: "1", text: "Send **ETH or STRK** to the address above for gas fees (~0.01 ETH or ~50 STRK is enough)")
            stepRow(num: "2", text: "Tap **Check Balance** once the transfer arrives")
            stepRow(num: "3", text: "Tap **Activate Wallet** — the app deploys your account contract")
            stepRow(num: "4", text: "Done! Your privacy shield is live.")
        }
        .padding(16)
        .background(themeManager.surface1)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func stepRow(num: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(num)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(themeManager.bgColor)
                .frame(width: 22, height: 22)
                .background(themeManager.textPrimary)
                .clipShape(Circle())
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .foregroundStyle(themeManager.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func checkFundsButton(keys: StarknetAccount.AccountKeys) -> some View {
        Button(action: { Task { await checkBalance(keys: keys) } }) {
            Text("Check Balance")
                .font(.headline.weight(.semibold))
                .foregroundStyle(themeManager.bgColor)
                .frame(maxWidth: .infinity)
                .padding()
                .background(themeManager.textSecondary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func activateButton(keys: StarknetAccount.AccountKeys) -> some View {
        Button(action: { Task { await deployAccount(keys: keys) } }) {
            Text("Activate Wallet")
                .font(.headline.weight(.heavy))
                .tracking(0.5)
                .foregroundStyle(themeManager.bgColor)
                .frame(maxWidth: .infinity)
                .padding()
                .background(themeManager.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func retryButton(keys: StarknetAccount.AccountKeys) -> some View {
        Button(action: { deploymentState = .idle; errorMessage = nil }) {
            Text("Try Again")
                .font(.headline)
                .foregroundStyle(themeManager.textSecondary)
        }
    }

    private func fundedBanner() -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                let tokenLabel = detectedGasToken.isEmpty ? "Gas token" : detectedGasToken
                Text("\(tokenLabel) detected — ready to activate!")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(themeManager.textPrimary)
            }
            if detectedGasToken == "both" {
                Text("Both ETH and STRK found — Starknet will use whichever covers the fee.")
                    .font(.system(size: 11))
                    .foregroundStyle(themeManager.textSecondary)
            }
        }
        .padding(12)
        .background(Color.green.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func deployedBanner() -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 48))
                .foregroundStyle(.green)
            Text("Wallet Activated!")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(themeManager.textPrimary)
            Text("Your Starknet account is live. Entering the vault…")
                .font(.system(size: 14))
                .foregroundStyle(themeManager.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    private func loadingRow(_ label: String) -> some View {
        HStack(spacing: 12) {
            ProgressView().tint(themeManager.textPrimary)
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(themeManager.textSecondary)
        }
    }

    private func txHashBadge(_ hash: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(themeManager.textSecondary)
            Text("Tx: \(hash.prefix(14))…")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(themeManager.textSecondary)
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(themeManager.textSecondary)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(themeManager.textPrimary)
                .lineLimit(2)
        }
    }

    // MARK: - Logic

    private func computeKeys() {
        Task {
            guard let seed = KeychainManager.masterSeed() else { return }
            do {
                let keys = try StarknetAccount.deriveAccountKeys(fromSeed: seed)
                // Cache address for quick display on future launches
                try? KeychainManager.storeAccountAddress(keys.address)
                await MainActor.run { accountKeys = keys }
            } catch {
                await MainActor.run {
                    errorMessage = "Key derivation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func checkBalance(keys: StarknetAccount.AccountKeys) async {
        await MainActor.run { deploymentState = .checkingFunds }
        let rpcUrl = networkManager.activeNetwork.rpcUrl
        let address = keys.address
        do {
            // Query ETH and STRK in parallel — Starknet v0.13.1+ supports both as gas tokens
            async let ethResult = RPCClient().getETHBalance(rpcUrl: rpcUrl, address: address)
            async let strkResult = RPCClient().getSTRKBalance(rpcUrl: rpcUrl, address: address)
            let (ethBal, strkBal) = try await (ethResult, strkResult)

            // Parse u256 low/high words — any non-zero word = funded
            // u256 is returned as [low_u128_hex, high_u128_hex].
            // Low word can be up to 128 bits (e.g. 0x821ab0d4414980000 = ~148 STRK)
            // which overflows UInt64 — do NOT parse with UInt64.
            // Instead: strip 0x, check that not all digits are '0'.
            func isFunded(_ bal: String) -> Bool {
                let parts = bal.split(separator: ",").map {
                    String($0).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "0x", with: "")
                        .replacingOccurrences(of: "0X", with: "")
                }
                return parts.contains { hex in
                    !hex.isEmpty && hex.contains(where: { $0 != "0" })
                }
            }
            let ethFunded  = isFunded(ethBal)
            let strkFunded = isFunded(strkBal)
            let anyFunded  = ethFunded || strkFunded

            let tokenLabel: String
            switch (ethFunded, strkFunded) {
            case (true, true):   tokenLabel = "both"
            case (true, false):  tokenLabel = "ETH"
            case (false, true):  tokenLabel = "STRK"
            default:             tokenLabel = ""
            }

            await MainActor.run {
                ethBalance   = ethBal
                strkBalance  = strkBal
                detectedGasToken = tokenLabel
                deploymentState  = anyFunded ? .funded : .idle
                errorMessage = anyFunded ? nil
                    : "No ETH or STRK detected yet. Send either token and try again."
            }
        } catch {
            await MainActor.run {
                deploymentState = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    private func deployAccount(keys: StarknetAccount.AccountKeys) async {
        await MainActor.run {
            deploymentState = .deploying
            errorMessage = nil
        }
        let rpcUrl    = networkManager.activeNetwork.rpcUrl
        let pubKeyHex = keys.publicKey.hexString
        let rpc       = RPCClient()
        do {
            // Phase 14: estimate fee before computing the tx hash.
            // V3: estimate fee → resource bounds are committed inside the tx hash
            // V3: estimate fee returns resource bounds (STRK gas pricing)
            let resourceBounds = await rpc.estimateDeployFee(
                rpcUrl: rpcUrl,
                classHash: StarknetCurve.ozAccountClassHash,
                constructorCalldata: [pubKeyHex],
                salt: pubKeyHex,
                contractAddress: keys.address
            )
            // Compute V3 DEPLOY_ACCOUNT tx hash (Poseidon-based) + ECDSA signature
            let deployHash = try StarknetTransactionBuilder.deployAccountHash(
                contractAddress: keys.address,
                constructorCalldata: [pubKeyHex],
                classHash: StarknetCurve.ozAccountClassHash,
                salt: pubKeyHex,
                resourceBounds: resourceBounds,
                nonce: "0x0",
                chainID: networkManager.activeNetwork.chainIdFelt252
            )
            let deploySig = try StarkVeilProver.signTransaction(
                txHash: deployHash,
                privateKey: keys.privateKey.hexString
            )
            let txHash = try await rpc.deployAccount(
                rpcUrl: rpcUrl,
                classHash: StarknetCurve.ozAccountClassHash,
                constructorCalldata: [pubKeyHex],
                contractAddressSalt: pubKeyHex,
                resourceBounds: resourceBounds,
                signature: [deploySig.r, deploySig.s],
                nonce: "0x0"
            )
            await MainActor.run {
                deployTxHash = txHash
                deploymentState = .confirming
            }
            await pollForDeployment(rpcUrl: rpcUrl, txHash: txHash, address: keys.address)
        } catch {
            await MainActor.run {
                deploymentState = .error(error.localizedDescription)
            }
        }
    }

    // Phase 14: uses starknet_getTransactionReceipt for canonical confirmation.
    // Shows revert reason if the tx reverts, so users understand what went wrong.
    private func pollForDeployment(rpcUrl: URL, txHash: String, address: String) async {
        let result = await RPCClient().pollUntilAccepted(rpcUrl: rpcUrl, txHash: txHash)
        switch result {
        case .accepted:
            try? KeychainManager.markAccountDeployed()
            await MainActor.run { deploymentState = .deployed }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { onActivated() }
        case .reverted(let reason):
            await MainActor.run {
                deploymentState = .error("Transaction reverted: \(reason)")
            }
        case .rejected:
            await MainActor.run {
                deploymentState = .error("Rejected by sequencer. Check ETH balance and retry.")
            }
        case .timeout:
            let shortHash = String(txHash.prefix(12))
            await MainActor.run {
                deploymentState = .error("Tx \(shortHash)… pending — reopen app to recheck status.")
            }
        }
    }

    private func copyAddress(_ address: String) {
        UIPasteboard.general.string = address
        withAnimation { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { isCopied = false }
        }
    }
}
