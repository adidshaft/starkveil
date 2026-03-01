#[starknet::contract]
pub mod PrivacyPool {
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use core::poseidon::poseidon_hash_span;
    use openzeppelin::token::erc20::interface::{IERC20Dispatcher, IERC20DispatcherTrait};
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess};
    
    use super::super::interfaces::IPrivacyPool;

    const TREE_DEPTH: u32 = 20;

    #[storage]
    struct Storage {
        nullifiers: Map<felt252, bool>, // Map nullifier hash -> is_spent
        historic_roots: Map<felt252, bool>, // For asynchronous proof generation
        
        // Merkle Tree storage
        mt_next_index: u32,
        mt_nodes: Map<(u32, u32), felt252>, // (level, index) -> hash
        mt_root: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
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

    #[generate_trait]
    impl InternalImpl of InternalTrait {
        fn verify_proof(ref self: ContractState, proof: Span<felt252>, public_inputs: Span<felt252>) -> bool {
            // TODO: Integrate actual S-Two verifier here. 
            // For MVP, we verify a dummy condition or simply return true to represent a valid proof bind.
            // A real proof binds the nullifiers, commitments, and amounts to the ZK circuit.
            true
        }

        fn get_zero_hash(level: u32) -> felt252 {
            // In a real ZK application, these are precomputed hashes of empty subtrees
            // e.g. H(0,0), H(H(0,0), H(0,0)), etc.
            // For MVP, we'll return a simple level-dependent constant to avoid 0x0
            level.into()
        }

        fn insert_leaf(ref self: ContractState, leaf: felt252) -> felt252 {
            let index = self.mt_next_index.read();
            self.mt_nodes.write((0, index), leaf);
            
            let mut current_index = index;
            let mut current_hash = leaf;

            let mut level: u32 = 0;
            loop {
                if level == TREE_DEPTH {
                    break;
                }
                
                let is_right_child = (current_index % 2) == 1;
                let sibling_index = if is_right_child { current_index - 1 } else { current_index + 1 };
                
                let sibling_hash = if sibling_index < self.mt_next_index.read() {
                    self.mt_nodes.read((level, sibling_index))
                } else {
                    Self::get_zero_hash(level)
                };
                
                let (left, right) = if is_right_child {
                    (sibling_hash, current_hash)
                } else {
                    (current_hash, sibling_hash)
                };

                let mut hash_data = ArrayTrait::new();
                hash_data.append(left);
                hash_data.append(right);
                
                current_hash = poseidon_hash_span(hash_data.span());
                
                current_index = current_index / 2;
                level += 1;
                
                self.mt_nodes.write((level, current_index), current_hash);
            };

            self.mt_root.write(current_hash);
            self.historic_roots.write(current_hash, true);
            self.mt_next_index.write(index + 1);

            current_hash
        }
    }

    #[abi(embed_v0)]
    impl PrivacyPoolImpl of IPrivacyPool<ContractState> {
        fn shield(ref self: ContractState, asset: ContractAddress, amount: u256, note_commitment: felt252) {
            let caller = get_caller_address();
            let contract_addr = get_contract_address();

            let erc20 = IERC20Dispatcher { contract_address: asset };
            erc20.transfer_from(caller, contract_addr, amount);

            let index = self.mt_next_index.read();
            self.insert_leaf(note_commitment);
            
            self.emit(Event::Shielded(Shielded {
                asset: asset,
                amount: amount,
                commitment: note_commitment,
                leaf_index: index
            }));
        }

        fn private_transfer(
            ref self: ContractState,
            proof: Array<felt252>, 
            nullifiers: Array<felt252>,
            new_commitments: Array<felt252>,
            fee: u256
        ) {
            // 1. Verify ZK Proof binds to a historic root
            // In a real implementation this binds the `root`, `nullifiers`, and `new_commitments`
            let mut public_inputs = ArrayTrait::new();
            assert(self.verify_proof(proof.span(), public_inputs.span()), 'Invalid proof');

            let mut i = 0;
            loop {
                if i == nullifiers.len() { break; }
                let nf = *nullifiers.at(i);
                assert(!self.nullifiers.read(nf), 'Note already spent');
                self.nullifiers.write(nf, true);
                i += 1;
            };

            let mut j = 0;
            loop {
                if j == new_commitments.len() { break; }
                let commitment = *new_commitments.at(j);
                self.insert_leaf(commitment);
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
            // 1. Verify ZK Proof binds to the unshield amount and recipient
            let mut public_inputs = ArrayTrait::new();
            public_inputs.append(amount.low.into());
            public_inputs.append(amount.high.into());
            public_inputs.append(recipient.into());
            assert(self.verify_proof(proof.span(), public_inputs.span()), 'Invalid proof');

            assert(!self.nullifiers.read(nullifier), 'Note already spent');
            self.nullifiers.write(nullifier, true);

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
