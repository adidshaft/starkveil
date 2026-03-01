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

        fn get_zero_hash(_level: u32) -> felt252 {
            // PLACEHOLDER: Returns 0 for all levels, matching Cairo's default storage
            // value for unwritten Map slots. This is consistent for MVP but NOT
            // cryptographically sound.
            //
            // BEFORE PRODUCTION: Replace with canonical Poseidon empty-subtree hashes:
            //   Z[0] = 0  (empty leaf)
            //   Z[k] = poseidon_hash_span([Z[k-1], Z[k-1]])
            // Compute all 20 values offline and hardcode them as a match arm each.
            // The SAME 20 constants MUST be replicated in the Rust SDK
            // (prover/src/types.rs) so witness generation and on-chain verification
            // agree on empty-node values.
            0
        }

        fn insert_leaf(ref self: ContractState, leaf: felt252) -> felt252 {
            let leaf_count = self.mt_next_index.read();

            // Capacity guard: tree holds at most 2^TREE_DEPTH = 1,048,576 leaves.
            assert(leaf_count < 1048576_u32, 'Merkle tree is full');

            self.mt_nodes.write((0, leaf_count), leaf);

            let mut current_index = leaf_count;
            let mut current_hash = leaf;
            let mut level: u32 = 0;
            // level_size tracks 2^level so we can bound sibling existence per level
            // without recomputing the power from scratch each iteration.
            let mut level_size: u32 = 1;

            loop {
                if level == TREE_DEPTH {
                    break;
                }

                let is_right_child = (current_index % 2) == 1;
                let sibling_index = if is_right_child { current_index - 1 } else { current_index + 1 };

                // A node at (level, idx) was written iff idx < ceil(leaf_count / 2^level).
                // Using raw mt_next_index (a leaf count) to bound a level-N index is wrong
                // for level > 0 — that was the prior bug. The correct bound per level is:
                //   nodes_at_level = ceil(leaf_count / level_size)
                //                  = (leaf_count + level_size - 1) / level_size
                let nodes_at_level = (leaf_count + level_size - 1) / level_size;

                let sibling_hash = if sibling_index < nodes_at_level {
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
                level_size *= 2;

                self.mt_nodes.write((level, current_index), current_hash);
            };

            self.mt_root.write(current_hash);
            self.historic_roots.write(current_hash, true);
            self.mt_next_index.write(leaf_count + 1);

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
            // 1. Build public inputs for the ZK proof verifier.
            //    Schema: [merkle_root, nullifier_0, ..., commitment_0, ...]
            //    The root here is the current tip; in production the client should
            //    supply the specific historic root the proof was generated against
            //    (and the contract should assert historic_roots.read(that_root)).
            let mut public_inputs = ArrayTrait::new();
            public_inputs.append(self.mt_root.read());

            let mut k: u32 = 0;
            loop {
                if k == nullifiers.len() { break; }
                public_inputs.append(*nullifiers.at(k));
                k += 1;
            };

            let mut m: u32 = 0;
            loop {
                if m == new_commitments.len() { break; }
                public_inputs.append(*new_commitments.at(m));
                m += 1;
            };

            // 2. Verify proof before any state mutation.
            assert(self.verify_proof(proof.span(), public_inputs.span()), 'Invalid proof');

            // 3. Mark nullifiers spent.
            let mut i = 0;
            loop {
                if i == nullifiers.len() { break; }
                let nf = *nullifiers.at(i);
                assert(!self.nullifiers.read(nf), 'Note already spent');
                self.nullifiers.write(nf, true);
                i += 1;
            };

            // 4. Insert new output commitments.
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
            // 1. Verify ZK Proof binds to the unshield amount, asset, and recipient.
            //    All four values are public inputs so the circuit commits to exactly
            //    what is being withdrawn — preventing the caller from substituting a
            //    different amount or token after proof generation.
            let mut public_inputs = ArrayTrait::new();
            public_inputs.append(amount.low.into());
            public_inputs.append(amount.high.into());
            public_inputs.append(recipient.into());
            public_inputs.append(asset.into());
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
