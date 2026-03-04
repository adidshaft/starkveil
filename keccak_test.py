from eth_hash.auto import keccak

def starknet_keccak(name: str) -> str:
    h = keccak(name.encode("utf-8"))
    val = int.from_bytes(h, "big")
    val = val & ((1 << 250) - 1)
    return hex(val)

print("approve:", starknet_keccak("approve"))
print("shield:", starknet_keccak("shield"))
print("unshield:", starknet_keccak("unshield"))
print("transfer:", starknet_keccak("transfer"))
