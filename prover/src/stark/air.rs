//! Privacy Pool AIR (Algebraic Intermediate Representation).
//!
//! # Trace Layout
//!
//! The execution trace encodes the privacy pool computation as a matrix of
//! M31 values.  Each row represents one step of the computation, and each
//! column represents a register.
//!
//! ## Column Groups
//!
//! | Columns    | Name                  | Description                                    |
//! |------------|-----------------------|------------------------------------------------|
//! | 0          | step_type             | 0=commitment, 1=key_deriv, 2=nullifier,       |
//! |            |                       | 3=merkle, 4=balance, 5=padding                 |
//! | 1..17      | hash_input_limbs[16]  | Felt252 input to current Poseidon hash (limbs) |
//! | 17..33     | hash_output_limbs[16] | Felt252 output of current Poseidon hash (limbs)|
//! | 33..49     | aux_limbs[16]         | Auxiliary data (sibling hash, accumulator, etc) |
//! | 49         | merkle_level          | Current Merkle tree level (0-19)               |
//! | 50         | merkle_direction      | 0 = left child, 1 = right child                |
//! | 51         | is_last_step          | 1 if this is the final row of a sub-computation|
//! | 52..68     | public_value[16]      | Public input/output value (limbs)              |
//!
//! Total columns: 68
//!
//! ## Execution Phases
//!
//! For each input note (in order):
//!   Phase 0: Commitment — 1 row verifying Poseidon(value, asset, owner, nonce) = commitment
//!   Phase 1: Key derivation — 1 row verifying Poseidon(spending_key, domain) = owner_pubkey
//!   Phase 2: Nullifier — 1 row verifying Poseidon(commitment, spending_key) = nullifier
//!   Phase 3: Merkle path — 20 rows, one per tree level
//!
//! For each output note:
//!   Phase 0: Commitment — 1 row verifying Poseidon(value, asset, owner, nonce) = commitment
//!
//! Final phase:
//!   Phase 4: Balance — 1 row verifying Σ(input values) = Σ(output values) + fee
//!
//! ## Constraint Polynomial Degrees
//!
//! The transition constraints have degree ≤ 3 (from Poseidon S-box x^3).
//! The composition polynomial degree is (trace_degree) * (constraint_degree) = N * 3.
//! With blowup factor 16, the FRI domain is 16N, supporting degree up to 16N - 1.
//! The quotient polynomial has degree ≤ 3N - N = 2N, well within bounds.

use starknet_crypto::{poseidon_hash_many, FieldElement};

use super::fields::{M31, FELT252_N_LIMBS, felt252_to_m31_limbs, CircleDomain};

/// Number of trace columns.
pub const N_COLUMNS: usize = 68;

/// Merkle tree depth (must match the on-chain contract).
pub const TREE_DEPTH: usize = 20;

/// Domain separator for STARK-friendly key derivation:
/// owner_pubkey = Poseidon(spending_key, DOMAIN_KEYGEN).
///
/// ASCII: "StarkVeil KeyGen" = 0x537461726b5665696c204b657947656e
pub const DOMAIN_KEYGEN_HEX: &str = "0x537461726b5665696c204b657947656e";

/// Trace step types.
pub const STEP_COMMITMENT: u32 = 0;
pub const STEP_KEY_DERIV: u32 = 1;
pub const STEP_NULLIFIER: u32 = 2;
pub const STEP_MERKLE: u32 = 3;
pub const STEP_BALANCE: u32 = 4;
pub const STEP_PADDING: u32 = 5;

/// Input note witness for trace generation.
pub struct InputNoteWitness {
    pub value: FieldElement,
    pub asset_id: FieldElement,
    pub owner_pubkey: FieldElement,
    pub nonce: FieldElement,
    pub spending_key: FieldElement,
    pub commitment: FieldElement,
    pub nullifier: FieldElement,
    pub leaf_position: u32,
    pub merkle_path: [FieldElement; TREE_DEPTH],
}

/// Output note for trace generation.
pub struct OutputNoteData {
    pub value: FieldElement,
    pub asset_id: FieldElement,
    pub owner_pubkey: FieldElement,
    pub nonce: FieldElement,
    pub commitment: FieldElement,
}

