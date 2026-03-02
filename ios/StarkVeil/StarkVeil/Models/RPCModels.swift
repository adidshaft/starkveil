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
    // Empty params for starknet_blockNumber — encodes as [] rather than {}
    func encode(to encoder: Encoder) throws {
        _ = encoder.unkeyedContainer()
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
        // IMPORTANT: an Encoder allows only ONE top-level container per encode(to:) call.
        // Acquiring singleValueContainer() unconditionally and then calling
        // encoder.container(keyedBy:) for the .number case triggers
        // preconditionFailure("Attempt to encode value through multiple containers")
        // inside Foundation's JSONEncoder — crashing silently inside the catch block.
        // Each case must acquire its own container independently.
        switch self {
        case .latest:
            var container = encoder.singleValueContainer()
            try container.encode("latest")
        case .pending:
            var container = encoder.singleValueContainer()
            try container.encode("pending")
        case .number(let n):
            // Starknet RPC expects {"block_number": N} for numeric block identifiers
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(n, forKey: .block_number)
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
