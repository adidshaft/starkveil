//! M31 and QM31 field arithmetic for Circle STARK proofs.
//!
//! # Field Tower
//!
//! ```text
//! M31       = Z / (2^31 - 1)           — Mersenne prime base field
//! CM31      = M31[i] / (i^2 + 1)      — complex extension (Gaussian integers mod p)
//! QM31      = CM31[u] / (u^2 - (2+i)) — degree-4 extension ("secure field")
//! ```
//!
//! # Circle Group
//!
//! The unit circle C(M31) = { (x,y) in M31^2 : x^2 + y^2 = 1 } has order
//! p + 1 = 2^31, a perfect power of two.  This eliminates the need for
//! roots-of-unity searches and makes the FRI domain structure trivial.
//!
//! Circle group law (isomorphic to the multiplicative group via
//! the Cayley map t -> (1-t^2)/(1+t^2), 2t/(1+t^2)):
//!   (x1,y1) * (x2,y2) = (x1*x2 - y1*y2,  x1*y2 + y1*x2)
//!
//! This is identical to complex multiplication of (x+iy), restricted
//! to the unit circle |z| = 1.

use std::fmt;
use std::ops::{Add, Mul, Neg, Sub};

// ─────────────────────────────────────────────────────────────────────────────
// M31 — Base Field
// ─────────────────────────────────────────────────────────────────────────────

/// Mersenne-31 prime: p = 2^31 - 1 = 2,147,483,647.
pub const M31_P: u32 = (1u32 << 31) - 1;

/// An element of the Mersenne-31 field.  Stored in canonical form [0, p).
#[derive(Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct M31(pub u32);

impl M31 {
    pub const ZERO: Self = M31(0);
    pub const ONE: Self = M31(1);
    pub const TWO: Self = M31(2);

    /// Construct from arbitrary u32, reducing mod p.
    #[inline]
    pub fn new(val: u32) -> Self {
        let v = val & M31_P;
        let v = v + (val >> 31);
        if v >= M31_P { M31(v - M31_P) } else { M31(v) }
    }

    /// Reduce a u64 product/sum modulo p using the Mersenne identity:
    /// 2^31 ≡ 1 (mod p), so x mod p = (x & p) + (x >> 31), with at most
    /// one further subtraction.
    #[inline]
    pub fn reduce(val: u64) -> Self {
        let lo = (val & M31_P as u64) as u32;
        let hi = (val >> 31) as u32;
        let s = lo + hi;
        if s >= M31_P { M31(s - M31_P) } else { M31(s) }
    }

    /// Multiplicative inverse via Fermat's little theorem: a^{-1} = a^{p-2}.
    pub fn inv(self) -> Self {
        debug_assert!(self.0 != 0, "cannot invert zero in M31");
        self.pow(M31_P - 2)
    }

    /// Binary exponentiation.
    pub fn pow(self, mut exp: u32) -> Self {
        let mut result = M31::ONE;
        let mut base = self;
        while exp > 0 {
            if exp & 1 == 1 {
                result = result * base;
            }
            base = base * base;
            exp >>= 1;
        }
        result
    }

    /// Convert to u64 for safe arithmetic.
    #[inline]
    pub fn as_u64(self) -> u64 {
        self.0 as u64
    }
}

impl fmt::Debug for M31 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "M31({})", self.0)
    }
}

