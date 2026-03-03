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
    
    private func performRequest<T: Decodable>(url: URL, payload: Encodable) async throws -> RPCResponse<T> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        // Encode the JSON-RPC payload
        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(AnyEncodable(payload))

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RPCClientError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RPCResponse<T>.self, from: data)
    }

    // A type-erased Encodable wrapper to allow passing generic Encodable payloads
    private struct AnyEncodable: Encodable {
        private let _encode: (Encoder) throws -> Void
        init(_ encodable: Encodable) {
            self._encode = encodable.encode
        }
        func encode(to encoder: Encoder) throws {
            try _encode(encoder)
        }
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
    
    // MARK: - starknet_getNonce  (Phase 13)

    /// Fetches the current nonce for a Starknet account.
    /// Must be called before every invoke or deploy transaction.
    func getNonce(rpcUrl: URL, address: String) async throws -> String {
        struct Params: Encodable {
            let block_id: String = "latest"
            let contract_address: String
        }
        let payload = RPCRequest(method: "starknet_getNonce",
                                 params: Params(contract_address: address))
        let response: RPCResponse<String> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result   // hex string e.g. "0x3"
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
    /// Phase 13: nonce and signature must be computed by the caller using
    /// StarknetTransactionBuilder.buildAndSign() before calling this.
    @discardableResult
    func addInvokeTransaction(
        rpcUrl: URL,
        senderAddress: String,
        calldata: [String],
        maxFee: String,
        signature: [String],
        nonce: String
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

    // MARK: - starknet_addDeployAccountTransaction  (Phase 11)

    /// Broadcasts an OZ v0.8 deploy account transaction.
    /// The deployer must pre-fund the counterfactual address with enough ETH for gas
    /// before calling this. Returns the transaction hash.
    @discardableResult
    func deployAccount(
        rpcUrl: URL,
        classHash: String,
        constructorCalldata: [String],   // OZ v0.8: [publicKey]
        contractAddressSalt: String,     // = publicKey (OZ convention)
        maxFee: String = "0x2386f26fc10000", // 0.01 ETH — sufficient for deploy on Sepolia
        signature: [String] = ["0x0", "0x0"],
        nonce: String = "0x0"
    ) async throws -> String {
        struct DeployAccountTx: Encodable {
            let type: String = "DEPLOY_ACCOUNT"
            let max_fee: String
            let version: String = "0x1"
            let signature: [String]
            let nonce: String
            let contract_address_salt: String
            let constructor_calldata: [String]
            let class_hash: String
        }
        struct Params: Encodable { let deploy_account_transaction: DeployAccountTx }
        let tx = DeployAccountTx(
            max_fee: maxFee,
            signature: signature,
            nonce: nonce,
            contract_address_salt: contractAddressSalt,
            constructor_calldata: constructorCalldata,
            class_hash: classHash
        )
        let payload = RPCRequest(method: "starknet_addDeployAccountTransaction",
                                 params: Params(deploy_account_transaction: tx))
        struct TxResult: Decodable { let transaction_hash: String }
        let response: RPCResponse<TxResult> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result.transaction_hash
    }

    // MARK: - starknet_getClassAt  (Phase 11 — checks deployment status)

    /// Returns true if a contract class is deployed at the given address.
    /// Used to determine if the user's account needs to be deployed.
    func isContractDeployed(rpcUrl: URL, address: String) async -> Bool {
        struct Params: Encodable {
            let block_id: String = "latest"
            let contract_address: String
        }
        let payload = RPCRequest(method: "starknet_getClassAt",
                                 params: Params(contract_address: address))
        // If the RPC returns any result (class hash), the account is deployed.
        // An error means the address has no contract yet.
        struct ClassResult: Decodable { let class_hash: String? }
        let response = try? await performRequest(url: rpcUrl, payload: payload) as RPCResponse<ClassResult>
        return response?.result != nil && response?.error == nil
    }

    // MARK: - starknet_call: getBalance  (Phase 11 — ETH balance for gas estimation)

    /// Queries the ETH balance of an address via the ETH ERC-20 contract.
    /// Returns the balance in wei as a hex string ("0x...").
    func getETHBalance(rpcUrl: URL, address: String) async throws -> String {
        let ethTokenAddress = "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7" // Starknet ETH ERC-20
        // LOW-SELECTORS fix: verified Keccak-250 selector for "balanceOf"
        // python3: hex(int(hashlib.sha3_256(b'balanceOf').hexdigest(),16) & ((1<<250)-1))
        // = 0x2b43118902ce404ad9f6882cdad03bb727383209c55d71a1f9fb5a580aabe82
        let balanceOfSelector = "0x2b43118902ce404ad9f6882cdad03bb727383209c55d71a1f9fb5a580aabe82"
        struct Params: Encodable {
            let request: CallRequest
            let block_id: String
            struct CallRequest: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        let payload = RPCRequest(
            method: "starknet_call",
            params: Params(
                request: Params.CallRequest(
                    contract_address: ethTokenAddress,
                    entry_point_selector: balanceOfSelector,
                    calldata: [address]
                ),
                block_id: "latest"
            )
        )
        // LOW-DEAD-STRUCT fix: CallResult was declared but never used — decode directly to [String].
        let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        return response.result?.first ?? "0x0"
    }
}
