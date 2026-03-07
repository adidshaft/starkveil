/// StarkVeil Privacy Pool STARK Circuit — Phase 20: Stwo Integration
///
/// This module implements a self-contained STARK proof generator for the StarkVeil
/// privacy pool operations (private transfer and unshield). It uses:
///
/// - `starknet-crypto::poseidon_hash_many` for Poseidon constraint evaluation
/// - `stwo::core::fields` for M31/QM31 field arithmetic (Circle STARK compatible)
/// - `starknet-crypto::FieldElement` for felt252 operations
///
/// The circuit constrains:
/// 1. **Merkle membership** — each input note's commitment exists in the tree
/// 2. **Balance conservation** — Σ(input values) = Σ(output values) + fee
/// 3. **Nullifier correctness** — each nullifier = Poseidon(commitment, spending_key)
/// 4. **Commitment wellformedness** — each commitment = Poseidon(value, asset, owner, nonce)
///
/// The proof is serialized as `Vec<String>` (hex felt252) for the Cairo verifier.

use starknet_crypto::{poseidon_hash_many, FieldElement};

use crate::{felt_from_hex, felt_to_hex};
use crate::types::ZERO_HASHES_20;

/// Errors during proof generation
#[derive(Debug)]
pub enum CircuitError {
    /// A required field is missing from the input note
    MissingField(String),
    /// Merkle path verification failed
    InvalidMerklePath { leaf_index: u32, expected_root: String, computed_root: String },
    /// Balance equation does not hold
    BalanceViolation { total_in: String, total_out: String },
    /// The operation mixes mismatched assets.
    AssetMismatch { expected: String, found: String },
    /// Unshield amount does not match the spent note.
    AmountMismatch { expected: String, found: String },
    /// Unshield amount.high must currently be zero because note values are encoded as felt252.
    UnsupportedAmountHigh { found: String },
    /// Field element parsing error
    ParseError(String),
}

impl std::fmt::Display for CircuitError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            CircuitError::MissingField(field) => write!(f, "Missing required field: {}", field),
            CircuitError::InvalidMerklePath { leaf_index, expected_root, computed_root } =>
                write!(f, "Merkle path invalid at leaf {}: expected root {}, computed {}",
                       leaf_index, expected_root, computed_root),
            CircuitError::BalanceViolation { total_in, total_out } =>
                write!(f, "Balance violation: inputs={} != outputs={}", total_in, total_out),
            CircuitError::AssetMismatch { expected, found } =>
                write!(f, "Asset mismatch: expected {}, found {}", expected, found),
            CircuitError::AmountMismatch { expected, found } =>
                write!(f, "Amount mismatch: expected {}, found {}", expected, found),
            CircuitError::UnsupportedAmountHigh { found } =>
                write!(f, "Unsupported non-zero amount.high: {}", found),
            CircuitError::ParseError(msg) => write!(f, "Parse error: {}", msg),
        }
    }
}

/// Witness for a single input note (private data that goes into the circuit)
pub struct NoteWitness {
    pub value: FieldElement,
    pub asset_id: FieldElement,
    pub owner_pubkey: FieldElement,
    pub nonce: FieldElement,
    pub spending_key: FieldElement,
    pub leaf_position: u32,
    pub merkle_path: [FieldElement; 20],
    /// Pre-validated Merkle leaf commitment. When present, it must match
    /// Poseidon(value, asset_id, owner_pubkey, nonce).
    pub commitment: Option<FieldElement>,
}

/// Witness for a single output note
pub struct OutputNote {
    pub value: FieldElement,
    pub asset_id: FieldElement,
    pub owner_pubkey: FieldElement,
    pub nonce: FieldElement,
}

/// Public inputs for the transfer circuit
pub struct TransferPublicInputs {
    pub historic_root: FieldElement,
    pub nullifiers: Vec<FieldElement>,
    pub new_commitments: Vec<FieldElement>,
    pub fee: FieldElement,
}

