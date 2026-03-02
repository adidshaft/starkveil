import SwiftUI
import CryptoKit

// MARK: - Account Activation View  (Phase 11)
//
// Shown whenever the wallet has been set up (seed phrase stored) but the
// Starknet account contract has not yet been deployed.
//
// Flow:
//  1. App computes the counterfactual address and displays it with a QR code.
//  2. User sends ETH to that address from any source (exchange, friend, bridge).
//  3. App polls starknet_getClassAt to detect when the address is funded enough.
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
    @State private var deployTxHash: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isCopied = false

    enum DeploymentState {
        case idle            // Showing address, waiting for funding
        case checkingFunds   // Polling ETH balance
        case funded          // Balance > 0 detected
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
            Text("Your Starknet account address is ready.\nSend ETH to it for gas, then tap **Activate**.")
                .font(.system(size: 14))
                .foregroundStyle(themeManager.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Address Card

    private func addressCard(keys: StarknetAccount.AccountKeys) -> some View {
        VStack(spacing: 16) {
            // QR placeholder (shows address as monospaced text; replace with QRCodeView once SwiftQR is linked)
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(themeManager.surface1)
                    .frame(width: 200, height: 200)
                VStack(spacing: 6) {
                    Image(systemName: "qrcode")
                        .font(.system(size: 60))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.4))
                    Text("QR placeholder")
                        .font(.system(size: 10))
                        .foregroundStyle(themeManager.textSecondary.opacity(0.4))
                }
            }

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
                    infoRow(label: "Network", value: networkManager.activeNetwork.name)
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
                txHashBadge(hash: hash)
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
            stepRow(num: "1", text: "Send ETH to the address above for gas fees (~0.01 ETH is enough)")
            stepRow(num: "2", text: "Tap **Check Balance** once the transfer arrives")
            stepRow(num: "3", text: "Tap **Activate Wallet** — the app will deploy your account contract")
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
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text("ETH detected — ready to activate!")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(themeManager.textPrimary)
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
            // Derive or load cached account keys
            if let cached = KeychainManager.accountAddress(),
               let seed = KeychainManager.masterSeed() {
                let keys = StarknetAccount.deriveAccountKeys(fromSeed: seed)
                await MainActor.run { accountKeys = keys }
            } else if let seed = KeychainManager.masterSeed() {
                let keys = StarknetAccount.deriveAccountKeys(fromSeed: seed)
                // Cache address in Keychain for future launches
                try? KeychainManager.storeAccountAddress(keys.address)
                await MainActor.run { accountKeys = keys }
            }
        }
    }

    private func checkBalance(keys: StarknetAccount.AccountKeys) async {
        await MainActor.run { deploymentState = .checkingFunds }
        let rpcUrl = networkManager.activeNetwork.rpcUrl
        do {
            let balance = try await RPCClient().getETHBalance(rpcUrl: rpcUrl, address: keys.address)
            // M-BALANCE-PARSE fix: starknet_call returns [low_u128, high_u128] for a u256.
            // Parsing only the low word via UInt64 truncates balances > 18.44 ETH.
            // Any non-zero value in either word means the address is funded.
            let parts = balance.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            let low  = UInt64(parts.first?.replacingOccurrences(of: "0x", with: "") ?? "0", radix: 16) ?? 0
            let high = UInt64(parts.dropFirst().first?.replacingOccurrences(of: "0x", with: "") ?? "0", radix: 16) ?? 0
            let isFunded = low > 0 || high > 0
            await MainActor.run {
                ethBalance = balance
                deploymentState = isFunded ? .funded : .idle
                errorMessage = isFunded ? nil : "No ETH detected yet. Check your transfer and try again."
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
        let rpcUrl = networkManager.activeNetwork.rpcUrl
        let pubKeyHex = keys.publicKey.hexString
        do {
            let txHash = try await RPCClient().deployAccount(
                rpcUrl: rpcUrl,
                classHash: StarknetCurve.ozAccountClassHash,
                constructorCalldata: [pubKeyHex],   // OZ v0.8: constructor takes [publicKey]
                contractAddressSalt: pubKeyHex       // OZ convention: salt = publicKey
            )
            await MainActor.run {
                deployTxHash = txHash
                deploymentState = .confirming
            }
            // Poll for confirmation every 3 seconds for up to 60 seconds
            try await pollForDeployment(rpcUrl: rpcUrl, txHash: txHash, address: keys.address)
        } catch {
            await MainActor.run {
                deploymentState = .error(error.localizedDescription)
            }
        }
    }

    private func pollForDeployment(rpcUrl: URL, txHash: String, address: String) async throws {
        for _ in 0..<20 {
            // M-CANCEL-GAP fix: catch CancellationError separately.
            // If the Task is cancelled mid-poll (e.g. app backgrounded) but the contract is
            // already deployed on-chain, we must not lose that fact. Re-check once before throwing.
            do {
                try await Task.sleep(nanoseconds: 3_000_000_000)   // 3 seconds
            } catch is CancellationError {
                // Task was cancelled — do one final check then propagate cancellation
                let isDeployed = await RPCClient().isContractDeployed(rpcUrl: rpcUrl, address: address)
                if isDeployed {
                    try? KeychainManager.markAccountDeployed()
                    await MainActor.run { deploymentState = .deployed }
                }
                throw CancellationError()
            }
            let isDeployed = await RPCClient().isContractDeployed(rpcUrl: rpcUrl, address: address)
            if isDeployed {
                try? KeychainManager.markAccountDeployed()
                await MainActor.run { deploymentState = .deployed }
                try await Task.sleep(nanoseconds: 1_500_000_000)
                await MainActor.run { onActivated() }
                return
            }
        }
        // Timed out — tx may still confirm; user can reopen and recheck
        await MainActor.run {
            deploymentState = .error("Transaction submitted (\(txHash.prefix(12))…) but confirmation timed out. Reopen the app to recheck.")
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
