// A simple append-only Merkle Tree for Poseidon hashes
use core::hash::{HashStateTrait, HashStateExTrait};
use core::poseidon::{PoseidonTrait, poseidon_hash_span};

#[starknet::component]
pub mod MerkleTreeComponent {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess, StoragePointerWriteAccess
    };
    use core::poseidon::poseidon_hash_span;

    const TREE_DEPTH: u32 = 20;

    #[storage]
    struct Storage {
        pub next_index: u32,
        pub nodes: Map<(u32, u32), felt252>, // (level, index) -> hash
        pub root: felt252,
    }

    #[generate_trait]
    pub impl InternalImpl<
        TContractState, +HasComponent<TContractState>
    > of InternalTrait<TContractState> {
        fn insert(ref self: ComponentState<TContractState>, leaf: felt252) -> felt252 {
            let index = self.next_index.read();
            self.nodes.write((0, index), leaf);
            
            let mut current_index = index;
            let mut current_hash = leaf;

            let mut level: u32 = 0;
            loop {
                if level == TREE_DEPTH {
                    break;
                }
                
                let is_right_child = (current_index % 2) == 1;
                let sibling_index = if is_right_child { current_index - 1 } else { current_index + 1 };
                
                let sibling_hash = self.nodes.read((level, sibling_index));
                
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
                
                self.nodes.write((level, current_index), current_hash);
            };

            self.root.write(current_hash);
            self.next_index.write(index + 1);

            current_hash
        }

        fn get_root(self: @ComponentState<TContractState>) -> felt252 {
            self.root.read()
        }
    }
}
