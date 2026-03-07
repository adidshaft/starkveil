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
    //   Scarb/Cairo: 2.16.0, Sierra: 1.7.0 — includes Stwo STARK prover + Cairo verifier
    //   Class hash:       0x024559a23de684c4421ff64afd7edce6630b905c12d8a7f6431f9459e3fb76f9
    //   Contract address: 0x062cf904594a71239b0a72350289175b233bacf84e5649c656acabee69206b6f
    //   Declare tx:       0x05ba511955e82ebe8b04290421599769dbed9f2b716488ae4b3a376cc499ea8a
    //   Deploy tx:        0x02dae02bd25317a78f07f23d039b0c2fe03dd4e2ca5c377df77e833f795299ef
    //
    // MAINNET: not yet deployed — replace before mainnet launch.
    var contractAddress: String {
        switch self {
        case .mainnet:
            // TODO: replace with mainnet PrivacyPool address after production deployment
            return "0x0000000000000000000000000000000000000000000000000000000000000000"
        case .sepolia:
            return "0x062cf904594a71239b0a72350289175b233bacf84e5649c656acabee69206b6f"
        }
    }
}

class NetworkManager: ObservableObject {
    @Published var activeNetwork: NetworkEnvironment = .sepolia

    init(defaultNetwork: NetworkEnvironment = .sepolia) {
        self.activeNetwork = defaultNetwork
    }
}
