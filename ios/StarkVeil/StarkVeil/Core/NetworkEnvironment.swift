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
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
