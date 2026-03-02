import Foundation

// MARK: - Generic JSON-RPC Wrapper
struct RPCRequest<T: Encodable>: Encodable {
    let jsonrpc = "2.0"
    let id = 1
    let method: String
    let params: T
}

struct RPCResponse<T: Decodable>: Decodable {
    let jsonrpc: String
    let id: Int
    let result: T?
    let error: RPCError?
}

struct RPCError: Decodable {
    let code: Int
    let message: String
}

// MARK: - starknet_blockNumber

struct BlockNumberParams: Encodable {
    // Empty params for starknet_blockNumber
    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        // Ensure params encode as an empty array [] rather than {}
    }
}

// MARK: - starknet_getEvents

struct GetEventsParams: Encodable {
    let filter: EventFilter
}

struct EventFilter: Encodable {
    let from_block: BlockId
    let to_block: BlockId
    let address: String
    let keys: [[String]] // Match specific event hashes (like Shielded or Transfer)
}

enum BlockId: Encodable {
    case latest
    case pending
    case number(Int)
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .latest:
            try container.encode("latest")
        case .pending:
            try container.encode("pending")
        case .number(let n):
            // Starknet RPC expects block_number wrapping integer
            var nested = encoder.container(keyedBy: CodingKeys.self)
            try nested.encode(n, forKey: .block_number)
        }
    }
    
    enum CodingKeys: String, CodingKey {
        case block_number
    }
}

struct EventPageResponse: Decodable {
    let events: [EmittedEvent]
    let continuation_token: String?
}

struct EmittedEvent: Decodable {
    let from_address: String
    let keys: [String] // The event selector hash
    let data: [String] // The payload fields
    let block_number: Int
    let transaction_hash: String
}
