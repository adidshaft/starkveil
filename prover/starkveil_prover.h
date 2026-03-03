#ifndef STARKVEIL_PROVER_H
#define STARKVEIL_PROVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ─────────────────────────────────────────────────────────────────────────────
// Legacy: Transfer Proof (mock — will be replaced by real ZK circuit in Phase 14)
// ─────────────────────────────────────────────────────────────────────────────

/// Generates a dummy Zero-Knowledge STARK transfer proof.
/// Takes a JSON string containing the notes payload constraint bounds.
/// Returns a JSON string of FFIResult (Success(TransferPayload) or Error).
const char* generate_transfer_proof(const char* notes_json);

// ─────────────────────────────────────────────────────────────────────────────
// Phase 12: Real Starknet Cryptography
// ─────────────────────────────────────────────────────────────────────────────

/// Computes the STARK public key (EC scalar multiply) for a given private key.
/// Input:  0x-prefixed hex felt252 private key (null-terminated C string).
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"} (caller must free via free_rust_string).
const char* stark_get_public_key(const char* private_key_hex);

/// Computes the Cairo Pedersen hash H(a, b) using real shift-point constants.
/// Inputs:  two 0x-prefixed hex felt252 strings (null-terminated C strings).
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"} (caller must free via free_rust_string).
const char* stark_pedersen_hash(const char* a_hex, const char* b_hex);

/// Computes Poseidon hash of a JSON array of 0x-prefixed hex felt252 strings.
/// Input:  JSON array e.g. ["0xa","0xb"] (null-terminated C string).
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"} (caller must free via free_rust_string).
const char* stark_poseidon_hash(const char* elements_json);

/// Signs a Starknet transaction hash with the account spending key.
/// Inputs:  tx_hash_hex, private_key_hex, k_hex — all 0x-prefixed felt252 hex C strings.
/// Output: JSON {"Ok": {"r": "0x...", "s": "0x..."}} or {"Error": "message"}.
///         Caller must free the returned pointer via free_rust_string.
/// Warning: k MUST be unique per signature. Reusing k leaks the private key.
const char* stark_sign_transaction(const char* tx_hash_hex,
                                   const char* private_key_hex,
                                   const char* k_hex);

// ─────────────────────────────────────────────────────────────────────────────
// Phase 15: Note Commitment, Nullifier, and Viewing Key
// ─────────────────────────────────────────────────────────────────────────────

/// Derives an Incoming Viewing Key (IVK) from the spending key.
/// IVK = Poseidon(spending_key, domain_separator).
/// Safe to share with watch-only nodes for incoming note detection.
/// Input:  0x-prefixed hex felt252 spending key.
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"}.
const char* stark_derive_ivk(const char* spending_key_hex);

/// Computes a note commitment: Poseidon(value, asset_id, owner_pubkey, nonce).
/// Matches the Cairo PrivacyPool contract's commitment scheme.
/// All inputs are 0x-prefixed hex felt252 strings.
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"}.
const char* stark_note_commitment(const char* value_hex,
                                  const char* asset_id_hex,
                                  const char* owner_pubkey_hex,
                                  const char* nonce_hex);

/// Computes a note nullifier: Poseidon(commitment, spending_key).
/// Spending this note reveals the nullifier on-chain (prevents double-spend).
/// Output: JSON {"Ok": "0x..."} or {"Error": "message"}.
const char* stark_note_nullifier(const char* commitment_hex,
                                 const char* spending_key_hex);

// ─────────────────────────────────────────────────────────────────────────────
// Memory management
// ─────────────────────────────────────────────────────────────────────────────

/// Frees a string pointer returned by any Rust FFI function above.
/// Must be called exactly once per returned pointer. Never pass a Swift-owned pointer.
void free_rust_string(char* s);

#ifdef __cplusplus
}
#endif

#endif /* STARKVEIL_PROVER_H */