/// A STARK proof for the privacy pool circuit.
/// The proof consists of:
/// 1. Commitment to constraint evaluation (Poseidon hash of all constraint outputs)
/// 2. FRI query responses (commitment openings at random points)
/// 3. Decommitment paths
///
/// For the Integrity FactRegistry, the "fact" is:
///   fact_hash = Poseidon(proof_commitment, public_inputs_hash)
pub struct StarkVeilProof {
    /// The proof elements serialized as felt252 hex strings
    pub proof_elements: Vec<String>,
    /// Hash of the proof commitment — used for on-chain fact verification
    pub proof_commitment: FieldElement,
}

/// Verify that a note commitment lies in the Merkle tree at the given position.
/// Returns the computed root.
pub fn verify_merkle_path(
    commitment: &FieldElement,
    leaf_position: u32,
    merkle_path: &[FieldElement; 20],
) -> FieldElement {
    let mut current_hash = *commitment;
    let mut index = leaf_position;

    for level in 0..20u32 {
        let sibling = merkle_path[level as usize];
        let is_right = (index % 2) == 1;

        let (left, right) = if is_right {
            (sibling, current_hash)
        } else {
            (current_hash, sibling)
        };

        current_hash = poseidon_hash_many(&[left, right]);
        index /= 2;
    }

    current_hash
}

/// Compute a note commitment: Poseidon(value, asset_id, owner_pubkey, nonce)
pub fn compute_commitment(
    value: &FieldElement,
    asset_id: &FieldElement,
    owner_pubkey: &FieldElement,
    nonce: &FieldElement,
) -> FieldElement {
    poseidon_hash_many(&[*value, *asset_id, *owner_pubkey, *nonce])
}

/// Compute a nullifier: Poseidon(commitment, spending_key)
pub fn compute_nullifier(
    commitment: &FieldElement,
    spending_key: &FieldElement,
) -> FieldElement {
    poseidon_hash_many(&[*commitment, *spending_key])
}

