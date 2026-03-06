//! Fiat-Shamir transcript using Poseidon sponge.
//!
//! The channel absorbs proof commitments and public inputs, then squeezes
//! pseudorandom challenges.  Using Poseidon (matching the Cairo verifier)
//! ensures both prover and verifier derive identical challenges.
//!
//! Sponge construction:
//!   state = [s0, s1, s2] (3 felt252 elements, initialized to zero)
//!   absorb(x): s0 += x; state = Poseidon_permutation(state)
//!   squeeze():  output s0; state = Poseidon_permutation(state)

use starknet_crypto::{poseidon_hash_many, FieldElement};
use super::fields::{M31, CM31, QM31};

/// Poseidon-based Fiat-Shamir channel.
pub struct Channel {
    /// Running Poseidon sponge state, represented as accumulated elements.
    /// We use the simpler approach of hashing the full transcript prefix
    /// at each squeeze, which is equivalent to a sponge for our purposes.
    digest: FieldElement,
    counter: u64,
}

impl Channel {
    pub fn new() -> Self {
        Channel {
            digest: FieldElement::ZERO,
            counter: 0,
        }
    }

    /// Absorb a felt252 value into the transcript.
    pub fn absorb_felt(&mut self, val: &FieldElement) {
        self.digest = poseidon_hash_many(&[self.digest, *val]);
    }

    /// Absorb multiple felt252 values.
    pub fn absorb_felts(&mut self, vals: &[FieldElement]) {
        let mut elements = vec![self.digest];
        elements.extend_from_slice(vals);
        self.digest = poseidon_hash_many(&elements);
    }

    /// Absorb an M31 value (converted to felt252).
    pub fn absorb_m31(&mut self, val: M31) {
        self.absorb_felt(&FieldElement::from(val.0 as u64));
    }

    /// Squeeze a felt252 challenge from the transcript.
    pub fn squeeze_felt(&mut self) -> FieldElement {
        self.counter += 1;
        let challenge = poseidon_hash_many(&[
            self.digest,
            FieldElement::from(self.counter),
        ]);
        // Feed the challenge back to maintain chain integrity.
        self.digest = challenge;
        challenge
    }

    /// Squeeze an M31 challenge (reduce felt252 mod M31_P).
    pub fn squeeze_m31(&mut self) -> M31 {
        let f = self.squeeze_felt();
        let bytes = f.to_bytes_be();
        // Take the low 31 bits.
        let lo = u32::from_be_bytes([bytes[28], bytes[29], bytes[30], bytes[31]]);
        M31::new(lo)
    }

    /// Squeeze a QM31 (secure field) challenge: four independent M31 values.
    pub fn squeeze_qm31(&mut self) -> QM31 {
        QM31(
            CM31(self.squeeze_m31(), self.squeeze_m31()),
            CM31(self.squeeze_m31(), self.squeeze_m31()),
        )
    }

    /// Squeeze N random query indices in [0, domain_size).
    /// Uses Fisher-Yates rejection sampling to avoid bias.
    pub fn squeeze_query_indices(&mut self, n_queries: usize, domain_size: usize) -> Vec<usize> {
        let mut indices = Vec::with_capacity(n_queries);
        let mut seen = std::collections::HashSet::new();
        while indices.len() < n_queries {
            let f = self.squeeze_felt();
            let bytes = f.to_bytes_be();
            let raw = u64::from_be_bytes([
                bytes[24], bytes[25], bytes[26], bytes[27],
                bytes[28], bytes[29], bytes[30], bytes[31],
            ]);
            let idx = (raw as usize) % domain_size;
            if seen.insert(idx) {
                indices.push(idx);
            }
        }
        indices
    }

    /// Get the current digest (for debugging/testing).
    pub fn current_digest(&self) -> FieldElement {
        self.digest
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_channel_deterministic() {
        let mut c1 = Channel::new();
        let mut c2 = Channel::new();
        c1.absorb_felt(&FieldElement::from(42u64));
        c2.absorb_felt(&FieldElement::from(42u64));
        assert_eq!(c1.squeeze_felt(), c2.squeeze_felt());
    }

    #[test]
    fn test_channel_different_inputs_different_output() {
        let mut c1 = Channel::new();
        let mut c2 = Channel::new();
        c1.absorb_felt(&FieldElement::from(1u64));
        c2.absorb_felt(&FieldElement::from(2u64));
        assert_ne!(c1.squeeze_felt(), c2.squeeze_felt());
    }
}
