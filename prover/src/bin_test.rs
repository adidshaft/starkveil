
use starkveil_prover::circuit::{compute_commitment, verify_merkle_path};
use starkveil_prover::types::{TransferInput, Note};
use starknet_crypto::FieldElement;

fn main() {
    // We are just verifying that the prover DOES NOT panic with "invalid type: map" 
    // and successfully spits out a proof structure.
    
    let input_json = r#"{
        "input_notes": [{
            "value": "0x16345785d8a0000",
            "asset_id": "0x5354524b",
            "owner_ivk": "0x123",
            "owner_pubkey": "0x123",
            "nonce": "0x123",
            "spending_key": "0x123",
            "memo": "",
            "leaf_position": 0,
            "merkle_path": ["0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0", "0x0"],
            "commitment": "0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f"
        }],
        "output_notes": [{
            "value": "0xb1a2bc2ec500000",
            "asset_id": "0x5354524b",
            "owner_ivk": "0x456",
            "owner_pubkey": "0x456",
            "nonce": "0x456",
            "spending_key": null,
            "memo": "",
            "leaf_position": null,
            "merkle_path": null,
            "commitment": "0x20351717b08dd97de89d6e4b8df21b6c00ed646cb0b7e28a9b2d87e076dfbd6"
        }]
    }"#;

    let input: TransferInput = serde_json::from_str(input_json).unwrap();
    println!("SUCCESS! Struct cleanly parsed from JSON.");
    println!("Input notes count: {}", input.input_notes.len());
    println!("Output notes count: {}", input.output_notes.len());
    
    // Test the C-FFI entrypoint
    let c_string = std::ffi::CString::new(input_json).unwrap();
    let ptr = c_string.as_ptr();
    
    unsafe {
        let res_ptr = starkveil_prover::stark_generate_transfer_proof(ptr);
        let res_c_str = std::ffi::CStr::from_ptr(res_ptr);
        let res_str = res_c_str.to_str().unwrap();
        // println!("Proof Generation Result: {}", res_str); // Commented out to reduce noise, we just care if it successfully generates
        let is_ok = res_str.contains("Success");
        println!("FFI Call Success: {}", is_ok);
    }
}
