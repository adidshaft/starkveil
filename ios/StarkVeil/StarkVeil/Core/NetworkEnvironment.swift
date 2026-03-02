import Combine
import Foundation

enum NetworkEnvironment: String, CaseIterable, Identifiable {
    case mainnet = "Mainnet"
    case sepolia = "Sepolia Testnet"

    var id: String { self.rawValue }

    var rpcUrl: URL {
        switch self {
        case .mainnet:
            return URL(string: "https://free-rpc.nethermind.io/mainnet-juno")!
        case .sepolia:
            return URL(string: "https://free-rpc.nethermind.io/sepolia-juno")!
        }
    }

    var chainId: String {
        switch self {
        case .mainnet:
            return "SN_MAIN"
        case .sepolia:
            return "SN_SEPOLIA"
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
            return "0x74b2fe0e8674fb9f5ee5417e435492e88dd8dac2c68f67f328d8970883fa931"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