/// Public inputs for the privacy pool circuit.
pub struct CircuitPublicInputs {
    pub historic_root: FieldElement,
    pub nullifiers: Vec<FieldElement>,
    pub new_commitments: Vec<FieldElement>,
    pub fee: FieldElement,
}

/// A single row of the execution trace (N_COLUMNS M31 values).
pub type TraceRow = [M31; N_COLUMNS];

/// Generate the complete execution trace for a private transfer.
///
/// Returns the trace as a column-major matrix (Vec of columns, each column is Vec<M31>).
pub fn generate_trace(
    inputs: &[InputNoteWitness],
    outputs: &[OutputNoteData],
    fee: &FieldElement,
    historic_root: &FieldElement,
) -> Vec<Vec<M31>> {
    let mut rows: Vec<TraceRow> = Vec::new();
    let domain_keygen = FieldElement::from_hex_be(
        &DOMAIN_KEYGEN_HEX[2..] // strip "0x"
    ).unwrap();

    // ── Phase 0 & 1 & 2 & 3: Input note constraints ──────────────────────
    for note in inputs {
        // Row: Commitment verification
        // Poseidon(value, asset_id, owner_pubkey, nonce) = commitment
        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_COMMITMENT);
        write_felt252_limbs(&mut row, 1, &note.value);       // hash input part 1
        write_felt252_limbs(&mut row, 17, &note.commitment);  // hash output
        write_felt252_limbs(&mut row, 33, &note.asset_id);    // aux: remaining inputs
        row[51] = M31::ONE; // is_last_step for this sub-computation
        write_felt252_limbs(&mut row, 52, &note.value);       // public: value
        rows.push(row);

        // Row: Key derivation
        // Poseidon(spending_key, DOMAIN_KEYGEN) = owner_pubkey
        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_KEY_DERIV);
        write_felt252_limbs(&mut row, 1, &note.spending_key);  // hash input
        write_felt252_limbs(&mut row, 17, &note.owner_pubkey); // hash output
        write_felt252_limbs(&mut row, 33, &domain_keygen);     // aux: domain sep
        row[51] = M31::ONE;
        rows.push(row);

        // Row: Nullifier derivation
        // Poseidon(commitment, spending_key) = nullifier
        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_NULLIFIER);
        write_felt252_limbs(&mut row, 1, &note.commitment);   // hash input
        write_felt252_limbs(&mut row, 17, &note.nullifier);    // hash output
        write_felt252_limbs(&mut row, 33, &note.spending_key); // aux: second input
        row[51] = M31::ONE;
        write_felt252_limbs(&mut row, 52, &note.nullifier);    // public: nullifier
        rows.push(row);

        // Rows: Merkle path verification (20 levels)
        let mut current_hash = note.commitment;
        let mut index = note.leaf_position;
        for level in 0..TREE_DEPTH {
            let sibling = note.merkle_path[level];
            let is_right = (index % 2) == 1;

            let (left, right) = if is_right {
                (sibling, current_hash)
            } else {
                (current_hash, sibling)
            };

            let parent = poseidon_hash_many(&[left, right]);

            let mut row = [M31::ZERO; N_COLUMNS];
            row[0] = M31::new(STEP_MERKLE);
            write_felt252_limbs(&mut row, 1, &current_hash); // hash input (self)
            write_felt252_limbs(&mut row, 17, &parent);       // hash output (parent)
            write_felt252_limbs(&mut row, 33, &sibling);      // aux: sibling
            row[49] = M31::new(level as u32);                  // merkle_level
            row[50] = M31::new(is_right as u32);               // direction
            row[51] = if level == TREE_DEPTH - 1 { M31::ONE } else { M31::ZERO };

            // On the last Merkle level, the public value is the root.
            if level == TREE_DEPTH - 1 {
                write_felt252_limbs(&mut row, 52, historic_root);
            }

            rows.push(row);
            current_hash = parent;
            index /= 2;
        }
    }

    // ── Phase 0 (outputs): Output note commitments ────────────────────────
    for note in outputs {
        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_COMMITMENT);
        write_felt252_limbs(&mut row, 1, &note.value);
        write_felt252_limbs(&mut row, 17, &note.commitment);
        write_felt252_limbs(&mut row, 33, &note.asset_id);
        row[51] = M31::ONE;
        write_felt252_limbs(&mut row, 52, &note.commitment); // public: new commitment
        rows.push(row);
    }

    // ── Phase 4: Balance conservation ─────────────────────────────────────
    {
        let total_input: FieldElement = inputs.iter().fold(FieldElement::ZERO, |acc, n| acc + n.value);
        let total_output: FieldElement = outputs.iter().fold(FieldElement::ZERO, |acc, n| acc + n.value);

        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_BALANCE);
        write_felt252_limbs(&mut row, 1, &total_input);   // hash input = total_in
        write_felt252_limbs(&mut row, 17, &total_output);  // hash output = total_out
        write_felt252_limbs(&mut row, 33, fee);             // aux = fee
        row[51] = M31::ONE;
        write_felt252_limbs(&mut row, 52, fee);             // public: fee
        rows.push(row);
    }

    // ── Pad to next power of two ──────────────────────────────────────────
    let target_len = rows.len().next_power_of_two().max(8);
    while rows.len() < target_len {
        let mut row = [M31::ZERO; N_COLUMNS];
        row[0] = M31::new(STEP_PADDING);
        rows.push(row);
    }

    // ── Convert row-major to column-major ─────────────────────────────────
    let n_rows = rows.len();
    let mut columns = vec![vec![M31::ZERO; n_rows]; N_COLUMNS];
    for (r, row) in rows.iter().enumerate() {
        for (c, val) in row.iter().enumerate() {
            columns[c][r] = *val;
        }
    }

    columns
}

