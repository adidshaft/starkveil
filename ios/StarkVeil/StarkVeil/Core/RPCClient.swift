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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bodyData = try encoder.encode(AnyEncodable(payload))
        request.httpBody = bodyData

        let reqDict = (try? JSONSerialization.jsonObject(with: bodyData, options: [])) as? [String: Any]
        let reqMethod = reqDict?["method"] as? String ?? "Unknown RPC Method"

        print("\n\n==========================================================")
        print("↗️ [RPC REQUEST] \(reqMethod)")
        print("URL: \(url.absoluteString)")
        if let bodyStr = String(data: bodyData, encoding: .utf8) {
            print("PAYLOAD:\n\(bodyStr)")
        }
        print("==========================================================")

        let (data, response) = try await urlSession.data(for: request)

        print("\n==========================================================")
        print("↙️ [RPC RESPONSE] \(reqMethod)")
        print("URL: \(url.absoluteString)")
        if let httpResponse = response as? HTTPURLResponse {
            let icon = (200...299).contains(httpResponse.statusCode) ? "✅" : "❌"
            print("STATUS CODE: \(httpResponse.statusCode) \(icon)")
        }

        if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
           let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
           let prettyStr = String(data: prettyData, encoding: .utf8) {
            print("BODY:\n\(prettyStr)")
        } else if let respStr = String(data: data, encoding: .utf8) {
            print("BODY (Raw):\n\(respStr)")
        }
        print("==========================================================\n\n")

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
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let body = try encoder.encode(AnyEncodable(payload))
        
        let reqDict = (try? JSONSerialization.jsonObject(with: body, options: [])) as? [String: Any]
        let reqMethod = reqDict?["method"] as? String ?? "Unknown RPC Method"
        
        var lastError: Error = RPCClientError.invalidResponse
        for url in urls {
            do {
                var req = URLRequest(url: url)
                req.httpMethod       = "POST"
                req.httpBody         = body
                req.timeoutInterval  = 15   // L-2 fix: explicit timeout, matching performRequest
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.setValue("application/json", forHTTPHeaderField: "Accept")
                
                print("\n\n==========================================================")
                print("↗️ [RPC REQUEST (Fallback)] \(reqMethod)")
                print("URL: \(url.absoluteString)")
                if let bodyStr = String(data: body, encoding: .utf8) {
                    print("PAYLOAD:\n\(bodyStr)")
                }
                print("==========================================================")

                let (data, response) = try await urlSession.data(for: req)
                
                print("\n==========================================================")
                print("↙️ [RPC RESPONSE (Fallback)] \(reqMethod)")
                print("URL: \(url.absoluteString)")
                if let http = response as? HTTPURLResponse {
                    let icon = (200...299).contains(http.statusCode) ? "✅" : "❌"
                    print("STATUS CODE: \(http.statusCode) \(icon)")
                }
                
                if let jsonObject = try? JSONSerialization.jsonObject(with: data, options: []),
                   let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
                   let prettyStr = String(data: prettyData, encoding: .utf8) {
                    print("BODY:\n\(prettyStr)")
                } else if let respStr = String(data: data, encoding: .utf8) {
                    print("BODY (Raw):\n\(respStr)")
                }
                print("==========================================================\n\n")

                guard let http = response as? HTTPURLResponse else { continue }
                guard (200..<300).contains(http.statusCode) else {
                    print("⚠️ [RPC Error] HTTP \(http.statusCode) from \(url.host ?? url.absoluteString) — trying next")
                    lastError = RPCClientError.httpError(statusCode: http.statusCode)
                    continue
                }
                let decoded: RPCResponse<T> = try JSONDecoder().decode(RPCResponse<T>.self, from: data)
                return decoded
            } catch {
                print("⚠️ [RPC Error] \(url.host ?? url.absoluteString) failed: \(error.localizedDescription) — trying next")
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
        let payload = RPCRequest(
            method: "starknet_getNonce",
            params: Params(contract_address: address)
        )
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
        // Starknet RPC v0.9.0 OpenRPC spec defines a single NAMED param "invoke_transaction".
        // Sending [tx] (positional array) works on some nodes but fails on others.
        struct AddInvokeTxParams: Encodable { let invoke_transaction: InvokeTransactionV3 }
        let payload = RPCRequest(method: "starknet_addInvokeTransaction",
                                 params: AddInvokeTxParams(invoke_transaction: tx))
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
        struct AddDeployTxParams: Encodable { let deploy_account_transaction: DeployAccountTxV3 }
        let payload = RPCRequest(method: "starknet_addDeployAccountTransaction",
                                 params: AddDeployTxParams(deploy_account_transaction: tx))
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
            l2_gas: ResourceBound(max_amount: "0xffffffffffff", max_price_per_unit: "0xffffffffffff"),
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

    /// Checks if a nullifier is spent by directly reading the contract's storage map.
    func isNullifierSpent(
        rpcUrl: URL,
        contractAddress: String,
        nullifier: String
    ) async -> Bool {
        // Keep using direct storage reads here so nullifier checks remain ABI-independent
        // across old and newly deployed pool contracts.
        // Storage address = Poseidon(sn_keccak("nullifiers"), nullifier)
        // Storage address = Poseidon(sn_keccak("nullifiers"), nullifier)
        // sn_keccak("nullifiers") = "0x011eb1cfd6dc2270dd714e86a9f4fb7dcb1701385311eab1be1d38260a927c32"
        let mapSelector = "0x011eb1cfd6dc2270dd714e86a9f4fb7dcb1701385311eab1be1d38260a927c32"
        
        guard let storageAddress = try? StarkVeilProver.poseidonHash(elements: [mapSelector, nullifier]),
              let value = try? await fetchStorageAt(rpcUrl: rpcUrl, contractAddress: contractAddress, storageKey: storageAddress) else {
            return false
        }
        
        return value != "0x0" && value != "0"
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

    // MARK: - Merkle tree (view functions + storage fallback)

    /// Reads the current Merkle root from the contract.
    /// Tries the `get_mt_root()` view function first (available in contracts compiled with
    /// Cairo 2.16 + view functions). Falls back to `starknet_getStorageAt` for older
    /// deployments where the entrypoint doesn't exist (RPC error 21).
    func fetchMerkleRoot(rpcUrl: URL, contractAddress: String) async throws -> String {
        // Primary: call view function
        struct CallParams: Encodable {
            let request: CallReq
            let block_id: String = "latest"
            struct CallReq: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        let selector = "0x00074addea198acfff933b6d6b4a4ba165265c7d7261d654c5e32ed6e53e4437"
        let callPayload = RPCRequest(method: "starknet_call",
                                     params: CallParams(request: CallParams.CallReq(
                                         contract_address: contractAddress,
                                         entry_point_selector: selector,
                                         calldata: [])))
        let callResp: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: callPayload)
        if let result = callResp.result?.first, callResp.error == nil {
            return result
        }
        // Fallback: read mt_root directly from storage slot sn_keccak("mt_root")
        // Storage slot: keccak256("mt_root") & ((1<<250)-1)
        return try await fetchStorageAt(rpcUrl: rpcUrl,
                                        contractAddress: contractAddress,
                                        storageKey: "0x03e2609850a479983c566ae20fc029bc61956f6950343015ef33ea32dd2d935d")
    }

    /// Reads mt_next_index. Tries view function, falls back to storage slot.
    func fetchMerkleNextIndex(rpcUrl: URL, contractAddress: String) async throws -> Int {
        struct CallParams: Encodable {
            let request: CallReq
            let block_id: String = "latest"
            struct CallReq: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        let selector = "0x03dbad2e340264907e47b2cbbcc75d5a93b48640ed9d6082f3a29a2fd650e56d"
        let callPayload = RPCRequest(method: "starknet_call",
                                     params: CallParams(request: CallParams.CallReq(
                                         contract_address: contractAddress,
                                         entry_point_selector: selector,
                                         calldata: [])))
        let callResp: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: callPayload)
        if let hexStr = callResp.result?.first, callResp.error == nil {
            let clean = hexStr.hasPrefix("0x") ? String(hexStr.dropFirst(2)) : hexStr
            if let value = Int(clean, radix: 16) { return value }
        }
        // Fallback: storage slot sn_keccak("mt_next_index")
        let raw = try await fetchStorageAt(rpcUrl: rpcUrl,
                                           contractAddress: contractAddress,
                                           storageKey: "0x00a25379c1f6617ffc4b2314ba856f3dfc9ef61c99ff48d938c4e8a89aad6b7a")
        let clean = raw.hasPrefix("0x") ? String(raw.dropFirst(2)) : raw
        return Int(clean, radix: 16) ?? 0
    }

    /// Reconstructs the 20-level Merkle authentication path for a leaf.
    /// On contracts without get_mt_node, returns an empty array (prover uses zero hashes).
    func fetchMerkleWitness(
        rpcUrl: URL,
        contractAddress: String,
        leafIndex: Int
    ) async throws -> [String] {
        struct CallParams: Encodable {
            let request: CallReq
            let block_id: String = "latest"
            struct CallReq: Encodable {
                let contract_address: String
                let entry_point_selector: String
                let calldata: [String]
            }
        }
        let selector = "0x00f240b02d924525746aea6e87814fae41da607a0e7d674b69cd564b3ee85d7c"
        var path: [String] = []
        var idx = leafIndex
        for level in 0..<20 {
            let siblingIdx = idx ^ 1
            let payload = RPCRequest(method: "starknet_call",
                                     params: CallParams(request: CallParams.CallReq(
                                         contract_address: contractAddress,
                                         entry_point_selector: selector,
                                         calldata: [String(format: "0x%x", level),
                                                    String(format: "0x%x", siblingIdx)])))
            let response: RPCResponse<[String]> = try await performRequest(url: rpcUrl, payload: payload)
            if let error = response.error {
                // get_mt_node not available on this contract (old class).
                // Return only the levels we already fetched. The Rust prover's
                // parse_merkle_path fills missing levels with pre-computed ZERO_HASHES_20
                // constants, which ARE the correct empty-sibling values. Padding with "0x0"
                // here would override those constants with plain zeros, producing a wrong root.
                print("[RPCClient] fetchMerkleWitness: entrypoint missing at level \(level), returning \(path.count) collected levels")
                return path
            }
            guard let node = response.result?.first else { throw RPCClientError.invalidResponse }
            path.append(node)
            idx >>= 1
        }
        return path
    }

    /// Scans all Shielded AND Transfer events to find the Merkle leaf index for a commitment.
    /// Shielded events carry an explicit leaf_index in data[4] (ground truth).
    /// Transfer events carry new_commitments in data[1..N]; their leaf indices are derived
    /// by maintaining a running insertion counter anchored to Shielded event leaf_indices.
    func fetchLeafPositionByCommitment(
        rpcUrl: URL,
        contractAddress: String,
        commitment: String
    ) async throws -> Int? {
        let latestBlock = (try? await fetchLatestBlockNumber(rpcUrl: rpcUrl)) ?? 0
        guard latestBlock > 0 else { return nil }
        let shieldedSelector = "0x3905e8c1752e2e2f768e4ed493f6d4df0bcaaf86ad37ef5bc7c2bbf18fe8083"
        let transferSelector  = "0x99cd8bde557814842a3121e8ddfd433a539b8c9f14bf31ebf108d12e6196e9"
        let events = try await fetchEvents(rpcUrl: rpcUrl, fromBlock: 0, toBlock: latestBlock,
                                           contractAddress: contractAddress)
        let normalised = commitment.lowercased()
        // Running leaf count — anchored to Shielded events' leaf_index (ground truth),
        // incremented by Transfer events' commitment count.
        var runningCount = 0
        for event in events {
            guard let selector = event.keys.first else { continue }
            if selector == shieldedSelector, event.data.count >= 5 {
                let leafHex = event.data[4]
                let leafStr = leafHex.hasPrefix("0x") ? String(leafHex.dropFirst(2)) : leafHex
                if let idx = Int(leafStr, radix: 16) {
                    runningCount = idx + 1   // anchor running count to ground truth
                    if event.data[3].lowercased() == normalised { return idx }
                }
            } else if selector == transferSelector, event.data.count >= 1 {
                // data[0] = commitments_len; data[1..N] = commitments
                let countHex = event.data[0]
                let countStr = countHex.hasPrefix("0x") ? String(countHex.dropFirst(2)) : countHex
                let count = Int(countStr, radix: 16) ?? 0
                guard count > 0, event.data.count >= 1 + count else { continue }
                for i in 0..<count {
                    if event.data[1 + i].lowercased() == normalised { return runningCount + i }
                }
                runningCount += count
            }
        }
        return nil
    }

    /// Raw `starknet_getStorageAt` call — used as fallback when view functions are unavailable.
    private func fetchStorageAt(rpcUrl: URL, contractAddress: String, storageKey: String) async throws -> String {
        struct Params: Encodable {
            let contract_address: String
            let key: String
            let block_id: String
        }
        let payload = RPCRequest(method: "starknet_getStorageAt",
                                 params: Params(contract_address: contractAddress,
                                                key: storageKey,
                                                block_id: "latest"))
        let response: RPCResponse<String> = try await performRequest(url: rpcUrl, payload: payload)
        if let error = response.error {
            throw RPCClientError.serverError(code: error.code, message: error.message)
        }
        return response.result ?? "0x0"
    }
}
