use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, Hash)]
pub struct Note {
    pub value: u256,
    pub asset_id: ContractAddress,
    pub owner_ivk: felt252, // incoming viewing key
    pub memo: felt252,
}

#[derive(Copy, Drop, Serde, Hash)]
pub struct Nullifier {
    pub nullifier_hash: felt252,
}