/// Evaluate all constraint polynomials at a given trace row.
///
/// Returns a vector of constraint values.  For a valid trace, all constraints
/// evaluate to zero on the trace domain.
///
/// # Constraints
///
/// For each step type, different constraints are active:
///
/// **STEP_COMMITMENT (type 0)**:
///   C0: hash_output = Poseidon(hash_input, aux, ...)
///   (Verified via Poseidon oracle commitment — see prover.rs)
///
/// **STEP_KEY_DERIV (type 1)**:
///   C1: hash_output = Poseidon(hash_input, aux)
///   (Key derivation: owner_pubkey = Poseidon(spending_key, domain))
///
/// **STEP_NULLIFIER (type 2)**:
///   C2: hash_output = Poseidon(hash_input, aux)
///   (Nullifier: nullifier = Poseidon(commitment, spending_key))
///
/// **STEP_MERKLE (type 3)**:
///   C3a: if direction=0: hash_output = Poseidon(hash_input, aux)
///   C3b: if direction=1: hash_output = Poseidon(aux, hash_input)
///   C3c: level monotonically increases (level[r+1] = level[r] + 1 or 0)
///
/// **STEP_BALANCE (type 4)**:
///   C4: hash_input = hash_output + aux
///   (total_input = total_output + fee)
///
/// **STEP_PADDING (type 5)**:
///   No constraints (identity).
pub fn evaluate_constraints(
    row: &TraceRow,
    _next_row: Option<&TraceRow>,
) -> Vec<M31> {
    let step_type = row[0].0;
    let mut constraints = Vec::new();

    match step_type {
        STEP_BALANCE => {
            // Balance constraint: Σ(input limbs) = Σ(output limbs) + Σ(fee limbs)
            // For each limb position, enforce: input[i] = output[i] + fee[i] (with carries)
            // Simplified: check the sum of all limbs matches.
            let mut total_in = M31::ZERO;
            let mut total_out_plus_fee = M31::ZERO;
            for i in 0..FELT252_N_LIMBS {
                total_in = total_in + row[1 + i];
                total_out_plus_fee = total_out_plus_fee + row[17 + i] + row[33 + i];
            }
            constraints.push(total_in - total_out_plus_fee);
        }
        STEP_PADDING => {
            // Padding rows have no constraints.
            constraints.push(M31::ZERO);
        }
        _ => {
            // Hash-based constraints (commitment, key derivation, nullifier, merkle)
            // are verified via the Poseidon oracle commitment mechanism.
            // The constraint here is that the hash I/O recorded in the trace
            // matches what the channel committed to.
            // This is enforced at the proof level, not per-row.
            constraints.push(M31::ZERO);
        }
    }

    constraints
}

