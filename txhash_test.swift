import Foundation

// We only need encodeResourceBound to test the hex mapping
struct ResourceBound {
    let max_amount: String
    let max_price_per_unit: String
}
struct ResourceBoundsMapping {
    let l1_gas: ResourceBound
    let l2_gas: ResourceBound
    let l1_data_gas: ResourceBound
}

let L1_GAS_NAME:  UInt64 = 0x4c315f474153
let L2_GAS_NAME:  UInt64 = 0x4c325f474153
let L1_DATA_NAME: UInt64 = 0x4c315f44415441

func encodeResourceBound(name: UInt64, bound: ResourceBound) -> String {
    let amountHex = bound.max_amount.hasPrefix("0x") ? String(bound.max_amount.dropFirst(2)) : bound.max_amount
    let priceHex = bound.max_price_per_unit.hasPrefix("0x") ? String(bound.max_price_per_unit.dropFirst(2)) : bound.max_price_per_unit

    let amountPadded = String(repeating: "0", count: max(0, 16 - amountHex.count)) + amountHex
    let pricePadded  = String(repeating: "0", count: max(0, 32 - priceHex.count))  + priceHex
    let nameHex = String(name, radix: 16)

    return "0x" + nameHex + amountPadded + pricePadded
}

let bounds = ResourceBoundsMapping(
    l1_gas: ResourceBound(max_amount: "0x30d40", max_price_per_unit: "0x174876e800"),
    l2_gas: ResourceBound(max_amount: "0x989680", max_price_per_unit: "0x174876e800"),
    l1_data_gas: ResourceBound(max_amount: "0x2710", max_price_per_unit: "0x174876e800")
)

print("l1_gas_bound:", encodeResourceBound(name: L1_GAS_NAME, bound: bounds.l1_gas))
print("l2_gas_bound:", encodeResourceBound(name: L2_GAS_NAME, bound: bounds.l2_gas))
print("l1_data_gas_bound:", encodeResourceBound(name: L1_DATA_NAME, bound: bounds.l1_data_gas))
