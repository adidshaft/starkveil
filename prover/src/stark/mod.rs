//! StarkVeil Circle STARK Prover
//!
//! This module implements a production-grade STARK proving system for the
//! StarkVeil privacy pool, using the Circle STARK protocol over M31/QM31.
//!
//! # Module Structure
//!
//! - `fields`  — M31, CM31, QM31 field arithmetic and circle group operations
//! - `channel` — Poseidon-based Fiat-Shamir transcript
//! - `merkle`  — Poseidon Merkle tree for polynomial commitments
//! - `fri`     — FRI (Fast Reed-Solomon IOP) protocol
//! - `air`     — Privacy pool AIR definition and trace generation
//! - `prover`  — Top-level proof generation pipeline
//!
//! # Architecture
//!
//! ```text
//!                    ┌────────────────────────────────────────┐
//!                    │        Private Witness (Rust)          │
//!                    │  spending_keys, note values, nonces,   │
//!                    │  Merkle paths, asset_ids               │
//!                    └────────────┬───────────────────────────┘
//!                                 │
//!                    ┌────────────▼───────────────────────────┐
//!                    │    1. Trace Generation (air.rs)        │
//!                    │    Commitment ─► KeyDeriv ─► Nullifier │
//!                    │    ─► MerklePath ─► Balance            │
//!                    └────────────┬───────────────────────────┘
//!                                 │
//!                    ┌────────────▼───────────────────────────┐
//!                    │    2. LDE + Merkle Commit (merkle.rs)  │
//!                    │    Extend trace to blowup domain,      │
//!                    │    build Poseidon Merkle tree           │
//!                    └────────────┬───────────────────────────┘
//!                                 │
//!                    ┌────────────▼───────────────────────────┐
//!                    │    3. Composition Poly (air.rs)        │
//!                    │    α-combination of constraints / Z(x) │
//!                    └────────────┬───────────────────────────┘
//!                                 │
//!                    ┌────────────▼───────────────────────────┐
//!                    │    4. FRI Proximity Proof (fri.rs)     │
//!                    │    Circle FRI folding + query phase    │
//!                    └────────────┬───────────────────────────┘
//!                                 │
//!                    ┌────────────▼───────────────────────────┐
//!                    │    5. Serialize → Vec<felt252>         │
//!                    │    For Cairo on-chain verifier         │
//!                    └────────────────────────────────────────┘
//! ```

pub mod fields;
pub mod channel;
pub mod merkle;
pub mod fri;
pub mod air;
pub mod prover;

// Re-export the main entry points.
pub use prover::{prove_transfer, prove_unshield, PrivacyPoolProof, ProverConfig};
pub use air::{InputNoteWitness, OutputNoteData, CircuitPublicInputs};
