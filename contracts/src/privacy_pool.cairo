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
        leaf_index: u32,
        // AES-256-GCM encrypted memo (IVK-keyed). Recipients trial-decrypt this
        // during SyncEngine polling to identify incoming notes.
        encrypted_memo: felt252
    }

    #[derive(Drop, starknet::Event)]
    struct Transfer {
        new_commitments: Array<felt252>,
        fee: u256,
        encrypted_memo: felt252,
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
            // MOCK VERIFIER: Returns true unconditionally for demo purposes.
            // TODO: Integrate the Stwo (Starknet Two) verifier once the client-side
            // prover circuit is complete. The Stwo verifier runs fully on-chain and
            // does not require any external proving service (preserving full privacy).
            true
        }

        fn get_zero_hash(level: u32) -> felt252 {
            if level == 0 { 0 }
            else if level == 1 { 0x293d3e8a80f400daaaffdd5932e2bcc8814bab8f414a75dcacf87318f8b14c5 }
            else if level == 2 { 0x296ec483967ad3fbe3407233db378b6284cc1fcc78d62457b97a4be6744ad0d }
            else if level == 3 { 0x4127be83b42296fe28f98f8fdda29b96e22e5d90501f7d31b84e729ec2fac3f }
            else if level == 4 { 0x33883305ab0df1ab7610153578a4d510b845841b84d90ed993133ce4ce8f827 }
            else if level == 5 { 0x40e4093fe5af73becf6507f475a529a78e49f604539ea5f3547059b5e7f1076 }
            else if level == 6 { 0x55dac7437527a89b6c03ecb7141193e30a38f87324f3da22f3b8ce7411a88cd }
            else if level == 7 { 0x1ec859a19ca9ab8d8663eb85a09cfb902326fc14b3a2121569ed2847a9c22bf }
            else if level == 8 { 0x765e137cda6685830cf14ec5298f46097e78a3be06aa15beced907f1a22d9fd }
            else if level == 9 { 0x5d25d6b8f11e34542cc850407899926bd61e253dd776477996151f6554f3da1 }
            else if level == 10 { 0x4a21358c3e754766216b4c93ecfae222e86822f746e706e563f3a05ef398959 }
            else if level == 11 { 0x754ef42b3e3b74dfa72b4d3a1d209e42bb1ca97ff2c88ff1855345f5b357e48 }
            else if level == 12 { 0x2bcb136aacbdb24b04af1e4bb0b3ffbb498fb4e18eed0a9ea6d67d1e364483b }
            else if level == 13 { 0x5217091dfec63f0513351a00820896fd2eaca65690848373cf9c2840480ee7f }
            else if level == 14 { 0x16e1846f39b0d2925c60d7e0e99a304ed5e1ddf1244dc7d93046c2ce6510cdf }
            else if level == 15 { 0x3a7e107c9eef537905902c3c3acc6204353c06e8916274c97c56725ff2e3b95 }
            else if level == 16 { 0xb2d71ff5f414c577fb3e1d946ed639e1e84f31c53c6a7af1b8f97522be62ca }
            else if level == 17 { 0x7672e9549873d8f291e72a50ae711641339836f38eebb8bbd219f311ea36d07 }
            else if level == 18 { 0x384bf7a44fc20b2de2c7c0655256b2cc64cecd66cacf75821d9716d08ef4326 }
            else if level == 19 { 0x688a48d473aaa2ecfa9bfe6fc46d0bf3d755f380db6b9e7fa9c792f5e9353c6 }
            else if level == 20 { 0x2dbdbece8787cd765854509dbff122cd2ca371f2d7a15550cdc513950311734 }
            else { 0 }
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
        fn shield(ref self: ContractState, asset: ContractAddress, amount: u256, note_commitment: felt252, encrypted_memo: felt252) {
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
                leaf_index: index,
                encrypted_memo: encrypted_memo
            }));
        }

        fn private_transfer(
            ref self: ContractState,
            proof: Array<felt252>,
            nullifiers: Array<felt252>,
            new_commitments: Array<felt252>,
            fee: u256,
            encrypted_memo: felt252
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
                fee: fee,
                encrypted_memo: encrypted_memo
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
