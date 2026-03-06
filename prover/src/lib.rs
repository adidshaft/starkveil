pub mod types;
pub mod circuit;

use std::ffi::{CStr, CString};
use std::os::raw::c_char;

use types::{Note, TransferPayload, FFIResult, UnshieldInput, UnshieldPayload, UnshieldFFIResult};
use circuit::{NoteWitness, OutputNote, parse_merkle_path};

// Phase 12: Real Starknet cryptography via starknet-crypto crate
// Phase 18: RFC-6979 deterministic ECDSA nonce (H-2 audit fix)
use rfc6979::HmacDrbg;
use sha2::Sha256;
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
    let s = if hex.starts_with("0x") || hex.starts_with("0X") {
        &hex[2..]
    } else {
        hex
    };
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

fn ffi_ok_unshield(payload: UnshieldPayload) -> *mut c_char {
    let result = UnshieldFFIResult::Success(payload);
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
/// Phase 18 (H-2 fix): k is derived deterministically via RFC-6979 inside Rust.
/// The caller CANNOT supply k — this eliminates the ECDSA nonce-reuse vulnerability.
///
/// Input:
///   - tx_hash_hex:    0x-prefixed transaction hash felt252
///   - private_key_hex: 0x-prefixed spending key felt252
///
/// Output: C string JSON: {"Ok": {"r": "0x...", "s": "0x..."}} or {"Err": "message"}
///
/// Swift: StarkVeilProver.signTransaction(txHash: String, privateKey: String) -> (r: String, s: String)
#[no_mangle]
pub unsafe extern "C" fn stark_sign_transaction(
    tx_hash_hex: *const c_char,
    private_key_hex: *const c_char,
) -> *mut c_char {
    if tx_hash_hex.is_null() || private_key_hex.is_null() {
        return ffi_error("null pointer");
    }
    let hash_str = match CStr::from_ptr(tx_hash_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 hash") };
    let pk_str   = match CStr::from_ptr(private_key_hex).to_str() { Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8 pk") };

    let msg_hash = match felt_from_hex(hash_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let pk       = match felt_from_hex(pk_str)   { Ok(f) => f, Err(e) => return ffi_error(&e) };

    // STARK EC group order N (NOT the field prime P).
    // N = 0x0800000000000010FFFFFFFFFFFFFFFFB781126DCAE7B2321E66A241ADC64D2F
    // N < P, so N is a valid FieldElement — but we compare raw bytes to avoid any issues.
    let stark_order_bytes: [u8; 32] = [
        0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10,
        0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
        0xB7, 0x81, 0x12, 0x6D, 0xCA, 0xE7, 0xB2, 0x32,
        0x1E, 0x66, 0xA2, 0x41, 0xAD, 0xC6, 0x4D, 0x2F,
    ];

    // RFC-6979 deterministic k derivation with retry loop.
    // If the derived k is out of range or sign() rejects it, we re-derive
    // with an incremented counter byte fed into HMAC-DRBG additional_data.
    let pk_bytes = pk.to_bytes_be();
    let msg_bytes = msg_hash.to_bytes_be();

    for attempt in 0u16..256 {
        // Feed counter into additional_data so each attempt produces a different k
        // M-3 fix: use 2-byte LE representation to avoid u16→u8 truncation
        // (attempt=256 would wrap to 0, colliding with attempt=0)
        let extra = attempt.to_le_bytes();
        let mut drbg = HmacDrbg::<Sha256>::new(&pk_bytes, &msg_bytes, &extra);
        let mut k_bytes = [0u8; 32];
        drbg.fill_bytes(&mut k_bytes);

        // Clamp top 5 bits → value < 2^251 (well within both N and P)
        k_bytes[0] &= 0x07;

        // Skip k = 0 (degenerate)
        if k_bytes.iter().all(|b| *b == 0) {
            continue;
        }

        // Reject k >= N (STARK EC order) via raw byte comparison
        if k_bytes >= stark_order_bytes {
            continue;
        }

        // Parse as FieldElement — safe since k < N < P
        let k = match FieldElement::from_bytes_be(&k_bytes) {
            Ok(f) => f,
            Err(_) => continue,
        };

        match sign(&pk, &msg_hash, &k) {
            Ok(sig) => {
                let result = serde_json::json!({
                    "Ok": {
                        "r": felt_to_hex(&sig.r),
                        "s": felt_to_hex(&sig.s)
                    }
                }).to_string();
                return CString::new(result)
                    .unwrap_or_else(|_| CString::new("{\"Err\":\"CString\"}").unwrap())
                    .into_raw();
            }
            Err(_) => continue,  // InvalidK from sign(), try next k
        }
    }

    ffi_error("ECDSA sign failed: could not derive valid k after 256 attempts")
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 15: Real Commitment + Nullifier Derivation
// ─────────────────────────────────────────────────────────────────────────────

/// Computes a note commitment: Poseidon(value, asset_id, owner_pubkey, nonce)
/// This matches the Cairo PrivacyPool contract's commitment scheme.
/// All inputs are 0x-prefixed hex felt252 strings.
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"}
#[no_mangle]
pub unsafe extern "C" fn stark_note_commitment(
    value_hex: *const c_char,
    asset_id_hex: *const c_char,
    owner_pubkey_hex: *const c_char,
    nonce_hex: *const c_char,
) -> *mut c_char {
    if value_hex.is_null() || asset_id_hex.is_null() || owner_pubkey_hex.is_null() || nonce_hex.is_null() {
        return ffi_error("null pointer");
    }
    macro_rules! parse_felt {
        ($ptr:expr, $name:expr) => {
            match CStr::from_ptr($ptr).to_str() {
                Ok(s) => match felt_from_hex(s) { Ok(f) => f, Err(e) => return ffi_error(&e) },
                Err(_) => return ffi_error(concat!("Invalid UTF-8: ", $name)),
            }
        };
    }
    let value        = parse_felt!(value_hex,       "value");
    let asset_id     = parse_felt!(asset_id_hex,    "asset_id");
    let owner_pubkey = parse_felt!(owner_pubkey_hex,"owner_pubkey");
    let nonce        = parse_felt!(nonce_hex,        "nonce");

    // Commitment = Poseidon(value ‖ asset_id ‖ owner_pubkey ‖ nonce)
    let commitment = poseidon_hash_many(&[value, asset_id, owner_pubkey, nonce]);
    let result = serde_json::json!({ "Ok": felt_to_hex(&commitment) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Error\":\"CString\"}").unwrap()).into_raw()
}

/// Computes a note nullifier: Poseidon(commitment, spending_key)
/// Spending the note reveals this value on-chain (preventing double-spend).
/// Inputs: commitment (0x-prefixed hex), spending_key (0x-prefixed hex).
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"}
#[no_mangle]
pub unsafe extern "C" fn stark_note_nullifier(
    commitment_hex: *const c_char,
    spending_key_hex: *const c_char,
) -> *mut c_char {
    if commitment_hex.is_null() || spending_key_hex.is_null() {
        return ffi_error("null pointer");
    }
    let commitment   = match CStr::from_ptr(commitment_hex).to_str() {
        Ok(s) => match felt_from_hex(s) { Ok(f) => f, Err(e) => return ffi_error(&e) },
        Err(_) => return ffi_error("Invalid UTF-8: commitment"),
    };
    let spending_key = match CStr::from_ptr(spending_key_hex).to_str() {
        Ok(s) => match felt_from_hex(s) { Ok(f) => f, Err(e) => return ffi_error(&e) },
        Err(_) => return ffi_error("Invalid UTF-8: spending_key"),
    };
    // Nullifier = Poseidon(commitment ‖ spending_key)
    let nullifier = poseidon_hash_many(&[commitment, spending_key]);
    let result = serde_json::json!({ "Ok": felt_to_hex(&nullifier) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Error\":\"CString\"}").unwrap()).into_raw()
}

/// Derives an Incoming Viewing Key (IVK) from the spending key.
/// IVK = Poseidon(spending_key, domain_separator)
/// where domain_separator = felt252("StarkVeil IVK v1") = ASCII bytes as felt.
/// The IVK allows detecting incoming notes without spending them.
/// It is safe to share with watch-only nodes.
#[no_mangle]
pub unsafe extern "C" fn stark_derive_ivk(
    spending_key_hex: *const c_char,
) -> *mut c_char {
    if spending_key_hex.is_null() { return ffi_error("null pointer"); }
    let sk_str = match CStr::from_ptr(spending_key_hex).to_str() {
        Ok(s) => s, Err(_) => return ffi_error("Invalid UTF-8"),
    };
    let sk = match felt_from_hex(sk_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    // C-DOMAIN-SPACE fix: correct ASCII hex for "StarkVeil IVK v1" with no spaces and correct byte order.
    // S=53 t=74 a=61 r=72 k=6b V=56 e=65 i=69 l=6c SP=20 I=49 V=56 K=4b SP=20 v=76 1=31
    let domain = FieldElement::from_hex_be("0x537461726b5665696c2049564b207631")
        .expect("hardcoded IVK domain constant is always valid hex");
    let ivk = poseidon_hash_many(&[sk, domain]);
    let result = serde_json::json!({ "Ok": felt_to_hex(&ivk) }).to_string();
    CString::new(result).unwrap_or_else(|_| CString::new("{\"Error\":\"CString\"}").unwrap()).into_raw()
}

/// Phase 20: Generates a real Stwo STARK transfer proof with cryptographic verification.
///
/// The proof constrains:
///   - Merkle membership: each input note exists in the tree at its claimed position
///   - Balance conservation: Σ(input values) = Σ(output values) + fee
///   - Nullifier correctness: each nullifier = Poseidon(commitment, spending_key)
///   - Commitment wellformedness: Poseidon(value, asset_id, owner_pubkey, nonce)
///
/// Required fields per input note: value, asset_id, owner_pubkey, nonce,
///   spending_key, leaf_position, merkle_path (20 sibling hashes).
///
/// The output note is derived deterministically from the first input note.
/// In a full implementation, the caller would supply explicit output notes.
///
/// Input JSON: [{value, asset_id, owner_pubkey, nonce, spending_key, leaf_position, merkle_path}]
/// Output: FFIResult::Success(TransferPayload) or FFIResult::Error
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

    let notes: Vec<Note> = match serde_json::from_str(str_slice) {
        Ok(n) => n,
        Err(e) => return ffi_error(&format!("Failed to parse notes: {}", e)),
    };

    if notes.is_empty() {
        return ffi_error("At least one input note is required");
    }

    // ── Parse input notes into NoteWitness structs ───────────────────────────
    let mut input_witnesses: Vec<NoteWitness> = Vec::new();
    for (i, note) in notes.iter().enumerate() {
        let value_str = match note.value.as_deref() {
            Some(s) => s,
            None => return ffi_error(&format!("Input note {} missing required field: value", i)),
        };
        let asset_str = match note.asset_id.as_deref() {
            Some(s) => s,
            None => return ffi_error(&format!("Input note {} missing required field: asset_id", i)),
        };
        let owner_str = match note.owner_pubkey.as_deref() {
            Some(s) => s,
            None => return ffi_error(&format!("Input note {} missing required field: owner_pubkey", i)),
        };
        let nonce_str = match note.nonce.as_deref() {
            Some(s) => s,
            None => return ffi_error(&format!("Input note {} missing required field: nonce", i)),
        };
        let sk_str = match note.spending_key.as_deref() {
            Some(s) => s,
            None => return ffi_error(&format!("Input note {} missing required field: spending_key", i)),
        };
        let leaf_pos = match note.leaf_position {
            Some(p) => p,
            None => return ffi_error(&format!("Input note {} missing required field: leaf_position", i)),
        };
        let path_hex = match note.merkle_path.as_ref() {
            Some(p) => p,
            None => return ffi_error(&format!("Input note {} missing required field: merkle_path", i)),
        };

        let value = match felt_from_hex(value_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
        let asset = match felt_from_hex(asset_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
        let owner = match felt_from_hex(owner_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
        let nonce = match felt_from_hex(nonce_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
        let sk    = match felt_from_hex(sk_str)    { Ok(f) => f, Err(e) => return ffi_error(&e) };

        let merkle_path = match parse_merkle_path(path_hex) {
            Ok(p) => p,
            Err(e) => return ffi_error(&format!("Input note {} merkle_path error: {}", i, e)),
        };

        input_witnesses.push(NoteWitness {
            value, asset_id: asset, owner_pubkey: owner, nonce,
            spending_key: sk, leaf_position: leaf_pos, merkle_path,
        });
    }

    // ── Derive historic root from the first note's Merkle path ──────────────
    let first_commitment = circuit::compute_commitment(
        &input_witnesses[0].value,
        &input_witnesses[0].asset_id,
        &input_witnesses[0].owner_pubkey,
        &input_witnesses[0].nonce,
    );
    let historic_root = circuit::verify_merkle_path(
        &first_commitment,
        input_witnesses[0].leaf_position,
        &input_witnesses[0].merkle_path,
    );

    // ── Build output note (change note) ─────────────────────────────────────
    // Deterministic output commitment from the first note's parameters.
    // In a full implementation, the caller would supply explicit output notes.
    let first = &notes[0];
    let out_value = match felt_from_hex(first.value.as_deref().unwrap_or("0x0")) {
        Ok(f) => f, Err(e) => return ffi_error(&e),
    };
    let out_asset = match felt_from_hex(first.asset_id.as_deref().unwrap_or("0x0")) {
        Ok(f) => f, Err(e) => return ffi_error(&e),
    };
    let out_owner = match felt_from_hex(first.owner_pubkey.as_deref().unwrap_or("0x0")) {
        Ok(f) => f, Err(e) => return ffi_error(&e),
    };
    let out_nonce = poseidon_hash_many(&[out_value, out_asset, out_owner]);

    let fee = FieldElement::from(100000000000000u64); // 0.0001 STRK

    // Compute actual output value: total_input - fee
    let mut total_input = FieldElement::ZERO;
    for w in &input_witnesses {
        total_input = total_input + w.value;
    }
    let output_value = total_input - fee;

    let output_note = OutputNote {
        value: output_value,
        asset_id: out_asset,
        owner_pubkey: out_owner,
        nonce: out_nonce,
    };

    // ── Generate the real STARK proof ────────────────────────────────────────
    let proof_result = circuit::generate_transfer_stark_proof(
        &input_witnesses,
        &[output_note],
        &fee,
        &historic_root,
    );

    match proof_result {
        Ok((proof, public_inputs)) => {
            let nullifiers: Vec<String> = public_inputs.nullifiers.iter()
                .map(|n| felt_to_hex(n))
                .collect();
            let new_commitments: Vec<String> = public_inputs.new_commitments.iter()
                .map(|c| felt_to_hex(c))
                .collect();

            let payload = TransferPayload {
                proof: proof.proof_elements,
                nullifiers,
                new_commitments,
                fee: "100000000000000".to_string(),
                historic_root: felt_to_hex(&public_inputs.historic_root),
            };

            ffi_ok(payload)
        }
        Err(e) => ffi_error(&format!("Proof generation failed: {}", e)),
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Phase 20: Unshield Proof Generation
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a real Stwo STARK proof for an unshield operation.
///
/// The proof constrains:
///   - Merkle membership: the input note exists in the tree
///   - Ownership: spending_key → owner_pubkey
///   - Nullifier derivation: Poseidon(commitment, spending_key)
///   - Public input binding: (amount, asset, recipient) are committed
///
/// Input JSON: {note: {...}, amount_low, amount_high, recipient, asset, historic_root}
/// Output: UnshieldFFIResult::Success(UnshieldPayload) or ::Error
#[no_mangle]
pub unsafe extern "C" fn generate_unshield_proof(
    input_json: *const c_char,
) -> *mut c_char {
    if input_json.is_null() { return ffi_error("Received null pointer"); }

    let c_str = CStr::from_ptr(input_json);
    let str_slice = match c_str.to_str() {
        Ok(s) => s,
        Err(_) => return ffi_error("Invalid UTF-8 sequence"),
    };

    let input: UnshieldInput = match serde_json::from_str(str_slice) {
        Ok(i) => i,
        Err(e) => return ffi_error(&format!("Failed to parse unshield input: {}", e)),
    };

    // Parse required fields
    let note = &input.note;
    let value_str = match note.value.as_deref() {
        Some(s) => s, None => return ffi_error("Missing required field: value"),
    };
    let asset_str = match note.asset_id.as_deref() {
        Some(s) => s, None => return ffi_error("Missing required field: asset_id"),
    };
    let owner_str = match note.owner_pubkey.as_deref() {
        Some(s) => s, None => return ffi_error("Missing required field: owner_pubkey"),
    };
    let nonce_str = match note.nonce.as_deref() {
        Some(s) => s, None => return ffi_error("Missing required field: nonce"),
    };
    let sk_str = match note.spending_key.as_deref() {
        Some(s) => s, None => return ffi_error("Missing required field: spending_key"),
    };
    let leaf_pos = match note.leaf_position {
        Some(p) => p, None => return ffi_error("Missing required field: leaf_position"),
    };
    let path_hex = match note.merkle_path.as_ref() {
        Some(p) => p, None => return ffi_error("Missing required field: merkle_path"),
    };

    let value = match felt_from_hex(value_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let asset = match felt_from_hex(asset_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let owner = match felt_from_hex(owner_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let nonce = match felt_from_hex(nonce_str) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let sk    = match felt_from_hex(sk_str)    { Ok(f) => f, Err(e) => return ffi_error(&e) };

    let amount_low  = match felt_from_hex(&input.amount_low)  { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let amount_high = match felt_from_hex(&input.amount_high) { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let recipient   = match felt_from_hex(&input.recipient)   { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let asset_addr  = match felt_from_hex(&input.asset)       { Ok(f) => f, Err(e) => return ffi_error(&e) };
    let root        = match felt_from_hex(&input.historic_root) { Ok(f) => f, Err(e) => return ffi_error(&e) };

    let merkle_path = match parse_merkle_path(path_hex) {
        Ok(p) => p,
        Err(e) => return ffi_error(&format!("merkle_path error: {}", e)),
    };

    let witness = NoteWitness {
        value, asset_id: asset, owner_pubkey: owner, nonce,
        spending_key: sk, leaf_position: leaf_pos, merkle_path,
    };

    let proof_result = circuit::generate_unshield_stark_proof(
        &witness, &amount_low, &amount_high, &recipient, &asset_addr, &root,
    );

    match proof_result {
        Ok((proof, nullifier)) => {
            let payload = UnshieldPayload {
                proof: proof.proof_elements,
                nullifier: felt_to_hex(&nullifier),
                historic_root: felt_to_hex(&root),
            };
            ffi_ok_unshield(payload)
        }
        Err(e) => ffi_error(&format!("Unshield proof generation failed: {}", e)),
    }
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
