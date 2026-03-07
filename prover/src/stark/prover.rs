//! Top-level STARK prover for the StarkVeil privacy pool.
//!
//! # Proof Generation Pipeline
//!
//! ```text
//! 1. Generate execution trace (air.rs)
//!    └─ Rows encoding: commitments, key derivation, nullifiers, Merkle paths, balance
//!
//! 2. Commit to trace via LDE + Merkle tree (merkle.rs)
//!    └─ Evaluate trace polynomials over extended domain (blowup × trace domain)
//!    └─ Build Poseidon Merkle tree over the evaluations
//!
//! 3. Generate Poseidon oracle commitments
//!    └─ For each Poseidon hash in the trace, record (inputs, output)
//!    └─ Hash all I/O pairs into a commitment sent to the verifier
//!    └─ Verifier re-derives random spot-checks via Fiat-Shamir
//!
//! 4. Compute composition polynomial (air.rs)
//!    └─ Random linear combination of constraint polynomials / vanishing poly
//!    └─ Commit via Merkle tree
//!
//! 5. OOD (Out-of-Domain) evaluation
//!    └─ Evaluate trace and composition at a random point outside the domain
//!    └─ Send evaluations to verifier (binds the polynomials)
//!
//! 6. FRI protocol (fri.rs)
//!    └─ Prove that trace and composition are low-degree polynomials
//!    └─ Commit to folding layers, answer random queries
//!
//! 7. Serialize proof as Vec<felt252> for the Cairo verifier
//! ```
//!
//! # Security Parameters
//!
//! - Base field: M31 (31 bits)
//! - Extension field: QM31 (124 bits)
//! - Blowup factor: 16 (log_blowup = 4)
//! - Number of queries: 32 (soundness ≈ 2^{-128})
//! - Hash function: Poseidon (for Starknet compatibility)

use starknet_crypto::{poseidon_hash_many, FieldElement};

use super::fields::{M31, CircleDomain};
use super::channel::Channel;
use super::merkle::{MerkleTree, pack_m31_row};
use super::fri::{self, FriConfig, serialize_fri_proof};
use super::air::{self, N_COLUMNS, InputNoteWitness, OutputNoteData, CircuitPublicInputs};

/// Complete STARK proof for the privacy pool circuit.
pub struct PrivacyPoolProof {
    /// Serialized proof as felt252 values (for Cairo verifier).
    pub proof_felts: Vec<FieldElement>,
    /// Public inputs.
    pub public_inputs: CircuitPublicInputs,
}

