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
    
    // MARK: - starknet_addInvokeTransaction

    /// Struct matching the Starknet JSON-RPC `INVOKE_TXN_V1` spec.
    struct InvokeTransaction: Encodable {
        let type: String = "INVOKE"
        let sender_address: String
        let calldata: [String]
        let max_fee: String
        let version: String = "0x1"
        let signature: [String]
        let nonce: String
    }

    /// Submits a signed invoke transaction to the Starknet sequencer.
    /// Returns the transaction hash on success.
    @discardableResult
    func addInvokeTransaction(
        rpcUrl: URL,
        senderAddress: String,
        calldata: [String],
        maxFee: String = "0x0",
        signature: [String] = [],
        nonce: String = "0x0"
    ) async throws -> String {
        struct Params: Encodable {
            let invoke_transaction: InvokeTransaction
        }
        let tx = InvokeTransaction(
            sender_address: senderAddress,
            calldata: calldata,
            max_fee: maxFee,
            signature: signature,
            nonce: nonce
        )
        let payload = RPCRequest(method: "starknet_addInvokeTransaction", params: Params(invoke_transaction: tx))
        struct TxResult: Decodable { let transaction_hash: String }
        let response: RPCResponse<TxResult> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result.transaction_hash
    }
}
