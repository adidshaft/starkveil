/// Stwo Verifier Interface — Phase 20: Integrity FactRegistry Interface
///
/// This module defines the interface for the Herodotus Integrity FactRegistry contract
/// deployed on Starknet Sepolia. The FactRegistry stores verified proof hashes and
/// allows on-chain verification of STARK proofs.
///
/// FactRegistry address (Sepolia): 0x07d3550237ecf2d6ddef9b78e59b38647ee511467fe000ce276f245a006b40bc


#[starknet::interface]
pub trait IFactRegistry<TContractState> {
    /// Returns true if the given fact hash has been verified and stored in the registry.
    /// A fact hash is typically Poseidon(proof_commitment, public_inputs_hash).
    fn is_valid(self: @TContractState, fact: felt252) -> bool;
}
