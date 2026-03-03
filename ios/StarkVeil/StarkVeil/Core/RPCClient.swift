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

    // MARK: - starknet_estimateFee  (Phase 14)

    /// Estimates the fee for an INVOKE_V1 transaction and returns a suggested maxFee
    /// with a configurable safety multiplier (default 1.5 × — gives headroom for mempool spikes).
    ///
    /// Falls back to the conservative hardcoded amount if the RPC call fails,
    /// so callers don't need to handle the error specially.
    func estimateInvokeFee(
        rpcUrl: URL,
        senderAddress: String,
        calldata: [String],
        nonce: String,
        fallback: String = "0x2386f26fc10000",   // 0.01 ETH — safe upper-bound
        multiplier: Double = 1.5
    ) async -> String {
        struct EstimateInvokeTx: Encodable {
            let type: String = "INVOKE"
            let sender_address: String
            let calldata: [String]
            let max_fee: String = "0xffffffffffffffffffffffffffffffff"  // sentinel — ignored by node
            let version: String = "0x1"
            let signature: [String] = []   // empty sig for estimation
            let nonce: String
        }
        struct Params: Encodable {
            let request: [EstimateInvokeTx]
            let block_id: String = "latest"
            let simulation_flags: [String] = ["SKIP_VALIDATE"]  // don't validate sig for estimate
        }
        struct FeeEstimate: Decodable {
            let overall_fee: String           // hex wei
            let gas_price: String?
        }
        let tx = EstimateInvokeTx(sender_address: senderAddress, calldata: calldata, nonce: nonce)
        let payload = RPCRequest(method: "starknet_estimateFee",
                                 params: Params(request: [tx]))
        guard let response = try? await performRequest(url: rpcUrl, payload: payload) as RPCResponse<[FeeEstimate]>,
              let estimate = response.result?.first,
              let feeValue = UInt64(estimate.overall_fee.dropFirst(2), radix: 16) else {
            return fallback
        }
        // Apply multiplier and cap at a sensible maximum (0.05 ETH)
        let suggested = Double(feeValue) * multiplier
        let capped = min(suggested, 2.8e16)   // 0.028 ETH
        return "0x\(String(UInt64(capped), radix: 16))"
    }

    /// Estimates the fee for a DEPLOY_ACCOUNT_V1 transaction.
    func estimateDeployFee(
        rpcUrl: URL,
        classHash: String,
        constructorCalldata: [String],
        salt: String,
        contractAddress: String,
        fallback: String = "0x2386f26fc10000",
        multiplier: Double = 1.5
    ) async -> String {
        struct EstimateDeployTx: Encodable {
            let type: String = "DEPLOY_ACCOUNT"
            let max_fee: String = "0xffffffffffffffffffffffffffffffff"
            let version: String = "0x1"
            let signature: [String] = []
            let nonce: String = "0x0"
            let contract_address_salt: String
            let constructor_calldata: [String]
            let class_hash: String
        }
        struct Params: Encodable {
            let request: [EstimateDeployTx]
            let block_id: String = "latest"
            let simulation_flags: [String] = ["SKIP_VALIDATE"]
        }
        struct FeeEstimate: Decodable { let overall_fee: String }
        let tx = EstimateDeployTx(contract_address_salt: salt,
                                  constructor_calldata: constructorCalldata,
                                  class_hash: classHash)
        let payload = RPCRequest(method: "starknet_estimateFee",
                                 params: Params(request: [tx]))
        guard let response = try? await performRequest(url: rpcUrl, payload: payload) as RPCResponse<[FeeEstimate]>,
              let estimate = response.result?.first,
              let feeValue = UInt64(estimate.overall_fee.dropFirst(2), radix: 16) else {
            return fallback
        }
        let suggested = Double(feeValue) * multiplier
        let capped = min(suggested, 2.8e16)
        return "0x\(String(UInt64(capped), radix: 16))"
    }

    // MARK: - starknet_getTransactionReceipt  (Phase 14)

    /// Execution and finality status of a submitted transaction.
    struct TransactionReceipt: Decodable {
        /// "SUCCEEDED" | "REVERTED"
        let execution_status: String?
        /// "ACCEPTED_ON_L2" | "ACCEPTED_ON_L1" | "RECEIVED" | "REJECTED"
        let finality_status: String?
        let transaction_hash: String?
        let revert_reason: String?

        var isAccepted: Bool {
            (finality_status == "ACCEPTED_ON_L2" || finality_status == "ACCEPTED_ON_L1")
            && execution_status == "SUCCEEDED"
        }
        var isReverted: Bool { execution_status == "REVERTED" }
        var isRejected: Bool { finality_status == "REJECTED" }
    }

    /// Fetches the receipt for a transaction hash.
    /// Throws RPCClientError.serverError if the node returns an error (e.g. tx not yet known).
    func getTransactionReceipt(rpcUrl: URL, txHash: String) async throws -> TransactionReceipt {
        struct Params: Encodable { let transaction_hash: String }
        let payload = RPCRequest(method: "starknet_getTransactionReceipt",
                                 params: Params(transaction_hash: txHash))
        let response: RPCResponse<TransactionReceipt> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result
    }

    // MARK: - Poll until accepted  (Phase 14)
    //
    // Replaces the isContractDeployed loop in AccountActivationView.
    // Uses starknet_getTransactionReceipt which is the canonical confirmation signal.

    enum TxFinalityResult {
        case accepted(TransactionReceipt)
        case reverted(reason: String)
        case rejected
        case timeout
    }

    /// Polls until the tx is accepted or reverted, with a configurable interval and timeout.
    func pollUntilAccepted(
        rpcUrl: URL,
        txHash: String,
        intervalSeconds: UInt64 = 3,
        maxAttempts: Int = 40    // 40 × 3s = 120s max wait
    ) async -> TxFinalityResult {
        for _ in 0..<maxAttempts {
            // Respect Task cancellation between polls
            if Task.isCancelled { return .timeout }
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
            if Task.isCancelled { return .timeout }

            guard let receipt = try? await getTransactionReceipt(rpcUrl: rpcUrl, txHash: txHash) else {
                // Node hasn't indexed it yet — keep polling
                continue
            }
            if receipt.isAccepted  { return .accepted(receipt) }
            if receipt.isReverted  { return .reverted(reason: receipt.revert_reason ?? "unknown") }
            if receipt.isRejected  { return .rejected }
            // Still RECEIVED — keep polling
        }
        return .timeout
    }

    // MARK: - is_nullifier_spent  (Phase 15 — double-spend prevention)

    /// Queries the PrivacyPool contract to check if a nullifier has already been spent.
    /// Returns false on any RPC error so we don't silently block legitimate spends;
    /// the contract's on-chain check is the authoritative guard.
    func isNullifierSpent(
        rpcUrl: URL,
        contractAddress: String,
        nullifierHex: String
    ) async -> Bool {
        // Keccak-250 of "is_nullifier_spent".
        // python3: hex(int(hashlib.sha3_256(b'is_nullifier_spent').hexdigest(),16) & ((1<<250)-1))
        let selector = "0x243759dd8b145b290cb0ebd7289fcba6c154362acb1c778339ec59a2be5527b"
        struct Params: Encodable {
            let request: CallReq
            let block_id: String = "latest"
            struct CallReq: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        let payload = RPCRequest(
            method: "starknet_call",
            params: Params(request: Params.CallReq(
                contract_address: contractAddress,
                entry_point_selector: selector,
                calldata: [nullifierHex]
            ))
        )
        guard let response = try? await performRequest(url: rpcUrl, payload: payload) as RPCResponse<[String]>,
              let first = response.result?.first else { return false }
        // Cairo bool: "0x1" = spent, "0x0" = unspent
        return first == "0x1"
    }
}

