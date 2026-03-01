use starknet::ContractAddress;

#[starknet::contract]
pub mod PrivacyPool {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    
    use super::super::interfaces::IPrivacyPool;
    use super::super::merkle_tree::MerkleTreeComponent;

    component!(path: MerkleTreeComponent, storage: merkle_tree, event: MerkleTreeEvent);

    #[abi(embed_v0)]
    impl MerkleTreeImpl = MerkleTreeComponent::MerkleTreeImpl<ContractState>;

    impl MerkleTreeInternalImpl = MerkleTreeComponent::InternalImpl<ContractState>;

    #[storage]
    struct Storage {
        #[substorage(v0)]
        merkle_tree: MerkleTreeComponent::Storage,
        
        nullifiers: starknet::storage::Map<felt252, bool>, // Map nullifier hash -> is_spent
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        MerkleTreeEvent: MerkleTreeComponent::Event,
        Shielded: Shielded,
        Transfer: Transfer,
        Unshielded: Unshielded
    }

    #[derive(Drop, starknet::Event)]
    struct Shielded {
        asset: ContractAddress,
        amount: u256,
        commitment: felt252,
        leaf_index: u32
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        new_commitments: Array<felt252>,
        fee: u256,
    }

    #[derive(Drop, starknet::Event)]
    struct Unshielded {
        recipient: ContractAddress,
        amount: u256,
        asset: ContractAddress,
        nullifier: felt252
    }

    #[abi(embed_v0)]
    impl PrivacyPoolImpl of IPrivacyPool<ContractState> {
        fn shield(ref self: ContractState, asset: ContractAddress, amount: u256, note_commitment: felt252) {
            let caller = get_caller_address();
            let contract_addr = get_contract_address();

            // Transfer funds from user to this contract
            // Requires approval beforehand
            let erc20 = IERC20Dispatcher { contract_address: asset };
            erc20.transfer_from(caller, contract_addr, amount);

            // Insert commitment into MT
            let new_root = self.merkle_tree.insert(note_commitment);
            // Index from Merkle tree component isn't easily returned in this rough draft, 
            // so we'll just emit 0 or add a getter later. Let's assume leaf index is not critical for basic tests.
            
            self.emit(Event::Shielded(Shielded {
                asset: asset,
                amount: amount,
                commitment: note_commitment,
                leaf_index: 0
            }));
        }

        fn private_transfer(
            ref self: ContractState,
            proof: Array<felt252>, 
            nullifiers: Array<felt252>,
            new_commitments: Array<felt252>,
            fee: u256
        ) {
            // 1. Verify ZK Proof (omitted from MVP, assumed valid)
            // 2. Process nullifiers
            let mut i = 0;
            loop {
                if i == nullifiers.len() { break; }
                let nf = *nullifiers.at(i);
                assert(!self.nullifiers.read(nf), 'Note already spent');
                self.nullifiers.write(nf, true);
                i += 1;
            };

            // 3. Insert new commitments
            let mut j = 0;
            loop {
                if j == new_commitments.len() { break; }
                let commitment = *new_commitments.at(j);
                self.merkle_tree.insert(commitment);
                j += 1;
            };

            self.emit(Event::Transfer(Transfer {
                new_commitments: new_commitments,
                fee: fee
            }));
        }

        fn unshield(
            ref self: ContractState,
            proof: Array<felt252>,
            nullifier: felt252,
            recipient: ContractAddress,
            amount: u256,
            asset: ContractAddress
        ) {
            // 1. Verify ZK Proof (omitted) that proof allows this unshield
            
            // 2. Check nullifier
            assert(!self.nullifiers.read(nullifier), 'Note already spent');
            self.nullifiers.write(nullifier, true);

            // 3. Transfer out
            let erc20 = IERC20Dispatcher { contract_address: asset };
            erc20.transfer(recipient, amount);

            self.emit(Event::Unshielded(Unshielded {
                recipient: recipient,
                amount: amount,
                asset: asset,
                nullifier: nullifier
            }));
        }
    }
}
