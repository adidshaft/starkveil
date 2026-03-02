import Foundation

enum RPCClientError: Error {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(code: Int, message: String)
}

class RPCClient {
    private let urlSession: URLSession
    
    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }
    
    // MARK: - starknet_blockNumber
    
    /// Fetches the latest confirmed block height from Starknet
    func fetchLatestBlockNumber(rpcUrl: URL) async throws -> Int {
        let requestPayload = RPCRequest(method: "starknet_blockNumber", params: [] as [String])
        let response: RPCResponse<Int> = try await performRequest(url: rpcUrl, payload: requestPayload)
        
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else {
            throw RPCClientError.invalidResponse
        }
        return result
    }
    
    // MARK: - starknet_getEvents
    
    /// Fetches events emitted by the given contract between the block bounds.
    func fetchEvents(
        rpcUrl: URL,
        fromBlock: Int,
        toBlock: Int,
        contractAddress: String,
        keys: [[String]] = []
    ) async throws -> [EmittedEvent] {
        // Construct the `starknet_getEvents` argument array structure which expects:
        // { "filter": { "from_block": {"block_number": X}, "to_block": {"block_number": Y}, "address": "..", "keys": [[".."]] }, "chunk_size": 100 }
        
        // Define a custom param structure for the JSON-RPC
        struct GetEventsArgs: Encodable {
            let filter: EventFilter
            let chunk_size: Int
        }
        
        let filter = EventFilter(
            from_block: .number(fromBlock),
            to_block: .number(toBlock),
            address: contractAddress,
            keys: keys
        )
        
        var allEvents: [EmittedEvent] = []
        var continuationToken: String? = nil
        
        // Handle pagination using the continuation_token if necessary
        repeat {
            struct PagedArgs: Encodable {
                let filter: EventFilter
                let chunk_size: Int
                let continuation_token: String?
            }
            
            let args = PagedArgs(filter: filter, chunk_size: 100, continuation_token: continuationToken)
            let requestPayload = RPCRequest(method: "starknet_getEvents", params: args)
            
            let page: RPCResponse<EventPageResponse> = try await performRequest(url: rpcUrl, payload: requestPayload)
            
            if let error = page.error {
                throw RPCClientError.serverError(code: error.code, message: error.message)
            }
            guard let result = page.result else {
                break
            }
            
            allEvents.append(contentsOf: result.events)
            continuationToken = result.continuation_token
            
        } while continuationToken != nil
        
        return allEvents
    }
    
    // MARK: - HTTP Engine
    
    private func performRequest<T: Encodable, U: Decodable>(url: URL, payload: T) async throws -> U {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(payload)
        
        let (data, urlResponse) = try await urlSession.data(for: request)
        
        guard let httpRes = urlResponse as? HTTPURLResponse else {
            throw RPCClientError.invalidResponse
        }
        
        guard (200...299).contains(httpRes.statusCode) else {
            throw RPCClientError.httpError(statusCode: httpRes.statusCode)
        }
        
        let decoder = JSONDecoder()
        return try decoder.decode(U.self, from: data)
    }
}
