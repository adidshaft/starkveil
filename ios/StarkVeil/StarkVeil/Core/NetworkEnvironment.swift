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
    // SEPOLIA: deployed via sncast 0.50.0 + Katana 1.7.1 UDC invoke during hackathon session.
    //   Class hash:       0x44d6856773a46dac7832c861735856d3374632fab041e384b93518bb5ddc0e0
    //   Contract address: 0x74b2fe0e8674fb9f5ee5417e435492e88dd8dac2c68f67f328d8970883fa931
    //
    // MAINNET: not yet deployed — replace before mainnet launch.
    //   The previous placeholder (0x41a78e74…) was Katana's Universal Deployer Contract (UDC),
    //   not the PrivacyPool. Querying the UDC produces no Shielded events and breaks
    //   the per-network UTXO isolation invariant (both networks returned the same address).
    var contractAddress: String {
        switch self {
        case .mainnet:
            // TODO: replace with mainnet PrivacyPool address after production deployment
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        case .sepolia:
            return "0x20768453fb80c8958fdf9ceefa7f5af63db232fe2b8e9e36ead825301c4de74"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