/// Generate a STARK proof for a private transfer.
///
/// This function:
/// 1. Validates all circuit constraints locally (Merkle membership, balance, nullifiers)
/// 2. Generates the execution trace for the Circle STARK AIR
/// 3. Commits to the trace via Poseidon Merkle tree
/// 4. Runs the FRI proximity proof protocol
/// 5. Serializes the proof as felt252 array for the Cairo verifier
///
/// The proof constrains:
///   - Commitment wellformedness: Poseidon(value, asset_id, owner_pubkey, nonce) = commitment
///   - Merkle membership: commitment exists in the depth-20 Poseidon Merkle tree
///   - Nullifier derivation: Poseidon(commitment, spending_key) = nullifier
///   - Ownership: owner_pubkey derives from spending_key
///   - Balance conservation: Σ(input_values) = Σ(output_values) + fee
pub fn generate_transfer_stark_proof(
    input_notes: &[NoteWitness],
    output_notes: &[OutputNote],
    fee: &FieldElement,
    historic_root: &FieldElement,
) -> Result<(StarkVeilProof, TransferPublicInputs), CircuitError> {
    // ── Step 1: Validate all constraints ──────────────────────────────────────
    let expected_asset = input_notes[0].asset_id;

    let mut nullifiers = Vec::new();
    let mut new_commitments = Vec::new();
    let mut total_input_value = FieldElement::ZERO;

    // Validate input notes
    for (i, note) in input_notes.iter().enumerate() {
        if note.asset_id != expected_asset {
            return Err(CircuitError::AssetMismatch {
                expected: felt_to_hex(&expected_asset),
                found: felt_to_hex(&note.asset_id),
            });
        }

        let commitment = note.commitment.unwrap_or_else(|| compute_commitment(
            &note.value, &note.asset_id, &note.owner_pubkey, &note.nonce,
        ));

        // Verify Merkle membership
        let computed_root = verify_merkle_path(
            &commitment,
            note.leaf_position,
            &note.merkle_path,
        );
        if computed_root != *historic_root {
            return Err(CircuitError::InvalidMerklePath {
                leaf_index: note.leaf_position,
                expected_root: felt_to_hex(historic_root),
                computed_root: felt_to_hex(&computed_root),
            });
        }

        // Verify owner_pubkey matches spending_key
        let expected_pubkey = starknet_crypto::get_public_key(&note.spending_key);
        if expected_pubkey != note.owner_pubkey {
            return Err(CircuitError::MissingField(
                format!("Input note {} owner_pubkey does not match spending_key", i),
            ));
        }

        // Compute nullifier
        let nullifier = compute_nullifier(&commitment, &note.spending_key);
        nullifiers.push(nullifier);

        total_input_value = total_input_value + note.value;
    }

    // Validate output notes
    let mut total_output_value = FieldElement::ZERO;
    for note in output_notes {
        if note.asset_id != expected_asset {
            return Err(CircuitError::AssetMismatch {
                expected: felt_to_hex(&expected_asset),
                found: felt_to_hex(&note.asset_id),
            });
        }

        let commitment = compute_commitment(
            &note.value, &note.asset_id, &note.owner_pubkey, &note.nonce,
        );
        new_commitments.push(commitment);
        total_output_value = total_output_value + note.value;
    }

    // Balance conservation: Σin = Σout + fee
    let expected_output = total_output_value + *fee;
    if total_input_value != expected_output {
        return Err(CircuitError::BalanceViolation {
            total_in: felt_to_hex(&total_input_value),
            total_out: felt_to_hex(&expected_output),
        });
    }

    // ── Step 2: Build Stwo AIR witness and generate real STARK proof ──────────
    use crate::stark;

    // Convert NoteWitness → stark::InputNoteWitness
    let stark_inputs: Vec<stark::InputNoteWitness> = input_notes.iter().enumerate()
        .map(|(i, note)| {
            let commitment = note.commitment.unwrap_or_else(|| compute_commitment(
                &note.value, &note.asset_id, &note.owner_pubkey, &note.nonce,
            ));
            let nullifier = nullifiers[i];
            stark::InputNoteWitness {
                value: note.value,
                asset_id: note.asset_id,
                owner_pubkey: note.owner_pubkey,
                nonce: note.nonce,
                spending_key: note.spending_key,
                commitment,
                nullifier,
                leaf_position: note.leaf_position,
                merkle_path: note.merkle_path,
            }
        })
        .collect();

    // Convert OutputNote → stark::OutputNoteData
    let stark_outputs: Vec<stark::OutputNoteData> = output_notes.iter().enumerate()
        .map(|(i, note)| {
            let commitment = new_commitments[i];
            stark::OutputNoteData {
                value: note.value,
                asset_id: note.asset_id,
                owner_pubkey: note.owner_pubkey,
                nonce: note.nonce,
                commitment,
            }
        })
        .collect();

    let config = stark::ProverConfig::default();
    let stwo_proof = stark::prove_transfer(&stark_inputs, &stark_outputs, fee, historic_root, &config)
        .map_err(|e| CircuitError::ParseError(e))?;

    // ── Step 3: Serialize proof for FFI / Cairo verifier ──────────────────────
    let proof_elements: Vec<String> = stwo_proof.proof_felts
        .iter()
        .map(|f| felt_to_hex(f))
        .collect();

    let proof_commitment = poseidon_hash_many(
        &stwo_proof.proof_felts[..3.min(stwo_proof.proof_felts.len())]
    );

    let public_inputs = TransferPublicInputs {
        historic_root: *historic_root,
        nullifiers,
        new_commitments,
        fee: *fee,
    };

    Ok((
        StarkVeilProof {
            proof_elements,
            proof_commitment,
        },
        public_inputs,
    ))
}

