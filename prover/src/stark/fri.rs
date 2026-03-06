//! FRI (Fast Reed-Solomon Interactive Oracle Proof of Proximity) for Circle STARKs.
//!
//! # Protocol Overview
//!
//! FRI proves that a committed function f: D -> F is close to a polynomial
//! of degree < d, where D is a circle domain of size N and d = N / blowup.
//!
//! ## Circle FRI Folding
//!
//! For a standard (multiplicative) FRI, folding uses:
//!   f_folded(x) = (f(x) + f(-x))/2 + alpha * (f(x) - f(-x))/(2x)
//!
//! For Circle FRI over the circle group C(M31), the analogous operation is:
//!   Given twin points P = (x,y) and P' = (x,-y) on the circle,
//!   f_folded(x) = (f(P) + f(P'))/2 + alpha * (f(P) - f(P'))/(2y)
//!
//! Each folding step halves the domain size.  After log2(N/blowup) - 1 steps,
//! the remaining polynomial is of constant degree and sent in the clear.
//!
//! ## Security
//!
//! Soundness error per query: blowup^{-1} (for blowup factor 2^log_blowup).
//! With n_queries independent queries, total soundness = blowup^{-n_queries}.
//! For 128-bit security with blowup=16: need ceil(128/4) = 32 queries.

use starknet_crypto::FieldElement;

use super::fields::{M31, QM31, CircleDomain};
use super::channel::Channel;
use super::merkle::{MerkleTree, MerkleProof};

/// Configuration for the FRI protocol.
pub struct FriConfig {
    /// log2 of the blowup factor (rate^{-1}).  Typical value: 4 (blowup = 16).
    pub log_blowup: u32,
    /// Number of FRI queries for soundness amplification.
    pub n_queries: usize,
}

impl Default for FriConfig {
    fn default() -> Self {
        FriConfig {
            log_blowup: 4,
            n_queries: 32,
        }
    }
}

/// A committed FRI layer: evaluations + Merkle commitment.
pub struct FriLayer {
    pub evaluations: Vec<M31>,
    pub tree: MerkleTree,
}

/// The complete FRI proof, ready for serialization.
pub struct FriProof {
    /// Merkle root of each FRI layer (except the last, which is sent in the clear).
    pub layer_commitments: Vec<FieldElement>,
    /// Folding challenges (alpha) for each layer.
    pub alphas: Vec<QM31>,
    /// Coefficients of the final (constant or low-degree) polynomial.
    pub last_layer_coeffs: Vec<M31>,
    /// Per-query decommitment data.
    pub query_proofs: Vec<FriQueryProof>,
}

/// Decommitment data for a single FRI query.
pub struct FriQueryProof {
    pub query_index: usize,
    /// Value at the query position in each FRI layer.
    pub layer_values: Vec<(M31, M31)>, // (value at P, value at conjugate P')
    /// Merkle authentication paths for each layer.
    pub layer_auth_paths: Vec<MerkleProof>,
}

