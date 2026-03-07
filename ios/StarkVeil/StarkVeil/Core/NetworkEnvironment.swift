import Combine
import Foundation

enum NetworkEnvironment: String, CaseIterable, Identifiable {
    case mainnet = "Mainnet"
    case sepolia = "Sepolia Testnet"

    var id: String { self.rawValue }

    /// Primary RPC URL — used for all requests.
    var rpcUrl: URL {
        rpcUrls[0]
    }

    /// Ordered list of public RPC endpoints — tried in order if the primary fails.
    /// All are keyless public nodes so no API credentials are stored in the binary.
    var rpcUrls: [URL] {
        switch self {
        case .mainnet:
            return [
                URL(string: "https://rpc.starknet.lava.build")!,           // Primary (Lava)
                URL(string: "https://starknet-mainnet.public.blastapi.io")!, // Fallback 1
                URL(string: "https://free-rpc.nethermind.io/mainnet-juno")!  // Fallback 2
            ]
        case .sepolia:
            return [
                URL(string: "https://api.cartridge.gg/x/starknet/sepolia")!, // Primary (Cartridge, v0.9.0)
                URL(string: "https://rpc.starknet-testnet.lava.build")!      // Fallback (Lava, v0.8.1)
            ]
        }
    }

    var chainId: String {
        switch self {
        case .mainnet: return "SN_MAIN"
        case .sepolia: return "SN_SEPOLIA"
        }
    }

    /// M-CHAIN-ID-HARDCODED fix: felt252-encoded chain ID for tx hash computation.
    /// Callers pass this to StarknetTransactionBuilder instead of the hardcoded sepolia constant.
    var chainIdFelt252: String {
        switch self {
        case .mainnet: return StarknetTransactionBuilder.ChainID.mainnet   // 0x534e5f4d41494e
        case .sepolia: return StarknetTransactionBuilder.ChainID.sepolia  // 0x534e5f5345504f4c4941
        }
    }
    
    // The deployed PrivacyPool Cairo contract address for each environment.
    //
    // SEPOLIA: redeployed 2026-03-07 via sncast 0.57.0 on Starknet Sepolia 0.14.1
    //   Scarb/Cairo: 2.16.0, Sierra: 1.7.0 — includes fixed Stwo verifier transcript parsing
    //   Class hash:       0x0316cf3ac017db1524ea7a1195ebd60e48c058439b8c5804fd2e1017dc021de1
    //   Contract address: 0x019f2e14dfc8133b17c532e8990fb65efd5a596482b209b89c8b5bb6947ff91c
    //   Declare tx:       0x04f83d518d1543c6028dd69a1fe785b277ba26d56a485526555a43ee587e3832
    //   Deploy tx:        0x0044335207b29a66e2ec7c77559dcb48270c2a9d0ce222cc1d7c03d55b5f2bc3
    //
    // MAINNET: not yet deployed — replace before mainnet launch.
    var contractAddress: String {
        switch self {
        case .mainnet:
            // TODO: replace with mainnet PrivacyPool address after production deployment
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        case .sepolia:
            return "0x019f2e14dfc8133b17c532e8990fb65efd5a596482b209b89c8b5bb6947ff91c"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
