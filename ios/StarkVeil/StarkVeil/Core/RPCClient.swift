import Foundation

enum RPCClientError: Error, LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    case serverError(code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "RPC returned an unexpected response format."
        case .httpError(let code):
            return "HTTP error \(code) from RPC node."
        case .serverError(let code, let message):
            return "RPC error \(code): \(message)"
        }
    }
}

// MARK: - V3 Resource Bounds

/// Starknet V3 resource bounds for a single resource (L1_GAS or L2_GAS).
struct ResourceBound: Encodable {
    let max_amount: String    // hex: max gas units
    let max_price_per_unit: String  // hex: max STRK per gas unit (in fri = 1e-18 STRK)
}

/// Container for L1 gas, L2 gas, and L1 data gas bounds (Starknet RPC v0.8+).
struct ResourceBoundsMapping: Encodable {
    let l1_gas: ResourceBound
    let l2_gas: ResourceBound
    let l1_data_gas: ResourceBound
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
        request.timeoutInterval = 15   // explicit 15-second timeout

        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let bodyData = try encoder.encode(AnyEncodable(payload))
        request.httpBody = bodyData

        // ── DEBUG (commented out to reduce console noise — uncomment for RPC debugging) ──
        // if let bodyStr = String(data: bodyData, encoding: .utf8) {
        //     print("[RPC→] \(url.host ?? url.absoluteString)\n\(bodyStr)")
        // }
        // ─────────────────────────────────────────────────────────────────────

        let (data, response) = try await urlSession.data(for: request)