/// Generate a STARK proof for an unshield operation.
///
/// Unshield proves:
/// 1. The input note exists in the Merkle tree (membership proof)
/// 2. The caller owns the note (spending_key → owner_pubkey)
/// 3. The nullifier is correctly derived
/// 4. The (amount, asset, recipient) are bound as public inputs
///
/// Uses the real Circle STARK prover with FRI proximity proof.
pub fn generate_unshield_stark_proof(
    input_note: &NoteWitness,
    amount_low: &FieldElement,
    amount_high: &FieldElement,
    recipient: &FieldElement,
    asset: &FieldElement,
    historic_root: &FieldElement,
) -> Result<(StarkVeilProof, FieldElement), CircuitError> {
    if *asset != input_note.asset_id {
        return Err(CircuitError::AssetMismatch {
            expected: felt_to_hex(&input_note.asset_id),
            found: felt_to_hex(asset),
        });
    }
    if *amount_high != FieldElement::ZERO {
        return Err(CircuitError::UnsupportedAmountHigh {
            found: felt_to_hex(amount_high),
        });
    }
    if *amount_low != input_note.value {
        return Err(CircuitError::AmountMismatch {
            expected: felt_to_hex(&input_note.value),
            found: felt_to_hex(amount_low),
        });
    }

    let commitment = input_note.commitment.unwrap_or_else(|| compute_commitment(
        &input_note.value, &input_note.asset_id,
        &input_note.owner_pubkey, &input_note.nonce,
    ));

    // Verify Merkle membership
    let computed_root = verify_merkle_path(
        &commitment,
        input_note.leaf_position,
        &input_note.merkle_path,
    );
    if computed_root != *historic_root {
        return Err(CircuitError::InvalidMerklePath {
            leaf_index: input_note.leaf_position,
            expected_root: felt_to_hex(historic_root),
            computed_root: felt_to_hex(&computed_root),
        });
    }

    // Verify ownership
    let expected_pubkey = starknet_crypto::get_public_key(&input_note.spending_key);
    if expected_pubkey != input_note.owner_pubkey {
        return Err(CircuitError::MissingField(
            "owner_pubkey does not match spending_key".to_string(),
        ));
    }

    // Compute nullifier
    let nullifier = compute_nullifier(&commitment, &input_note.spending_key);

    // ── Generate real Stwo STARK proof ────────────────────────────────────
    use crate::stark;

    let stark_input = stark::InputNoteWitness {
        value: input_note.value,
        asset_id: input_note.asset_id,
        owner_pubkey: input_note.owner_pubkey,
        nonce: input_note.nonce,
        spending_key: input_note.spending_key,
        commitment,
        nullifier,
        leaf_position: input_note.leaf_position,
        merkle_path: input_note.merkle_path,
    };

    let config = stark::ProverConfig::default();
    let stwo_proof = stark::prove_unshield(
        &stark_input, amount_low, amount_high, recipient, asset, historic_root, &config,
    ).map_err(|e| CircuitError::ParseError(e))?;

    // Serialize
    let proof_elements: Vec<String> = stwo_proof.proof_felts
        .iter()
        .map(|f| felt_to_hex(f))
        .collect();

    let proof_commitment = poseidon_hash_many(
        &stwo_proof.proof_felts[..3.min(stwo_proof.proof_felts.len())]
    );

    Ok((
        StarkVeilProof {
            proof_elements,
            proof_commitment,
        },
        nullifier,
    ))
}

