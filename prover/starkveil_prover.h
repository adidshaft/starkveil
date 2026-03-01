#ifndef STARKVEIL_PROVER_H
#define STARKVEIL_PROVER_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Generates a dummy Zero-Knowledge STARK transfer proof.
/// Takes a JSON string containing the notes payload constraint bounds.
/// Returns a JSON string of the TransferPayload struct (Note Commitments, Nullifiers, Proof).
const char* generate_transfer_proof(const char* notes_json);

/// Free the string pointer returned by Rust crossing the FFI boundary
/// to prevent memory leakage memory leaks on the iOS side.
void free_rust_string(char* s);

#ifdef __cplusplus
}
#endif

#endif /* STARKVEIL_PROVER_H */