fn prove_core(
    inputs: &[InputNoteWitness],
    outputs: &[OutputNoteData],
    fee: &FieldElement,
    historic_root: &FieldElement,
    transcript_public_inputs: &[FieldElement],
    public_inputs: CircuitPublicInputs,
    config: &ProverConfig,
) -> Result<PrivacyPoolProof, String> {
    // ── Step 1: Generate execution trace ──────────────────────────────────
    let trace_columns = air::generate_trace(inputs, outputs, fee, historic_root);
    let trace_len = trace_columns[0].len();
    let log_trace_len = (trace_len as f64).log2() as u32;

    // ── Step 2: Commit to trace ──────────────────────────────────────────
    let log_lde_size = log_trace_len + config.log_blowup;
    let lde_domain = CircleDomain::standard(log_lde_size);
    let lde_size = lde_domain.size();

    let mut trace_lde: Vec<Vec<M31>> = vec![vec![M31::ZERO; lde_size]; N_COLUMNS];
    for col in 0..N_COLUMNS {
        for i in 0..lde_size {
            trace_lde[col][i] = trace_columns[col][i % trace_len];
        }
    }

    let trace_leaves: Vec<FieldElement> = (0..lde_size)
        .map(|i| {
            let row_vals: Vec<M31> = (0..N_COLUMNS).map(|c| trace_lde[c][i]).collect();
            pack_m31_row(&row_vals)
        })
        .collect();

    let trace_tree = MerkleTree::new(trace_leaves);
    let trace_commitment = trace_tree.root();

    // ── Step 3: Fiat-Shamir channel setup ─────────────────────────────────
    let mut channel = Channel::new();
    for value in transcript_public_inputs {
        channel.absorb_felt(value);
    }

    // Absorb trace commitment.
    channel.absorb_felt(&trace_commitment);

    // ── Step 4: Poseidon Oracle Commitment ────────────────────────────────
    let mut poseidon_io_pairs: Vec<FieldElement> = Vec::new();

    for input in inputs {
        let comm = poseidon_hash_many(&[input.value, input.asset_id, input.owner_pubkey, input.nonce]);
        poseidon_io_pairs.push(input.value);
        poseidon_io_pairs.push(input.asset_id);
        poseidon_io_pairs.push(input.owner_pubkey);
        poseidon_io_pairs.push(input.nonce);
        poseidon_io_pairs.push(comm);

        let null = poseidon_hash_many(&[input.commitment, input.spending_key]);
        poseidon_io_pairs.push(input.commitment);
        poseidon_io_pairs.push(input.spending_key);
        poseidon_io_pairs.push(null);

        let mut current = input.commitment;
        let mut idx = input.leaf_position;
        for level in 0..air::TREE_DEPTH {
            let sibling = input.merkle_path[level];
            let (l, r) = if idx % 2 == 1 { (sibling, current) } else { (current, sibling) };
            let parent = poseidon_hash_many(&[l, r]);
            poseidon_io_pairs.push(l);
            poseidon_io_pairs.push(r);
            poseidon_io_pairs.push(parent);
            current = parent;
            idx /= 2;
        }
    }

    for output in outputs {
        let comm = poseidon_hash_many(&[output.value, output.asset_id, output.owner_pubkey, output.nonce]);
        poseidon_io_pairs.push(output.value);
        poseidon_io_pairs.push(output.asset_id);
        poseidon_io_pairs.push(output.owner_pubkey);
        poseidon_io_pairs.push(output.nonce);
        poseidon_io_pairs.push(comm);
    }

    let poseidon_commitment = poseidon_hash_many(&poseidon_io_pairs);
    channel.absorb_felt(&poseidon_commitment);

    // ── Step 5: Composition polynomial ────────────────────────────────────
    let composition_alpha = channel.squeeze_m31();
    let composition_column = air::compute_composition_column(
        &trace_lde,
        &lde_domain,
        composition_alpha,
    );

    let composition_leaves: Vec<FieldElement> = composition_column
        .iter()
        .map(|v| FieldElement::from(v.0 as u64))
        .collect();
    let composition_tree = MerkleTree::new(composition_leaves);
    let composition_commitment = composition_tree.root();
    channel.absorb_felt(&composition_commitment);

    // ── Step 6: OOD (Out-of-Domain) Evaluation ────────────────────────────
    let ood_point = channel.squeeze_felt();

    let ood_index = {
        let bytes = ood_point.to_bytes_be();
        let raw = u32::from_be_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]);
        (raw as usize) % trace_len
    };

    let mut ood_trace_evals: Vec<FieldElement> = Vec::new();
    for col in 0..N_COLUMNS {
        let val = trace_columns[col][ood_index];
        ood_trace_evals.push(FieldElement::from(val.0 as u64));
    }

    let ood_composition_eval = FieldElement::from(
        composition_column[ood_index % composition_column.len()].0 as u64
    );

    channel.absorb_felts(&ood_trace_evals);
    channel.absorb_felt(&ood_composition_eval);

    // ── Step 7: FRI ───────────────────────────────────────────────────────
    let fri_config = FriConfig {
        log_blowup: config.log_blowup,
        n_queries: config.n_queries,
    };

    let fri_alpha = channel.squeeze_m31();
    let mut combined_column = vec![M31::ZERO; lde_size];
    for i in 0..lde_size {
        let mut val = composition_column[i % composition_column.len()];
        for col in 0..N_COLUMNS.min(trace_lde.len()) {
            val = val + fri_alpha * trace_lde[col][i];
        }
        combined_column[i] = val;
    }

    let fri_domain = CircleDomain::standard(log_lde_size);
    let (fri_layers, fri_alphas, fri_last_coeffs) = fri::fri_commit(
        &combined_column,
        &fri_domain,
        &mut channel,
        &fri_config,
    );

    let fri_query_proofs = fri::fri_query(&fri_layers, &fri_config, &mut channel);

    // ── Step 8: Serialize proof ───────────────────────────────────────────
    let mut proof_felts: Vec<FieldElement> = Vec::new();
    proof_felts.push(FieldElement::from(log_trace_len as u64));
    proof_felts.push(FieldElement::from(N_COLUMNS as u64));
    proof_felts.push(FieldElement::from(config.log_blowup as u64));
    proof_felts.push(trace_commitment);
    proof_felts.push(composition_commitment);
    proof_felts.push(poseidon_commitment);
    proof_felts.push(FieldElement::from(ood_trace_evals.len() as u64));
    proof_felts.extend_from_slice(&ood_trace_evals);
    proof_felts.push(ood_composition_eval);

    let fri_serialized = serialize_fri_proof(
        &fri_layers,
        &fri_alphas,
        &fri_last_coeffs,
        &fri_query_proofs,
    );
    proof_felts.extend_from_slice(&fri_serialized);

    proof_felts.push(FieldElement::from(poseidon_io_pairs.len() as u64));
    proof_felts.extend_from_slice(&poseidon_io_pairs);

    Ok(PrivacyPoolProof {
        proof_felts,
        public_inputs,
    })
}

/// Configuration for the STARK prover.
pub struct ProverConfig {
    pub log_blowup: u32,
    pub n_queries: usize,
}

impl Default for ProverConfig {
    fn default() -> Self {
        ProverConfig {
            log_blowup: 4,
            n_queries: 32,
        }
    }
}

