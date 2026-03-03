pub mod types;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use types::{Note, TransferPayload, FFIResult};

// Phase 12: Real Starknet cryptography via starknet-crypto crate
use starknet_crypto::{
    get_public_key,
    pedersen_hash,
    poseidon_hash_many,
    sign,
    FieldElement,
};

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Helper: parse FieldElement from hex string
// ─────────────────────────────────────────────────────────────────────────────

fn felt_from_hex(hex: &str) -> Result<FieldElement, String> {
    let s = if hex.starts_with("0x") { &hex[2..] } else { hex };
    FieldElement::from_hex_be(s).map_err(|e| format!("Invalid felt252 hex '{}': {}", hex, e))
}

fn felt_to_hex(felt: &FieldElement) -> String {
    format!("0x{:x}", felt)
}

fn ffi_error(msg: &str) -> *mut c_char {
    let err = FFIResult::Error(msg.to_string());
    let json = serde_json::to_string(&err).unwrap_or_else(|_| "{\"Error\":\"Serialization\"}".to_string());
    CString::new(json).unwrap_or_else(|_| CString::new("{\"Error\":\"CString\"}").unwrap()).into_raw()
}

fn ffi_ok(payload: TransferPayload) -> *mut c_char {
    let result = FFIResult::Success(payload);
    match serde_json::to_string(&result) {
        Ok(json) => CString::new(json).unwrap_or_else(|_| CString::new("{\"Error\":\"CString\"}").unwrap()).into_raw(),
        Err(_) => CString::new("{\"Error\":\"Serialization failed\"}").unwrap().into_raw(),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 12 Function 1: STARK Public Key (real EC scalar multiply)
// ─────────────────────────────────────────────────────────────────────────────

/// Computes the STARK public key (x-coordinate of private_key * G) using
/// the starknet-crypto crate which implements the real STARK curve EC multiply.
///
/// Input:  C string containing the private key as a 0x-prefixed hex felt252.
/// Output: C string JSON: {"Ok": "0x..."} or {"Err": "message"}
///
/// Swift: StarkVeilProver.starkPublicKey(privateKeyHex: String) -> String
#[no_mangle]
pub unsafe extern "C" fn stark_get_public_key(
    private_key_hex: *const c_char,
) -> *mut c_char {
    if private_key_hex.is_null() { return ffi_error("null pointer"); }
    let c_str = CStr::from_ptr(private_key_hex);
    let hex = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return ffi_error("Invalid UTF-8"),
    };
    let sk = match felt_from_hex(hex) {
        Ok(f) => f,
        Err(e) => return ffi_error(&e),
    };
    let pubkey = get_public_key(&sk);
    let result = serde_json::json!({ "Ok": felt_to_hex(&pubkey) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap()).into_raw()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 12 Function 2: Pedersen Hash
// ─────────────────────────────────────────────────────────────────────────────

/// Computes the Cairo Pedersen hash H(a, b) using the real shift-point constants.
///
/// Input:  two 0x-prefixed hex felt252 strings, comma-separated: "0xa,0xb"
/// Output: C string JSON: {"Ok": "0x..."} or {"Err": "message"}
///
/// Swift: StarkVeilProver.pedersenHash(a: String, b: String) -> String
#[no_mangle]
pub unsafe extern "C" fn stark_pedersen_hash(
    a_hex: *const c_char,
    b_hex: *const c_char,
) -> *mut c_char {
    if a_hex.is_null() || b_hex.is_null() { return ffi_error("null pointer"); }
    let a_str = match CStr::from_ptr(a_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 a") };
    let b_str = match CStr::from_ptr(b_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 b") };
    let a = match felt_from_hex(a_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let b = match felt_from_hex(b_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let hash = pedersen_hash(&a, &b);
    let result = serde_json::json!({ "Ok": felt_to_hex(&hash) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap()).into_raw()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 12 Function 3: Poseidon Hash (note commitments)
// ─────────────────────────────────────────────────────────────────────────────

/// Computes Poseidon hash of a variable-length list of felt252 elements.
/// Matches the Cairo `poseidon_hash_span` used in the PrivacyPool contract.
///
/// Input:  JSON array of hex felt252 strings: ["0xa","0xb","0xc"]
/// Output: C string JSON: {"Ok": "0x..."} or {"Err": "message"}
///
/// Swift: StarkVeilProver.poseidonHash(elements: [String]) -> String
#[no_mangle]
pub unsafe extern "C" fn stark_poseidon_hash(
    elements_json: *const c_char,
) -> *mut c_char {
    if elements_json.is_null() { return ffi_error("null pointer"); }
    let json_str = match CStr::from_ptr(elements_json).to_str() {
        Ok(s) => s,
        Err(_) => return ffi_error("Invalid UTF-8"),
    };
    let hex_strs: Vec<String> = match serde_json::from_str(json_str) {
        Ok(v) => v,
        Err(e) => return ffi_error(&format!("JSON parse error: {}", e)),
    };
    let mut felts = Vec::with_capacity(hex_strs.len());
    for h in &hex_strs {
        match felt_from_hex(h) {
            Ok(f) => felts.push(f),
            Err(e) => return ffi_error(&e),
        }
    }
    let hash = poseidon_hash_many(&felts);
    let result = serde_json::json!({ "Ok": felt_to_hex(&hash) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap()).into_raw()
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 12 Function 4: STARK ECDSA Transaction Signing
// ─────────────────────────────────────────────────────────────────────────────

/// Signs a Starknet transaction hash with the account's spending key.
/// Returns the (r, s) ECDSA signature pair as felt252 hex strings.
///
/// Input:
///   - tx_hash_hex:   0x-prefixed transaction hash felt252
///   - private_key_hex: 0x-prefixed spending key felt252
///   - k_hex:          0x-prefixed random nonce k (or 0x1 for deterministic RFC6979-style)
///
/// Output: C string JSON: {"Ok": {"r": "0x...", "s": "0x..."}} or {"Err": "message"}
///
/// Swift: StarkVeilProver.signTransaction(txHash: String, privateKey: String) -> (r: String, s: String)
///
/// IMPORTANT: k must be a fresh random felt252 for each signature.
/// Using the same k twice breaks key security (ECDSA nonce reuse attack).
/// In production, k should be derived via RFC 6979 deterministic nonce generation.
#[no_mangle]
pub unsafe extern "C" fn stark_sign_transaction(
    tx_hash_hex: *const c_char,
    private_key_hex: *const c_char,
    k_hex: *const c_char,
) -> *mut c_char {
    if tx_hash_hex.is_null() || private_key_hex.is_null() || k_hex.is_null() {
        return ffi_error("null pointer");
    }
    let hash_str = match CStr::from_ptr(tx_hash_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 hash") };
    let pk_str   = match CStr::from_ptr(private_key_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 pk") };
    let k_str    = match CStr::from_ptr(k_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 k") };

    let msg_hash = match felt_from_hex(hash_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let pk       = match felt_from_hex(pk_str)   { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let k        = match felt_from_hex(k_str)    { Ok(f) => f, Err(e) => return ffi_error(&e) };

    match sign(&pk, &msg_hash, &k) {
        Ok(sig) => {
            let result = serde_json::json!({
                "Ok": {
                    "r": felt_to_hex(&sig.r),
                    "s": felt_to_hex(&sig.s)
                }
            }).to_string();
            CString::new(result).unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap()).into_raw()
        }
        Err(e) => ffi_error(&format!("ECDSA sign failed: {:?}", e)),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Proof Generation (existing, kept for transfer circuits)
// ─────────────────────────────────────────────────────────────────────────────

/// Mocks generating a Starknet Proof for a Private Transfer.
/// The mock proof data is replaced once the Cairo proving backend is integrated.
/// # Safety
/// Caller must ensure pointer is a valid null-terminated C string.
/// Caller is responsible for freeing the returned string via `free_rust_string`.
#[no_mangle]
pub unsafe extern "C" fn generate_transfer_proof(
    notes_json: *const c_char,
) -> *mut c_char {
    if notes_json.is_null() { return ffi_error("Received null pointer"); }

    let c_str = CStr::from_ptr(notes_json);
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return ffi_error("Invalid UTF-8 sequence"),
    };

    let _notes: Vec<Note> = match serde_json::from_str(str_slice) {
        Ok(n) => n,
        Err(e) => return ffi_error(&format!("Failed to parse notes: {}", e)),
    };

    let mock_payload = TransferPayload {
        proof: vec!["0x123...mock_proof".to_string(), "0x456...mock_proof".to_string()],
        nullifiers: vec!["0xabc...nullifier".to_string()],
        new_commitments: vec!["0xdef...commitment".to_string()],
        fee: "100000000000000".to_string(),
    };

    ffi_ok(mock_payload)
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Memory Management
// ─────────────────────────────────────────────────────────────────────────────

/// Frees a string allocated by Rust that crossed the FFI boundary.
/// # Safety
/// Pointer must have been returned by one of the Rust FFI functions above.
#[no_mangle]
pub unsafe extern "C" fn free_rust_string(s: *mut c_char) {
    if s.is_null() { return; }
    let _ = CString::from_raw(s);
}