        // ── DEBUG (commented out to reduce console noise — uncomment for RPC debugging) ──
        // if let respStr = String(data: data, encoding: .utf8) {
        //     print("[RPC←] \(respStr)")
        // }
        // ─────────────────────────────────────────────────────────────────────

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCClientError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw RPCClientError.httpError(statusCode: httpResponse.statusCode)
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RPCResponse<T>.self, from: data)
    }

    /// Tries each URL in `urls` in order.
    /// Network errors and HTTP errors trigger the next fallback.
    /// Server errors (-32xxx) are NOT retried — a different node returns the same error.
    func performRequestWithFallback<T: Decodable>(urls: [URL], payload: Encodable) async throws -> RPCResponse<T> {
        let encoder = JSONEncoder()
        let body = try encoder.encode(AnyEncodable(payload))
        var lastError: Error = RPCClientError.invalidResponse
        for url in urls {
            do {
                var req = URLRequest(url: url)
                req.httpMethod       = "POST"
                req.httpBody         = body
                req.timeoutInterval  = 15   // L-2 fix: explicit timeout, matching performRequest
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                let (data, response) = try await urlSession.data(for: req)
                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    print("[RPC] HTTP \(http.statusCode) from \(url.host ?? url.absoluteString) — trying next")
                    lastError = RPCClientError.httpError(statusCode: http.statusCode)
                    continue
                }
                let decoded: RPCResponse<T> = try JSONDecoder().decode(RPCResponse<T>.self, from: data)
                return decoded
            } catch {
                print("[RPC] \(url.host ?? url.absoluteString) failed: \(error.localizedDescription) — trying next")
                lastError = error
            }
        }
        throw lastError
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

    func fetchLatestBlockNumber(rpcUrl: URL) async throws -> Int {
        let requestPayload = RPCRequest(method: "starknet_blockNumber", params: [] as [String])
        let response: RPCResponse<Int> = try await performRequest(url: rpcUrl, payload: requestPayload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let blockNumber = response.result else { throw RPCClientError.invalidResponse }
        return blockNumber
    }

    // MARK: - starknet_getClassHashAt

    func getClassHashAt(rpcUrl: URL, address: String) async throws -> String? {
        let requestPayload = RPCRequest(method: "starknet_getClassHashAt", params: ["latest", address])
        do {
            let response: RPCResponse<String> = try await performRequest(url: rpcUrl, payload: requestPayload)
            if let error = response.error {
                return nil
            }
            return response.result
        } catch {
            return nil
        }
    }

    /// Checks whether a given Starknet address has an on-chain contract deployed.
    /// Returns `true` (optimistic) on network failures to avoid booting users on bad connections.
    func isAddressDeployed(rpcUrl: URL, address: String) async -> Bool {
        let requestPayload = RPCRequest(method: "starknet_getClassHashAt", params: ["latest", address])
        do {
            let response: RPCResponse<String> = try await performRequest(url: rpcUrl, payload: requestPayload)
            if let e = response.error {
                // Code 20 = "Contract not found" — definitely not deployed
                if e.code == 20 { return false }
                // Any other server error — be optimistic (don't wipe valid wallets on bad RPC)
                return true
            }
            return response.result != nil
        } catch {
            // Network failure — optimistic: don't invalidate on poor connectivity
            return true
        }
    }

    // MARK: - starknet_getEvents

    func fetchEvents(
        rpcUrl: URL,
        fromBlock: Int,
        toBlock: Int,
        contractAddress: String
    ) async throws -> [EmittedEvent] {
        var allEvents: [EmittedEvent] = []
        var continuationToken: String? = nil
        repeat {
            // Build filter with optional continuation token
            struct EventFilterWithToken: Encodable {
                let from_block: BlockId
                let to_block: BlockId
                let address: String
                let keys: [[String]]
                let chunk_size: Int
                let continuation_token: String?
            }
            let filter = EventFilterWithToken(
                from_block: .number(fromBlock),
                to_block: .number(toBlock),
                address: contractAddress,
                keys: [],
                chunk_size: 100,
                continuation_token: continuationToken
            )
            struct Args: Encodable { let filter: EventFilterWithToken }
            let requestPayload = RPCRequest(method: "starknet_getEvents", params: Args(filter: filter))
            let response: RPCResponse<EventPageResponse> = try await performRequest(url: rpcUrl, payload: requestPayload)
            if let error = response.error {
                throw RPCClientError.serverError(code: error.code, message: error.message)
            }
            guard let page = response.result else { throw RPCClientError.invalidResponse }
            allEvents.append(contentsOf: page.events)
            continuationToken = page.continuation_token
        } while continuationToken != nil
        return allEvents
    }

    // MARK: - starknet_getNonce

    /// Returns the current on-chain nonce for the given account address.
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

    // MARK: - starknet_addInvokeTransaction  (V3)

    /// Struct matching the Starknet JSON-RPC `INVOKE_TXN_V3` spec.
    struct InvokeTransactionV3: Encodable {
        let type: String = "INVOKE"
        let sender_address: String
        let calldata: [String]
        let version: String = "0x3"
        let signature: [String]
        let nonce: String
        let resource_bounds: ResourceBoundsMapping
        let tip: String = "0x0"
        let paymaster_data: [String] = []
        let account_deployment_data: [String] = []
        let nonce_data_availability_mode: String = "L1"
        let fee_data_availability_mode: String = "L1"
    }

    /// Submits a signed V3 invoke transaction to the Starknet sequencer.
    @discardableResult
    func addInvokeTransaction(
        rpcUrl: URL,
        senderAddress: String,
        calldata: [String],
        resourceBounds: ResourceBoundsMapping,
        signature: [String],
        nonce: String
    ) async throws -> String {
        let tx = InvokeTransactionV3(
            sender_address: senderAddress,
            calldata: calldata,
            signature: signature,
            nonce: nonce,
            resource_bounds: resourceBounds
        )
        let payload = RPCRequest(method: "starknet_addInvokeTransaction",
                                 params: [tx])
        struct TxResult: Decodable { let transaction_hash: String }
        let response: RPCResponse<TxResult> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result.transaction_hash
    }

    // MARK: - starknet_addDeployAccountTransaction  (V3)

    /// Broadcasts an OZ v0.8 deploy account transaction using V3 format.
    /// The deployer must pre-fund the counterfactual address with STRK or ETH for gas.
    @discardableResult
    func deployAccount(
        rpcUrl: URL,
        classHash: String,
        constructorCalldata: [String],   // OZ v0.8: [publicKey]
        contractAddressSalt: String,     // = publicKey (OZ convention)
        resourceBounds: ResourceBoundsMapping,
        signature: [String] = ["0x0", "0x0"],
        nonce: String = "0x0"
    ) async throws -> String {
        struct DeployAccountTxV3: Encodable {
            let type: String = "DEPLOY_ACCOUNT"
            let version: String = "0x3"
            let signature: [String]
            let nonce: String
            let contract_address_salt: String
            let constructor_calldata: [String]
            let class_hash: String
            let resource_bounds: ResourceBoundsMapping
            let tip: String = "0x0"
            let paymaster_data: [String] = []
            let nonce_data_availability_mode: String = "L1"
            let fee_data_availability_mode: String = "L1"
        }
        let tx = DeployAccountTxV3(
            signature: signature,
            nonce: nonce,
            contract_address_salt: contractAddressSalt,
            constructor_calldata: constructorCalldata,
            class_hash: classHash,
            resource_bounds: resourceBounds
        )
        let payload = RPCRequest(method: "starknet_addDeployAccountTransaction",
                                 params: [tx])
        struct TxResult: Decodable { let transaction_hash: String }
        let response: RPCResponse<TxResult> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        guard let result = response.result else { throw RPCClientError.invalidResponse }
        return result.transaction_hash
    }

    // MARK: - starknet_estimateFee  (V3)

    /// Estimates the fee for an INVOKE_V3 transaction and returns ResourceBoundsMapping
    /// with a 1.5x safety multiplier.
    func estimateInvokeFee(
        rpcUrl: URL,
        senderAddress: String,
        calldata: [String],
        nonce: String,
        multiplier: Double = 1.5
    ) async throws -> ResourceBoundsMapping {
        let fallback = ResourceBoundsMapping(
            l1_gas: ResourceBound(max_amount: "0x30d40", max_price_per_unit: "0x174876e800"),  // ~200k L1 gas, ~100 Gwei
            l2_gas: ResourceBound(max_amount: "0x989680", max_price_per_unit: "0x174876e800"), // ~10M L2 gas, ~100 Gwei
            l1_data_gas: ResourceBound(max_amount: "0x2710", max_price_per_unit: "0x174876e800")
        )
        struct EstimateInvokeTx: Encodable {
            let type: String = "INVOKE"
            let sender_address: String
            let calldata: [String]
            let version: String = "0x3"
            let signature: [String] = []
            let nonce: String
            let resource_bounds: ResourceBoundsMapping
            let tip: String = "0x0"
            let paymaster_data: [String] = []
            let account_deployment_data: [String] = []
            let nonce_data_availability_mode: String = "L1"
            let fee_data_availability_mode: String = "L1"
        }
        struct Params: Encodable {
            let request: [EstimateInvokeTx]
            let block_id: String = "latest"
            let simulation_flags: [String] = ["SKIP_VALIDATE"]
        }
        let maxBounds = ResourceBoundsMapping(
            l1_gas: ResourceBound(max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff"),
            l2_gas: ResourceBound(max_amount: "0x0", max_price_per_unit: "0x0"),
            l1_data_gas: ResourceBound(max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff")
        )
        let tx = EstimateInvokeTx(
            sender_address: senderAddress,
            calldata: calldata,
            nonce: nonce,
            resource_bounds: maxBounds
        )
        let payload = RPCRequest(method: "starknet_estimateFee",
                                 params: Params(request: [tx]))
        do {
            let response: RPCResponse<[FeeEstimateV3]> = try await performRequest(url: rpcUrl, payload: payload)
            if let estimate = response.result?.first {
                return estimate.toResourceBounds(multiplier: multiplier)
            }
            if let err = response.error {
                 throw RPCClientError.serverError(code: err.code, message: err.message)
            }
        } catch {
            print("⚠️ [RPC] starknet_estimateFee failed: \(error.localizedDescription) — throwing error")
            throw error
        }
        return fallback
    }

    func estimateDeployFee(
        rpcUrl: URL,
        classHash: String,
        constructorCalldata: [String],
        salt: String,
        contractAddress: String,
        multiplier: Double = 1.5
    ) async throws -> ResourceBoundsMapping {
        let fallback = ResourceBoundsMapping(
            l1_gas: ResourceBound(max_amount: "0x30d40", max_price_per_unit: "0x174876e800"),  // ~200k L1 gas, ~100 Gwei
            l2_gas: ResourceBound(max_amount: "0x989680", max_price_per_unit: "0x174876e800"), // ~10M L2 gas, ~100 Gwei
            l1_data_gas: ResourceBound(max_amount: "0x2710", max_price_per_unit: "0x174876e800")
        )
        struct EstimateDeployTx: Encodable {
            let type: String = "DEPLOY_ACCOUNT"
            let version: String = "0x3"
            let signature: [String] = []
            let nonce: String = "0x0"
            let contract_address_salt: String
            let constructor_calldata: [String]
            let class_hash: String
            let resource_bounds: ResourceBoundsMapping
            let tip: String = "0x0"
            let paymaster_data: [String] = []
            let nonce_data_availability_mode: String = "L1"
            let fee_data_availability_mode: String = "L1"
        }
        struct Params: Encodable {
            let request: [EstimateDeployTx]
            let block_id: String = "latest"
            let simulation_flags: [String] = ["SKIP_VALIDATE"]
        }
        let maxBounds = ResourceBoundsMapping(
            l1_gas: ResourceBound(max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff"),
            l2_gas: ResourceBound(max_amount: "0x0", max_price_per_unit: "0x0"),
            l1_data_gas: ResourceBound(max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff")
        )
        let tx = EstimateDeployTx(
            contract_address_salt: salt,
            constructor_calldata: constructorCalldata,
            class_hash: classHash,
            resource_bounds: maxBounds
        )
        let payload = RPCRequest(method: "starknet_estimateFee",
                                 params: Params(request: [tx]))
        do {
            let response: RPCResponse<[FeeEstimateV3]> = try await performRequest(url: rpcUrl, payload: payload)
            if let estimate = response.result?.first {
                return estimate.toResourceBounds(multiplier: multiplier)
            }
            if let err = response.error {
                 throw RPCClientError.serverError(code: err.code, message: err.message)
            }
        } catch {
            print("⚠️ [RPC] starknet_estimateFee (deploy) failed: \(error.localizedDescription) — throwing error")
            throw error
        }
        return fallback
    }

    // MARK: - Fee Estimate V3 Parsing

    /// Starknet V3 fee estimate response.
    struct FeeEstimateV3: Decodable {
        // Actual field names returned by Starknet RPC v0.8
        let overall_fee: String
        let l1_gas_consumed: String?
        let l1_gas_price: String?
        let l2_gas_consumed: String?
        let l2_gas_price: String?
        let l1_data_gas_consumed: String?
        let l1_data_gas_price: String?
        let unit: String?   // "FRI" (STRK) or "WEI" (ETH)

        /// Converts per-resource-type estimate to ResourceBoundsMapping.
        /// Applies multiplier to each independently — L2 gas is the dominant
        /// execution cost on Starknet v0.13+ (Volition).
        func toResourceBounds(multiplier: Double = 1.5) -> ResourceBoundsMapping {
            func bounds(_ consumed: String?, _ price: String?, minGas: UInt64 = 100, minPrice: UInt64 = 1) -> ResourceBound {
                let gas   = parseHex(consumed ?? "0x0")
                let pri   = parseHex(price   ?? "0x0")
                let maxG  = max(UInt64(Double(gas) * multiplier), minGas)
                let maxP  = max(UInt64(Double(pri) * multiplier), minPrice)
                return ResourceBound(
                    max_amount: "0x\(String(maxG, radix: 16))",
                    max_price_per_unit: "0x\(String(maxP, radix: 16))"
                )
            }

            return ResourceBoundsMapping(
                l1_gas: bounds(l1_gas_consumed, l1_gas_price,
                               minGas: 100, minPrice: 1_000_000_000),
                l2_gas: bounds(l2_gas_consumed, l2_gas_price,
                               minGas: 10_000, minPrice: 1_000_000_000),
                l1_data_gas: bounds(l1_data_gas_consumed, l1_data_gas_price,
                                    minGas: 100, minPrice: 1_000)
            )
        }

        private func parseHex(_ hex: String) -> UInt64 {
            let s = hex.hasPrefix("0x") ? String(hex.dropFirst(2)) : hex
            if s.count > 16 { return UInt64(s.prefix(16), radix: 16) ?? 0 }
            return UInt64(s, radix: 16) ?? 0
        }
    }

    // MARK: - starknet_getTransactionReceipt

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

    /// Poll result
    enum TxPollResult {
        case accepted
        case reverted(String)
        case rejected
        case timeout
    }

    /// Polls `starknet_getTransactionReceipt` until the tx reaches a terminal state
    /// or the maximum number of retries is exhausted.
    func pollUntilAccepted(
        rpcUrl: URL,
        txHash: String,
        maxRetries: Int = 30,
        intervalSeconds: UInt64 = 4
    ) async -> TxPollResult {
        for _ in 0..<maxRetries {
            do {
                let receipt = try await getTransactionReceipt(rpcUrl: rpcUrl, txHash: txHash)
                if receipt.isAccepted { return .accepted }
                if receipt.isReverted { return .reverted(receipt.revert_reason ?? "Unknown revert") }
                if receipt.isRejected { return .rejected }
            } catch {
                // tx not yet known — keep polling
            }
            try? await Task.sleep(nanoseconds: intervalSeconds * 1_000_000_000)
        }
        return .timeout
    }

    // MARK: - Nullifier check

    /// Calls PrivacyPool.is_nullifier_spent(nullifier) → bool.
    func isNullifierSpent(
        rpcUrl: URL,
        contractAddress: String,
        nullifier: String
    ) async -> Bool {
        struct Params: Encodable {
            let request: CallReq
            let block_id: String = "latest"
            struct CallReq: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        // C-2 fix: correct sn_keccak("is_nullifier_spent") — verified via sha3_256
        let selector = "0x243759dd8b145b290cb0ebd7289fcba6c154362acb1c778339ec59a2be5527b"
        let payload = RPCRequest(method: "starknet_call",
                                 params: Params(request: Params.CallReq(
                                     contract_address: contractAddress,
                                     entry_point_selector: selector,
                                     calldata: [nullifier])))
        guard let response = try? await performRequest(url: rpcUrl, payload: payload) as RPCResponse<[String]>,
              let first = response.result?.first else { return false }
        return first == "0x1"
    }

    // MARK: - ETH balance

    func getETHBalance(rpcUrl: URL, address: String) async throws -> String {
        let ethContract = "0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7"
        let selector    = "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e"
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
                contract_address: ethContract,
                entry_point_selector: selector,
                calldata: [address]
            ))
        )
        let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        let parts = response.result ?? ["0x0", "0x0"]
        return parts.joined(separator: ", ")
    }

    // MARK: - STRK balance

    func getSTRKBalance(rpcUrl: URL, address: String) async throws -> String {
        let strkContract = "0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"
        let selector     = "0x2e4263afad30923c891518314c3c95dbe830a16874e8abc5777a9a20b54c76e"
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
                contract_address: strkContract,
                entry_point_selector: selector,
                calldata: [address]
            ))
        )
        let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        let parts = response.result ?? ["0x0", "0x0"]
        return parts.joined(separator: ", ")
    }
}