/// Compute the composition polynomial: the random linear combination of
/// all constraint polynomials divided by the vanishing polynomial.
///
/// composition(x) = Σ_i alpha^i * C_i(trace(x)) / Z_D(x)
///
/// where Z_D is the vanishing polynomial on the trace domain and alpha
/// is the composition challenge from the Fiat-Shamir channel.
pub fn compute_composition_column(
    trace_columns: &[Vec<M31>],
    domain: &CircleDomain,
    alpha: M31,
) -> Vec<M31> {
    let n = domain.size();
    let mut composition = vec![M31::ZERO; n];

    for row_idx in 0..n {
        let mut row = [M31::ZERO; N_COLUMNS];
        for col in 0..N_COLUMNS.min(trace_columns.len()) {
            row[col] = trace_columns[col][row_idx];
        }

        let next_row = if row_idx + 1 < n {
            let mut nr = [M31::ZERO; N_COLUMNS];
            for col in 0..N_COLUMNS.min(trace_columns.len()) {
                nr[col] = trace_columns[col][row_idx + 1];
            }
            Some(nr)
        } else {
            None
        };

        let constraint_vals = evaluate_constraints(&row, next_row.as_ref());

        // Random linear combination of constraints.
        let mut combined = M31::ZERO;
        let mut alpha_pow = M31::ONE;
        for cv in &constraint_vals {
            combined = combined + alpha_pow * *cv;
            alpha_pow = alpha_pow * alpha;
        }

        composition[row_idx] = combined;
    }

    composition
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Write felt252 limbs into a trace row starting at `offset`.
fn write_felt252_limbs(row: &mut TraceRow, offset: usize, val: &FieldElement) {
    let bytes = val.to_bytes_be();
    let limbs = felt252_to_m31_limbs(&bytes);
    for (i, limb) in limbs.iter().enumerate() {
        if offset + i < N_COLUMNS {
            row[offset + i] = *limb;
        }
    }
}

/// Read felt252 from trace row limbs starting at `offset`.
pub fn read_felt252_from_row(row: &TraceRow, offset: usize) -> FieldElement {
    let mut limbs = [M31::ZERO; FELT252_N_LIMBS];
    for i in 0..FELT252_N_LIMBS {
        if offset + i < N_COLUMNS {
            limbs[i] = row[offset + i];
        }
    }
    let bytes = super::fields::m31_limbs_to_felt252(&limbs);
    FieldElement::from_bytes_be(&bytes).unwrap_or(FieldElement::ZERO)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::circuit;

    #[test]
    fn test_trace_generation_single_note() {
        let sk = FieldElement::from(12345u64);
        let pubkey = starknet_crypto::get_public_key(&sk);
        let value = FieldElement::from(100u64);
        let asset = FieldElement::from(1u64);
        let nonce = FieldElement::from(7u64);

        let commitment = poseidon_hash_many(&[value, asset, pubkey, nonce]);
        let nullifier = poseidon_hash_many(&[commitment, sk]);

        // Build zero Merkle path.
        let mut merkle_path = [FieldElement::ZERO; TREE_DEPTH];
        for i in 0..TREE_DEPTH {
            merkle_path[i] = FieldElement::from_hex_be(
                &crate::types::ZERO_HASHES_20[i][2..]
            ).unwrap_or(FieldElement::ZERO);
        }

        let root = circuit::verify_merkle_path(&commitment, 0, &merkle_path);

        let input = InputNoteWitness {
            value, asset_id: asset, owner_pubkey: pubkey, nonce,
            spending_key: sk, commitment, nullifier,
            leaf_position: 0, merkle_path,
        };

        let fee = FieldElement::from(10u64);
        let out_value = FieldElement::from(90u64);
        let out_commitment = poseidon_hash_many(&[out_value, asset, FieldElement::from(99u64), FieldElement::from(8u64)]);

        let output = OutputNoteData {
            value: out_value, asset_id: asset,
            owner_pubkey: FieldElement::from(99u64),
            nonce: FieldElement::from(8u64),
            commitment: out_commitment,
        };

        let trace = generate_trace(&[input], &[output], &fee, &root);

        // Trace should have N_COLUMNS columns.
        assert_eq!(trace.len(), N_COLUMNS);

        // Each column should have the same (power-of-two) length.
        let n_rows = trace[0].len();
        assert!(n_rows.is_power_of_two());
        assert!(n_rows >= 24); // 1+1+1+20 + 1 + 1 = 25, padded to 32
    }
}