impl fmt::Display for M31 {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl Add for M31 {
    type Output = Self;
    #[inline]
    fn add(self, rhs: Self) -> Self {
        Self::reduce(self.0 as u64 + rhs.0 as u64)
    }
}

impl Sub for M31 {
    type Output = Self;
    #[inline]
    fn sub(self, rhs: Self) -> Self {
        // Add p to avoid underflow.
        Self::reduce(self.0 as u64 + M31_P as u64 - rhs.0 as u64)
    }
}

impl Mul for M31 {
    type Output = Self;
    #[inline]
    fn mul(self, rhs: Self) -> Self {
        Self::reduce(self.0 as u64 * rhs.0 as u64)
    }
}

impl Neg for M31 {
    type Output = Self;
    #[inline]
    fn neg(self) -> Self {
        if self.0 == 0 { self } else { M31(M31_P - self.0) }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// CM31 — Complex Extension
// ─────────────────────────────────────────────────────────────────────────────

/// CM31 = M31[i] / (i^2 + 1).  Represented as a + b*i.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct CM31(pub M31, pub M31);

impl CM31 {
    pub const ZERO: Self = CM31(M31::ZERO, M31::ZERO);
    pub const ONE: Self = CM31(M31::ONE, M31::ZERO);

    pub fn conjugate(self) -> Self {
        CM31(self.0, -self.1)
    }

    /// Squared norm: |a+bi|^2 = a^2 + b^2 (in M31).
    pub fn norm_sq(self) -> M31 {
        self.0 * self.0 + self.1 * self.1
    }

    pub fn inv(self) -> Self {
        let n_inv = self.norm_sq().inv();
        CM31(self.0 * n_inv, (-self.1) * n_inv)
    }
}

impl Add for CM31 {
    type Output = Self;
    fn add(self, rhs: Self) -> Self { CM31(self.0 + rhs.0, self.1 + rhs.1) }
}

impl Sub for CM31 {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self { CM31(self.0 - rhs.0, self.1 - rhs.1) }
}

impl Mul for CM31 {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        // (a+bi)(c+di) = (ac-bd) + (ad+bc)i
        CM31(
            self.0 * rhs.0 - self.1 * rhs.1,
            self.0 * rhs.1 + self.1 * rhs.0,
        )
    }
}

impl Neg for CM31 {
    type Output = Self;
    fn neg(self) -> Self { CM31(-self.0, -self.1) }
}

// ─────────────────────────────────────────────────────────────────────────────
// QM31 — Secure (Degree-4) Extension
// ─────────────────────────────────────────────────────────────────────────────

/// QM31 = CM31[u] / (u^2 - (2+i)).  Represented as a + b*u.
///
/// Security: 4 * 31 = 124 bits, sufficient for 128-bit STARK soundness
/// with a small security margin loss handled by the number of FRI queries.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct QM31(pub CM31, pub CM31);

/// The irreducible element w = 2 + i used in QM31: u^2 = w.
pub const QM31_W: CM31 = CM31(M31::TWO, M31::ONE);

impl QM31 {
    pub const ZERO: Self = QM31(CM31::ZERO, CM31::ZERO);
    pub const ONE: Self = QM31(CM31::ONE, CM31::ZERO);

    pub fn from_m31(v: M31) -> Self {
        QM31(CM31(v, M31::ZERO), CM31::ZERO)
    }

    pub fn from_cm31(v: CM31) -> Self {
        QM31(v, CM31::ZERO)
    }

    /// Inverse in QM31.
    /// (a + bu)(a - bu) = a^2 - b^2 * w  (in CM31)
    pub fn inv(self) -> Self {
        let denom = self.0 * self.0 - self.1 * self.1 * QM31_W;
        let denom_inv = denom.inv();
        QM31(self.0 * denom_inv, -self.1 * denom_inv)
    }

    /// Serialize QM31 as four M31 values: [a.real, a.imag, b.real, b.imag].
    pub fn to_m31_array(self) -> [M31; 4] {
        [self.0 .0, self.0 .1, self.1 .0, self.1 .1]
    }

