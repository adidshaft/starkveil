#[cfg(test)]
mod tests {
    use core::poseidon::poseidon_hash_span;
    use core::hash::{Hash, HashStateTrait};
    use core::poseidon::PoseidonTrait;

    #[test]
    fn test_storage_address() {
        let var_name = selector!("nullifiers");
        let nullifier: felt252 = 0x123;
        
        let mut state = PoseidonTrait::new();
        state = state.update(var_name);
        state = state.update(nullifier);
        let map_hash = state.finalize();
        
        println!("selector: {}", var_name);
        println!("nullifier: {}", nullifier);
        println!("map_hash (storage_address): {}", map_hash);
    }
}
