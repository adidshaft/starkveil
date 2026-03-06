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
    // SEPOLIA: redeployed 2026-03-06 via sncast 0.57.0 on Starknet Sepolia 0.14.1
    //   Scarb/Cairo: 2.16.0, Sierra: 1.7.0
    //   Class hash:       0x6f55e881019ffa68fdffed5fa0bc2ebb9cb1b8366ba44ab63dd5985f8cc7dec
    //   Contract address: 0x02d69236620a877ce24413b34dd45115bc72fd4cca8e3445546a9ce3d5be0abc
    //   Declare tx:       0x63c4a6cf2d616e6c92ad2b156366e11a4584f1e585ccbbc33a6ac5863b61da4
    //   Deploy tx:        0x0664a8f22e7d347c3b4db927dfade3cba8b8ad3441707e8e477f43d0f0e19144
    //
    // MAINNET: not yet deployed — replace before mainnet launch.
    var contractAddress: String {
        switch self {
        case .mainnet:
            // TODO: replace with mainnet PrivacyPool address after production deployment
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        case .sepolia:
            return "0x0212fd86010bc6da7d1284e7725ab1aac61a144be4daccb346f08f878ea184d3"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
