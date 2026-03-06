#ifndef STARKVEIL_PROVER_H
#define STARKVEIL_PROVER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

// ─────────────────────────────────────────────────────────────────────────────
// StarkVeil Prover — FFI Header for iOS Integration
//
// Phase 12: Real Starknet cryptography (Pedersen, Poseidon, ECDSA)
// Phase 18: RFC-6979 deterministic nonce, Poseidon nullifier/commitment
// Phase 20: Stwo STARK proof generation (replaces mock verification)
// ─────────────────────────────────────────────────────────────────────────────

/// Returns the Starknet public key (EC point x-coordinate) for a given private key.
/// Input:  hex felt252 private key
/// Output: JSON-wrapped hex felt252 public key or error
const char* stark_get_public_key(const char* private_key_hex);

/// Computes Pedersen hash of two felt252 inputs.
/// Input:  hex felt252 a, hex felt252 b
/// Output: JSON "Ok" hex felt252 or "Error"
const char* stark_pedersen_hash(const char* a_hex, const char* b_hex);

/// Computes Poseidon hash of a list of felt252 inputs (variable arity).
/// Input:  JSON array of hex felt252 strings, e.g. "[\"0x1\", \"0x2\"]"
/// Output: JSON "Ok" hex felt252 or "Error"
const char* stark_poseidon_hash(const char* elements_json);

/// Derives an Incoming Viewing Key (IVK) from a spending key.
/// IVK = Poseidon("StarkVeilIVK", spending_key)
/// Input:  hex felt252 spending_key
/// Output: JSON "Ok" hex felt252 IVK or "Error"
const char* stark_derive_ivk(const char* spending_key_hex);

/// Computes a note commitment: Poseidon(value, asset_id, owner_pubkey, nonce).
/// Input:  hex felt252 for each field
/// Output: JSON "Ok" hex felt252 commitment or "Error"
const char* stark_note_commitment(
    const char* value_hex,
    const char* asset_id_hex,
    const char* owner_pubkey_hex,
    const char* nonce_hex
);

/// Computes a note nullifier: Poseidon(commitment, spending_key).
/// Input:  hex felt252 commitment, hex felt252 spending_key
/// Output: JSON "Ok" hex felt252 nullifier or "Error"
const char* stark_note_nullifier(
    const char* commitment_hex,
    const char* spending_key_hex
);

/// Signs a transaction hash using ECDSA with RFC-6979 deterministic nonce.
/// Input:  hex felt252 private_key, hex felt252 msg_hash
/// Output: JSON with [r, s] signature components or error
const char* stark_sign_transaction(
    const char* private_key_hex,
    const char* msg_hash_hex
);

// ─────────────────────────────────────────────────────────────────────────────
// Phase 20: Stwo STARK Proof Generation
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a real Stwo STARK proof for a private transfer.
///
/// The proof cryptographically constrains:
///   - Merkle membership: each input note exists in the tree at its claimed position
///   - Balance conservation: Σ(input values) = Σ(output values) + fee
///   - Nullifier correctness: each nullifier = Poseidon(commitment, spending_key)
///   - Commitment wellformedness: Poseidon(value, asset_id, owner_pubkey, nonce)
///
/// Input:  JSON array of notes with fields:
///   [{value, asset_id, owner_pubkey, nonce, spending_key, leaf_position, merkle_path}]
///   - leaf_position: u32 position in the Merkle tree
///   - merkle_path: array of 20 hex felt252 sibling hashes
///
/// Output: JSON FFIResult with:
///   - proof: array of hex felt252 proof elements
///   - nullifiers: array of hex felt252 nullifiers
///   - new_commitments: array of hex felt252 output commitments
///   - fee: string fee amount
///   - historic_root: hex felt252 Merkle root used in the proof
const char* generate_transfer_proof(const char* notes_json);

/// Generates a real Stwo STARK proof for an unshield operation.
///
/// The proof cryptographically constrains:
///   - Merkle membership: the input note exists in the tree
///   - Ownership: spending_key → owner_pubkey
///   - Nullifier derivation: Poseidon(commitment, spending_key)
///   - Public input binding: (amount, asset, recipient) are committed
///
/// Input:  JSON with fields:
///   {note: {value, asset_id, owner_pubkey, nonce, spending_key, leaf_position, merkle_path},
///    amount_low, amount_high, recipient, asset, historic_root}
///
/// Output: JSON UnshieldFFIResult with:
///   - proof: array of hex felt252 proof elements
///   - nullifier: hex felt252 nullifier for the spent note
///   - historic_root: hex felt252 Merkle root used in the proof
const char* generate_unshield_proof(const char* unshield_json);

// ─────────────────────────────────────────────────────────────────────────────
// Memory management
// ─────────────────────────────────────────────────────────────────────────────

/// Frees a Rust-allocated CString previously returned by any FFI function.
/// Must be called exactly once per returned string to avoid memory leaks.
/// Passing NULL is safe (no-op).
void free_rust_string(char* ptr);

#endif // STARKVEIL_PROVER_H