    /// Deserialize from four M31 values.
    pub fn from_m31_array(arr: [M31; 4]) -> Self {
        QM31(CM31(arr[0], arr[1]), CM31(arr[2], arr[3]))
    }
}

impl Add for QM31 {
    type Output = Self;
    fn add(self, rhs: Self) -> Self { QM31(self.0 + rhs.0, self.1 + rhs.1) }
}

impl Sub for QM31 {
    type Output = Self;
    fn sub(self, rhs: Self) -> Self { QM31(self.0 - rhs.0, self.1 - rhs.1) }
}

impl Mul for QM31 {
    type Output = Self;
    fn mul(self, rhs: Self) -> Self {
        // (a + bu)(c + du) = (ac + bd*w) + (ad + bc)u
        QM31(
            self.0 * rhs.0 + self.1 * rhs.1 * QM31_W,
            self.0 * rhs.1 + self.1 * rhs.0,
        )
    }
}

impl Neg for QM31 {
    type Output = Self;
    fn neg(self) -> Self { QM31(-self.0, -self.1) }
}

// ─────────────────────────────────────────────────────────────────────────────
// Circle Point and Domain
// ─────────────────────────────────────────────────────────────────────────────

/// A point on the unit circle x^2 + y^2 = 1 over M31.
#[derive(Clone, Copy, Debug)]
pub struct CirclePoint {
    pub x: M31,
    pub y: M31,
}

impl CirclePoint {
    /// Circle group operation (complex multiplication restricted to unit circle).
    pub fn mul_circle(self, other: Self) -> Self {
        CirclePoint {
            x: self.x * other.x - self.y * other.y,
            y: self.x * other.y + other.x * self.y,
        }
    }

    /// Circle group doubling: z -> z^2.
    /// If z = x+iy, then z^2 = (x^2-y^2) + 2xyi = (2x^2 - 1) + 2xyi.
    pub fn double(self) -> Self {
        CirclePoint {
            x: M31::TWO * self.x * self.x - M31::ONE,
            y: M31::TWO * self.x * self.y,
        }
    }

    /// Scalar multiplication: self^n in the circle group.
    pub fn pow(self, mut n: u64) -> Self {
        let mut result = CirclePoint { x: M31::ONE, y: M31::ZERO }; // identity
        let mut base = self;
        while n > 0 {
            if n & 1 == 1 {
                result = result.mul_circle(base);
            }
            base = base.double();
            n >>= 1;
        }
        result
    }

    /// Standard generator of the full circle group of order p+1 = 2^31.
    ///
    /// We use g = (2, sqrt(p-3)) where 2^2 + y^2 = 1 means y^2 = -3 mod p.
    /// sqrt(-3) mod (2^31-1) = 1,268,011,823.
    pub fn generator() -> Self {
        CirclePoint {
            x: M31(2),
            y: M31(1268011823),
        }
    }

    /// Generator of a subgroup of order 2^log_size.
    /// Obtained by raising the full generator to the power 2^(31 - log_size).
    pub fn subgroup_generator(log_size: u32) -> Self {
        let mut g = Self::generator();
        for _ in 0..(31 - log_size) {
            g = g.double();
        }
        g
    }

    /// The conjugate point (x, -y).  In the circle group, this is the inverse.
    pub fn conjugate(self) -> Self {
        CirclePoint { x: self.x, y: -self.y }
    }
}

/// A coset of a circle subgroup, used as evaluation domain.
/// Coset = { initial_point * g^i : i = 0, ..., 2^log_size - 1 }
#[derive(Clone, Debug)]
pub struct CircleDomain {
    pub log_size: u32,
    pub initial: CirclePoint,
}

impl CircleDomain {
    /// Standard domain: subgroup of order 2^log_size with canonical coset shift.
    pub fn standard(log_size: u32) -> Self {
        // Shift by half-step to get a coset disjoint from the subgroup.
        let g = CirclePoint::subgroup_generator(log_size + 1);
        CircleDomain { log_size, initial: g }
    }

    /// Enumerate all points in this domain.
    pub fn points(&self) -> Vec<CirclePoint> {
        let n = 1usize << self.log_size;
        let g = CirclePoint::subgroup_generator(self.log_size);
        let mut pts = Vec::with_capacity(n);
        let mut current = self.initial;
        for _ in 0..n {
            pts.push(current);
            current = current.mul_circle(g);
        }
        pts
    }