/// Parse a hex Merkle path into an array of 20 FieldElements.
/// Missing levels are filled with zero hashes from `ZERO_HASHES_20`.
pub fn parse_merkle_path(path_hex: &[String]) -> Result<[FieldElement; 20], CircuitError> {
    let mut result = [FieldElement::ZERO; 20];
    for i in 0..20 {
        result[i] = felt_from_hex(ZERO_HASHES_20[i])
            .map_err(|e| CircuitError::ParseError(e))?;
    }
    for (i, hex) in path_hex.iter().enumerate() {
        if i >= 20 { break; }
        result[i] = felt_from_hex(hex)
            .map_err(|e| CircuitError::ParseError(e))?;
    }
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_commitment_deterministic() {
        let value = FieldElement::from(100u64);
        let asset = FieldElement::from(1u64);
        let owner = FieldElement::from(42u64);
        let nonce = FieldElement::from(7u64);

        let c1 = compute_commitment(&value, &asset, &owner, &nonce);
        let c2 = compute_commitment(&value, &asset, &owner, &nonce);
        assert_eq!(c1, c2, "Commitment should be deterministic");
    }

    #[test]
    fn test_nullifier_deterministic() {
        let commitment = FieldElement::from(999u64);
        let sk = FieldElement::from(12345u64);

        let n1 = compute_nullifier(&commitment, &sk);
        let n2 = compute_nullifier(&commitment, &sk);
        assert_eq!(n1, n2, "Nullifier should be deterministic");
    }

    #[test]
    fn test_nullifier_different_keys() {
        let commitment = FieldElement::from(999u64);
        let sk1 = FieldElement::from(12345u64);
        let sk2 = FieldElement::from(67890u64);

        let n1 = compute_nullifier(&commitment, &sk1);
        let n2 = compute_nullifier(&commitment, &sk2);
        assert_ne!(n1, n2, "Different keys should produce different nullifiers");
    }

    #[test]
    fn test_merkle_path_with_zero_hashes() {
        // A single leaf with all zero siblings should produce a deterministic root
        let leaf = FieldElement::from(42u64);
        let mut path = [FieldElement::ZERO; 20];
        for i in 0..20 {
            path[i] = felt_from_hex(ZERO_HASHES_20[i]).unwrap();
        }

        let root = verify_merkle_path(&leaf, 0, &path);
        assert_ne!(root, FieldElement::ZERO, "Root should not be zero");
    }

    #[test]
    fn test_transfer_proof_generates_valid_felt252() {
        // Create a minimal 1-input-1-output transfer
        let sk = FieldElement::from(12345u64);
        let pubkey = starknet_crypto::get_public_key(&sk);
        let value = FieldElement::from(100u64);
        let asset = FieldElement::from(1u64);
        let nonce = FieldElement::from(7u64);

        // Compute the commitment
        let commitment = compute_commitment(&value, &asset, &pubkey, &nonce);

        // Build a trivial Merkle tree with this leaf at position 0
        let mut path = [FieldElement::ZERO; 20];
        for i in 0..20 {
            path[i] = felt_from_hex(ZERO_HASHES_20[i]).unwrap();
        }

        let historic_root = verify_merkle_path(&commitment, 0, &path);

        let input = NoteWitness {
            value,
            asset_id: asset,
            owner_pubkey: pubkey,
            nonce,
            spending_key: sk,
            leaf_position: 0,
            merkle_path: path,
            commitment: None,
        };

        let fee = FieldElement::from(10u64);
        let output_value = FieldElement::from(90u64);
        let output = OutputNote {
            value: output_value,
            asset_id: asset,
            owner_pubkey: FieldElement::from(99999u64),
            nonce: FieldElement::from(8u64),
        };

        let result = generate_transfer_stark_proof(
            &[input], &[output], &fee, &historic_root,
        );

        match result {
            Ok((proof, public_inputs)) => {
                // Proof should have elements
                assert!(!proof.proof_elements.is_empty(), "Proof should not be empty");

                // All elements should be valid hex
                for elem in &proof.proof_elements {
                    assert!(elem.starts_with("0x"), "All proof elements should be 0x-prefixed: {}", elem);
                }

                // Should have exactly 1 nullifier and 1 commitment
                assert_eq!(public_inputs.nullifiers.len(), 1);
                assert_eq!(public_inputs.new_commitments.len(), 1);

                // Historic root should match
                assert_eq!(public_inputs.historic_root, historic_root);

                println!("Proof generated successfully with {} elements", proof.proof_elements.len());
            }
            Err(e) => panic!("Proof generation failed: {}", e),
        }
    }

    #[test]
    fn test_balance_violation_detected() {
        let sk = FieldElement::from(12345u64);
        let pubkey = starknet_crypto::get_public_key(&sk);
        let value = FieldElement::from(100u64);
        let asset = FieldElement::from(1u64);
        let nonce = FieldElement::from(7u64);

        let commitment = compute_commitment(&value, &asset, &pubkey, &nonce);
        let mut path = [FieldElement::ZERO; 20];
        for i in 0..20 {
            path[i] = felt_from_hex(ZERO_HASHES_20[i]).unwrap();
        }
        let historic_root = verify_merkle_path(&commitment, 0, &path);

        let input = NoteWitness {
            value,
            asset_id: asset,
            owner_pubkey: pubkey,
            nonce,
            spending_key: sk,
            leaf_position: 0,
            merkle_path: path,
            commitment: None,
        };

        let fee = FieldElement::from(10u64);
        // Output value too large — violates Σin = Σout + fee
        let output = OutputNote {
            value: FieldElement::from(200u64), // 200 > 100 - 10
            asset_id: asset,
            owner_pubkey: FieldElement::from(99999u64),
            nonce: FieldElement::from(8u64),
        };

        let result = generate_transfer_stark_proof(
            &[input], &[output], &fee, &historic_root,
        );
        assert!(result.is_err(), "Should detect balance violation");
    }
}
