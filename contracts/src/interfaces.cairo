use starknet::ContractAddress;

#[starknet::interface]
pub trait IPrivacyPool<TContractState> {
    fn shield(ref self: TContractState, asset: ContractAddress, amount: u256, note_commitment: felt252, encrypted_memo: felt252);
    
    fn private_transfer(
        ref self: TContractState,
        proof: Array<felt252>, 
        nullifiers: Array<felt252>,
        new_commitments: Array<felt252>,
        fee: u256,
        encrypted_memo: felt252
    );

    fn unshield(
        ref self: TContractState,
        proof: Array<felt252>,
        nullifier: felt252,
        recipient: ContractAddress,
        amount: u256,
        asset: ContractAddress
    );
}