    pub fn size(&self) -> usize {
        1 << self.log_size
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// Felt252 ↔ M31 Limb Decomposition
// ─────────────────────────────────────────────────────────────────────────────

/// Number of 16-bit limbs needed for felt252 (252 bits / 16 = 16 limbs, 256 total bits).
pub const FELT252_N_LIMBS: usize = 16;

/// Decompose a felt252 (as big-endian bytes) into 16 M31 limbs of 16 bits each.
/// Limb 0 is the least significant.
///
/// This representation allows constraining felt252 arithmetic in the M31 trace:
/// value = sum_{i=0}^{15} limb_i * 2^{16*i}
pub fn felt252_to_m31_limbs(bytes_be: &[u8; 32]) -> [M31; FELT252_N_LIMBS] {
    let mut limbs = [M31::ZERO; FELT252_N_LIMBS];
    // Bytes are big-endian; convert to little-endian limbs of 16 bits.
    for i in 0..FELT252_N_LIMBS {
        let byte_idx_lo = 31 - 2 * i;       // least significant byte of this limb
        let byte_idx_hi = 31 - 2 * i - 1;   // most significant byte
        let lo = if byte_idx_lo < 32 { bytes_be[byte_idx_lo] as u32 } else { 0 };
        let hi = if byte_idx_hi < 32 { bytes_be[byte_idx_hi] as u32 } else { 0 };
        limbs[i] = M31::new((hi << 8) | lo);
    }
    limbs
}

/// Reconstruct felt252 big-endian bytes from 16 M31 limbs (16 bits each).
pub fn m31_limbs_to_felt252(limbs: &[M31; FELT252_N_LIMBS]) -> [u8; 32] {
    let mut bytes = [0u8; 32];
    for i in 0..FELT252_N_LIMBS {
        let val = limbs[i].0 & 0xFFFF;
        let byte_idx_lo = 31 - 2 * i;
        let byte_idx_hi = 31 - 2 * i - 1;
        if byte_idx_lo < 32 { bytes[byte_idx_lo] = (val & 0xFF) as u8; }
        if byte_idx_hi < 32 { bytes[byte_idx_hi] = ((val >> 8) & 0xFF) as u8; }
    }
    bytes
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_m31_arithmetic() {
        let a = M31(100);
        let b = M31(200);
        assert_eq!((a + b).0, 300);
        assert_eq!((a * b).0, 20000);
        assert_eq!((b - a).0, 100);
        assert_eq!((-a + a).0, 0);
    }

    #[test]
    fn test_m31_inverse() {
        let a = M31(12345);
        let a_inv = a.inv();
        assert_eq!((a * a_inv).0, 1);
    }

    #[test]
    fn test_qm31_inverse() {
        let a = QM31(CM31(M31(3), M31(7)), CM31(M31(11), M31(13)));
        let a_inv = a.inv();
        let product = a * a_inv;
        assert_eq!(product, QM31::ONE);
    }

    #[test]
    fn test_circle_generator_on_circle() {
        let g = CirclePoint::generator();
        // x^2 + y^2 should equal 1 mod p
        let lhs = g.x * g.x + g.y * g.y;
        assert_eq!(lhs, M31::ONE);
    }

    #[test]
    fn test_circle_doubling_stays_on_circle() {
        let g = CirclePoint::generator();
        let g2 = g.double();
        let lhs = g2.x * g2.x + g2.y * g2.y;
        assert_eq!(lhs, M31::ONE);
    }

    #[test]
    fn test_felt252_roundtrip() {
        let mut bytes = [0u8; 32];
        bytes[31] = 0x42;
        bytes[30] = 0xAB;
        bytes[0] = 0x07; // top byte
        let limbs = felt252_to_m31_limbs(&bytes);
        let reconstructed = m31_limbs_to_felt252(&limbs);
        assert_eq!(bytes, reconstructed);
    }
}
