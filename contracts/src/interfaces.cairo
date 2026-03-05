use starknet::ContractAddress;

/// Phase 20: Updated interface with historic_root parameter for Stwo STARK verification.
/// The historic_root binds the proof to a specific Merkle tree state, allowing
/// asynchronous proof generation (the tree may have changed since proof creation).
#[starknet::interface]
pub trait IPrivacyPool<TContractState> {
    fn shield(ref self: TContractState, asset: ContractAddress, amount: u256, note_commitment: felt252, encrypted_memo: felt252);
    
    /// Phase 20: Added `historic_root` parameter.
    /// The proof is verified against this root (must exist in `historic_roots` map).
    fn private_transfer(
        ref self: TContractState,
        proof: Array<felt252>, 
        nullifiers: Array<felt252>,
        new_commitments: Array<felt252>,
        fee: u256,
        encrypted_memo: felt252,
        historic_root: felt252
    );

    /// Phase 20: Added `historic_root` parameter.
    /// Fixes L-5 audit: Merkle root is now included in public inputs.
    fn unshield(
        ref self: TContractState,
        proof: Array<felt252>,
        nullifier: felt252,
        recipient: ContractAddress,
        amount: u256,
        asset: ContractAddress,
        historic_root: felt252
    );
}