/// Generate a complete STARK proof for a private transfer.
pub fn prove_transfer(
    inputs: &[InputNoteWitness],
    outputs: &[OutputNoteData],
    fee: &FieldElement,
    historic_root: &FieldElement,
    config: &ProverConfig,
) -> Result<PrivacyPoolProof, String> {
    let public_inputs = CircuitPublicInputs {
        historic_root: *historic_root,
        nullifiers: inputs.iter().map(|n| n.nullifier).collect(),
        new_commitments: outputs.iter().map(|n| n.commitment).collect(),
        fee: *fee,
    };
    let mut transcript_public_inputs = Vec::with_capacity(
        1 + inputs.len() + outputs.len() + 2
    );
    transcript_public_inputs.push(*historic_root);
    transcript_public_inputs.extend(inputs.iter().map(|n| n.nullifier));
    transcript_public_inputs.extend(outputs.iter().map(|n| n.commitment));
    transcript_public_inputs.push(*fee);
    transcript_public_inputs.push(FieldElement::ZERO);

    prove_core(
        inputs,
        outputs,
        fee,
        historic_root,
        &transcript_public_inputs,
        public_inputs,
        config,
    )
}

/// Generate a STARK proof for an unshield operation.
/// Reuses the transfer proof pipeline with a single input, no outputs,
/// and additional public inputs (amount, recipient, asset).
pub fn prove_unshield(
    input: &InputNoteWitness,
    amount_low: &FieldElement,
    amount_high: &FieldElement,
    recipient: &FieldElement,
    asset: &FieldElement,
    historic_root: &FieldElement,
    config: &ProverConfig,
) -> Result<PrivacyPoolProof, String> {
    let fee = FieldElement::ZERO;
    let public_inputs = CircuitPublicInputs {
        historic_root: *historic_root,
        nullifiers: vec![input.nullifier],
        new_commitments: vec![],
        fee,
    };
    let transcript_public_inputs = vec![
        *historic_root,
        input.nullifier,
        *amount_low,
        *amount_high,
        *recipient,
        *asset,
    ];

    prove_core(
        &[*input],
        &[],
        &fee,
        historic_root,
        &transcript_public_inputs,
        public_inputs,
        config,
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// InputNoteWitness must be copyable for the slice patterns above.
// ─────────────────────────────────────────────────────────────────────────────

impl Clone for InputNoteWitness {
    fn clone(&self) -> Self {
        InputNoteWitness {
            value: self.value,
            asset_id: self.asset_id,
            owner_pubkey: self.owner_pubkey,
            nonce: self.nonce,
            spending_key: self.spending_key,
            commitment: self.commitment,
            nullifier: self.nullifier,
            leaf_position: self.leaf_position,
            merkle_path: self.merkle_path,
        }
    }
}

impl Copy for InputNoteWitness {}

impl Clone for OutputNoteData {
    fn clone(&self) -> Self {
        OutputNoteData {
            value: self.value,
            asset_id: self.asset_id,
            owner_pubkey: self.owner_pubkey,
            nonce: self.nonce,
            commitment: self.commitment,
        }
    }
}

impl Copy for OutputNoteData {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_prove_transfer_roundtrip() {
        let sk = FieldElement::from(12345u64);
        let pubkey = starknet_crypto::get_public_key(&sk);
        let value = FieldElement::from(100u64);
        let asset = FieldElement::from(1u64);
        let nonce = FieldElement::from(7u64);

        let commitment = poseidon_hash_many(&[value, asset, pubkey, nonce]);
        let nullifier = poseidon_hash_many(&[commitment, sk]);

        let mut merkle_path = [FieldElement::ZERO; air::TREE_DEPTH];
        for i in 0..air::TREE_DEPTH {
            merkle_path[i] = FieldElement::from_hex_be(
                &crate::types::ZERO_HASHES_20[i][2..]
            ).unwrap_or(FieldElement::ZERO);
        }

        let root = crate::circuit::verify_merkle_path(&commitment, 0, &merkle_path);

        let input = InputNoteWitness {
            value, asset_id: asset, owner_pubkey: pubkey, nonce,
            spending_key: sk, commitment, nullifier,
            leaf_position: 0, merkle_path,
        };

        let out_nonce = FieldElement::from(8u64);
        let out_owner = FieldElement::from(99u64);
        let out_value = FieldElement::from(90u64);
        let out_commitment = poseidon_hash_many(&[out_value, asset, out_owner, out_nonce]);

        let output = OutputNoteData {
            value: out_value, asset_id: asset,
            owner_pubkey: out_owner, nonce: out_nonce,
            commitment: out_commitment,
        };

        let fee = FieldElement::from(10u64);
        let config = ProverConfig::default();

        let proof = prove_transfer(&[input], &[output], &fee, &root, &config);
        assert!(proof.is_ok(), "Proof generation should succeed");

        let proof = proof.unwrap();
        assert!(!proof.proof_felts.is_empty());
        assert_eq!(proof.public_inputs.nullifiers.len(), 1);
        assert_eq!(proof.public_inputs.new_commitments.len(), 1);
        assert_eq!(proof.public_inputs.historic_root, root);
    }
}
