import Foundation

let amounts: [Double] = [1.0, 0.1, 150.0]

for amount in amounts {
    let amountWeiHex: String = {
        var hex = ""
        var remaining = Decimal(amount) * Decimal(sign: .plus, exponent: 18, significand: 1)
        if remaining == 0 { return "0x0" }
        while remaining > 0 {
            let (q, r) = { (val: Decimal) -> (Decimal, Int) in
                let divisor = Decimal(16)
                let q = NSDecimalNumber(decimal: val).dividing(by: NSDecimalNumber(decimal: divisor))
                let qFloor = q.int64Value
                let rVal = NSDecimalNumber(decimal: val).subtracting(NSDecimalNumber(value: qFloor).multiplying(by: NSDecimalNumber(decimal: divisor))).intValue
                return (Decimal(qFloor), rVal)
            }(remaining)
            hex = String(r, radix: 16) + hex
            remaining = q
        }
        return "0x" + hex
    }()
    print("\(amount) -> \(amountWeiHex)")
}