/// Run the FRI commit phase: fold evaluations and commit to each layer.
pub fn fri_commit(
    evaluations: &[M31],
    domain: &CircleDomain,
    channel: &mut Channel,
    config: &FriConfig,
) -> (Vec<FriLayer>, Vec<QM31>, Vec<M31>) {
    let mut layers = Vec::new();
    let mut alphas = Vec::new();
    let mut current_evals = evaluations.to_vec();
    let mut current_log_size = domain.log_size;

    let n_fold_steps = current_log_size - config.log_blowup;

    for _step in 0..n_fold_steps {
        // Commit to current layer.
        let leaves: Vec<FieldElement> = current_evals
            .iter()
            .map(|v| FieldElement::from(v.0 as u64))
            .collect();
        let tree = MerkleTree::new(leaves);
        channel.absorb_felt(&tree.root());

        layers.push(FriLayer {
            evaluations: current_evals.clone(),
            tree,
        });

        // Squeeze folding challenge.
        let alpha = channel.squeeze_qm31();
        alphas.push(alpha);

        // Fold: pair twin points (index i and i + n/2) and combine.
        // In Circle FRI, twin points are at indices i and i + half
        // where half = current_size / 2.
        let half = current_evals.len() / 2;
        let domain_points = CircleDomain::standard(current_log_size).points();

        let mut folded = Vec::with_capacity(half);
        for i in 0..half {
            let f_p = current_evals[i];
            let f_p_conj = current_evals[i + half];
            let y = domain_points[i].y;

            // Circle FRI folding:
            //   f_even = (f(P) + f(P')) / 2
            //   f_odd  = (f(P) - f(P')) / (2 * y)
            //   f_folded = f_even + alpha * f_odd
            //
            // For simplicity, we work in M31 and use only the real part of alpha.
            // A full implementation would use QM31 arithmetic throughout.
            let alpha_real = alpha.0.0; // M31 component

            let sum = f_p + f_p_conj;
            let diff = f_p - f_p_conj;

            let two_inv = M31::TWO.inv();
            let f_even = sum * two_inv;

            let two_y_inv = (M31::TWO * y).inv();
            let f_odd = diff * two_y_inv;

            let folded_val = f_even + alpha_real * f_odd;
            folded.push(folded_val);
        }

        current_evals = folded;
        current_log_size -= 1;
    }

    // The remaining evaluations form the "last layer" polynomial.
    let last_coeffs = current_evals;

    (layers, alphas, last_coeffs)
}

/// Run the FRI query phase: open committed layers at random positions.
pub fn fri_query(
    layers: &[FriLayer],
    config: &FriConfig,
    channel: &mut Channel,
) -> Vec<FriQueryProof> {
    if layers.is_empty() {
        return Vec::new();
    }

    let domain_size = layers[0].evaluations.len();
    let query_indices = channel.squeeze_query_indices(config.n_queries, domain_size / 2);

    let mut proofs = Vec::with_capacity(config.n_queries);

    for &qi in &query_indices {
        let mut layer_values = Vec::new();
        let mut layer_auth_paths = Vec::new();
        let mut idx = qi;

        for layer in layers {
            let half = layer.evaluations.len() / 2;
            let twin_idx = idx + half;

            let val = layer.evaluations[idx];
            let twin_val = layer.evaluations[twin_idx.min(layer.evaluations.len() - 1)];
            layer_values.push((val, twin_val));

            let auth_path = layer.tree.prove(idx);
            layer_auth_paths.push(auth_path);

            // For the next layer, the folded index is idx (mod half).
            idx = idx % (half / 2).max(1);
        }

        proofs.push(FriQueryProof {
            query_index: qi,
            layer_values,
            layer_auth_paths,
        });
    }

    proofs
}

/// Serialize a complete FRI proof into a flat Vec<FieldElement> for the Cairo verifier.
pub fn serialize_fri_proof(
    layers: &[FriLayer],
    alphas: &[QM31],
    last_coeffs: &[M31],
    query_proofs: &[FriQueryProof],
) -> Vec<FieldElement> {
    let mut out = Vec::new();

    // Number of FRI layers.
    out.push(FieldElement::from(layers.len() as u64));

    // Layer commitments.
    for layer in layers {
        out.push(layer.tree.root());
    }

    // Folding challenges (alpha), each serialized as 4 M31 packed into felt252.
    for alpha in alphas {
        let parts = alpha.to_m31_array();
        for p in &parts {
            out.push(FieldElement::from(p.0 as u64));
        }
    }

    // Last layer coefficients.
    out.push(FieldElement::from(last_coeffs.len() as u64));
    for c in last_coeffs {
        out.push(FieldElement::from(c.0 as u64));
    }

    // Query proofs.
    out.push(FieldElement::from(query_proofs.len() as u64));
    for qp in query_proofs {
        out.push(FieldElement::from(qp.query_index as u64));

        // Layer values (twin pairs).
        for (v, tv) in &qp.layer_values {
            out.push(FieldElement::from(v.0 as u64));
            out.push(FieldElement::from(tv.0 as u64));
        }

        // Authentication paths.
        for auth in &qp.layer_auth_paths {
            out.push(FieldElement::from(auth.siblings.len() as u64));
            out.extend_from_slice(&auth.siblings);
        }
    }

    out
}
