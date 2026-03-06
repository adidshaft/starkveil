//! Poseidon-based Merkle tree for polynomial commitment.
//!
//! The prover commits to trace column evaluations and FRI layer evaluations
//! by building a Merkle tree over the evaluation domain.  The hash function
//! is Starknet Poseidon (over felt252), ensuring the Cairo on-chain verifier
//! can recompute Merkle authentication paths with native Poseidon opcodes.
//!
//! Leaf packing: each leaf contains one or more M31 values (from trace columns
//! at the same evaluation point).  These are packed into felt252 before hashing.
//! Up to 7 M31 values fit in a single felt252 (7 * 31 = 217 < 252 bits).
//! For wider rows, multiple felt252 elements are hashed together.

use starknet_crypto::{poseidon_hash_many, FieldElement};
use super::fields::M31;

/// A Poseidon Merkle tree over felt252 leaves.
pub struct MerkleTree {
    /// All tree nodes stored in a flat array.
    /// Index 1 = root, 2..3 = depth-1, 4..7 = depth-2, etc.
    /// Leaves start at index `n_leaves` (1-indexed binary heap layout).
    nodes: Vec<FieldElement>,
    n_leaves: usize,
}

/// Authentication path: sibling hashes from leaf to root.
#[derive(Clone, Debug)]
pub struct MerkleProof {
    pub siblings: Vec<FieldElement>,
}

impl MerkleTree {
    /// Build a Merkle tree from the given leaves.
    /// `leaves` must have a power-of-two length.
    pub fn new(leaves: Vec<FieldElement>) -> Self {
        let n = leaves.len();
        assert!(n.is_power_of_two(), "Merkle tree requires power-of-two leaves");

        // Allocate 2*n nodes (index 0 unused, 1 = root, n..2n-1 = leaves).
        let mut nodes = vec![FieldElement::ZERO; 2 * n];

        // Copy leaves into the bottom layer.
        for (i, leaf) in leaves.iter().enumerate() {
            nodes[n + i] = *leaf;
        }

        // Build internal nodes bottom-up.
        for i in (1..n).rev() {
            nodes[i] = poseidon_hash_many(&[nodes[2 * i], nodes[2 * i + 1]]);
        }

        MerkleTree { nodes, n_leaves: n }
    }

    /// Root commitment (the Merkle root hash).
    pub fn root(&self) -> FieldElement {
        self.nodes[1]
    }

    /// Generate an authentication path for the leaf at `index`.
    pub fn prove(&self, index: usize) -> MerkleProof {
        assert!(index < self.n_leaves);
        let mut siblings = Vec::new();
        let mut pos = self.n_leaves + index;
        while pos > 1 {
            let sibling = if pos % 2 == 0 { pos + 1 } else { pos - 1 };
            siblings.push(self.nodes[sibling]);
            pos /= 2;
        }
        MerkleProof { siblings }
    }

    /// Verify that `leaf` at `index` is consistent with `root`.
    pub fn verify(
        root: &FieldElement,
        leaf: &FieldElement,
        index: usize,
        proof: &MerkleProof,
    ) -> bool {
        let mut current = *leaf;
        let mut pos = index;
        for sibling in &proof.siblings {
            current = if pos % 2 == 0 {
                poseidon_hash_many(&[current, *sibling])
            } else {
                poseidon_hash_many(&[*sibling, current])
            };
            pos /= 2;
        }
        current == *root
    }
}

/// Pack a row of M31 values into a single felt252 leaf hash.
/// Groups values into chunks of 7 (fitting in 252 bits), hashes each chunk,
/// then hashes the chunk digests together.
pub fn pack_m31_row(values: &[M31]) -> FieldElement {
    if values.is_empty() {
        return FieldElement::ZERO;
    }
    // Convert each M31 to felt252 and hash the whole row.
    let felts: Vec<FieldElement> = values
        .iter()
        .map(|v| FieldElement::from(v.0 as u64))
        .collect();
    poseidon_hash_many(&felts)
}

/// Pack a row of QM31 values (each serialized as 4 M31) into a leaf hash.
pub fn pack_qm31_row(values: &[super::fields::QM31]) -> FieldElement {
    let m31s: Vec<M31> = values
        .iter()
        .flat_map(|q| q.to_m31_array())
        .collect();
    pack_m31_row(&m31s)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_merkle_tree_basic() {
        let leaves: Vec<FieldElement> = (0..8)
            .map(|i| FieldElement::from(i as u64))
            .collect();
        let tree = MerkleTree::new(leaves.clone());
        let root = tree.root();

        // Verify each leaf.
        for i in 0..8 {
            let proof = tree.prove(i);
            assert!(MerkleTree::verify(&root, &leaves[i], i, &proof));
        }
    }

    #[test]
    fn test_merkle_tamper_detection() {
        let leaves: Vec<FieldElement> = (0..4)
            .map(|i| FieldElement::from(i as u64))
            .collect();
        let tree = MerkleTree::new(leaves.clone());
        let root = tree.root();
        let proof = tree.prove(0);
        // Tampered leaf should fail verification.
        let fake_leaf = FieldElement::from(999u64);
        assert!(!MerkleTree::verify(&root, &fake_leaf, 0, &proof));
    }
}
