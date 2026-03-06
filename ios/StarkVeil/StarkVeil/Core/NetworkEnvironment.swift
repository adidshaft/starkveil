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
    // SEPOLIA: deployed 2026-03-06 via sncast 0.57.0 on Starknet Sepolia 0.14.1
    //   Scarb/Cairo: 2.16.0, Sierra: 1.7.0
    //   Class hash:       0x2d83a57fa7d4acf29be38e9b05920f12ca4672fc457c38f70978c58de1f8861
    //   Contract address: 0x03e5309aae68ecafb93e82e70a4fa5d8c96a38f072a1e5de66370519aeb1c54c
    //   Declare tx:       0x43147d727c8b501cf89ba50736a169a770237c3c412aa66636ffb89d1b3b5c4
    //   Deploy tx:        0x057435b7d6321f948b36f18fe8beb3892a463bc1fdebc6341f7809ada1e577c1
    //
    // MAINNET: not yet deployed — replace before mainnet launch.
    var contractAddress: String {
        switch self {
        case .mainnet:
            // TODO: replace with mainnet PrivacyPool address after production deployment
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        case .sepolia:
            return "0x03e5309aae68ecafb93e82e70a4fa5d8c96a38f072a1e5de66370519aeb1c54c"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
