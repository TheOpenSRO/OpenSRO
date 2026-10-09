//! Godot 4.7.2's single-precision vector and basis arithmetic, operation for operation (round 763),
//! so the effect simulation (core/efp_sim.rs) gives GDScript's bits. Every function names the
//! engine code it follows (READ, godotengine/godot 4.7.2-stable, core/math/): the same operands in
//! the same order, in f32 -- Godot's `real_t` in a standard build -- with no fused multiply-add
//! (Rust never contracts; the engine's x86-64 builds have no FMA in their baseline). Where GDScript
//! itself computes in f64 (a `float` variable), the callers here do too.
//!
//! A shortcut that is exact in real arithmetic is NOT taken: multiplying by the identity basis turns
//! a -0.0 into +0.0, and GDScript does that multiplication, so this does too.

use std::sync::atomic::{AtomicU64, Ordering};

/// How many singular bases `B3::inverse` met (returned unchanged), for the parity tools: the case
/// where the GDScript itself differs between editor and release builds.
pub static SINGULAR_INVERSES: AtomicU64 = AtomicU64::new(0);

/// Vector3 (vector3.h): x, y, z.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct V3(pub f32, pub f32, pub f32);

pub const ZERO: V3 = V3(0.0, 0.0, 0.0);
pub const ONE: V3 = V3(1.0, 1.0, 1.0);

impl V3 {
    #[inline]
    pub fn add(self, o: V3) -> V3 {
        V3(self.0 + o.0, self.1 + o.1, self.2 + o.2)
    }
    #[inline]
    pub fn sub(self, o: V3) -> V3 {
        V3(self.0 - o.0, self.1 - o.1, self.2 - o.2)
    }
    /// Component-wise (`Vector3 * Vector3`).
    #[inline]
    pub fn mul(self, o: V3) -> V3 {
        V3(self.0 * o.0, self.1 * o.1, self.2 * o.2)
    }
    /// `Vector3 * real_t` (a GDScript float is narrowed to f32 first: Variant's evaluator calls
    /// the real_t operator).
    #[inline]
    pub fn scale(self, s: f32) -> V3 {
        V3(self.0 * s, self.1 * s, self.2 * s)
    }
    #[inline]
    pub fn neg(self) -> V3 {
        V3(-self.0, -self.1, -self.2)
    }
    /// Vector3::dot: `x * p.x + y * p.y + z * p.z`.
    #[inline]
    pub fn dot(self, o: V3) -> f32 {
        self.0 * o.0 + self.1 * o.1 + self.2 * o.2
    }
    /// Vector3::length_squared: x2 + y2 + z2.
    #[inline]
    pub fn length_squared(self) -> f32 {
        let x2 = self.0 * self.0;
        let y2 = self.1 * self.1;
        let z2 = self.2 * self.2;
        x2 + y2 + z2
    }
    /// Vector3::cross.
    #[inline]
    pub fn cross(self, o: V3) -> V3 {
        V3(self.1 * o.2 - self.2 * o.1, self.2 * o.0 - self.0 * o.2, self.0 * o.1 - self.1 * o.0)
    }
    pub fn is_finite(self) -> bool {
        self.0.is_finite() && self.1.is_finite() && self.2.is_finite()
    }
    /// Vector3::normalize: zero when not finite or of length 0, else each divided by the root.
    pub fn normalized(self) -> V3 {
        if !self.is_finite() {
            return ZERO;
        }
        let l = self.length_squared();
        if l == 0.0 {
            ZERO
        } else {
            let l = l.sqrt();
            V3(self.0 / l, self.1 / l, self.2 / l)
        }
    }
    /// Vector3::lerp: Math::lerp per component, in f32.
    pub fn lerp(self, to: V3, w: f32) -> V3 {
        V3(lerp32(self.0, to.0, w), lerp32(self.1, to.1, w), lerp32(self.2, to.2, w))
    }
    /// Vector3::is_equal_approx: Math::is_equal_approx(float, float) per component.
    pub fn is_equal_approx(self, o: V3) -> bool {
        approx32(self.0, o.0) && approx32(self.1, o.1) && approx32(self.2, o.2)
    }
}

/// Math::lerp(float, float, float).
#[inline]
pub fn lerp32(a: f32, b: f32, w: f32) -> f32 {
    a + (b - a) * w
}

/// Math::lerp(double, double, double) (GDScript's lerpf).
#[inline]
pub fn lerp64(a: f64, b: f64, w: f64) -> f64 {
    a + (b - a) * w
}

/// Math::is_equal_approx(float, float): exact first (infinities), then within CMP_EPSILON scaled
/// by |a| (at least CMP_EPSILON).
pub fn approx32(a: f32, b: f32) -> bool {
    if a == b {
        return true;
    }
    let eps = 0.00001f64 as f32;
    let mut tol = eps * a.abs();
    if tol < eps {
        tol = eps;
    }
    (a - b).abs() < tol
}

/// GDScript's maxf / Godot's MAX: `a > b ? a : b` (so a NaN `a` gives `b`).
#[inline]
pub fn gmax(a: f64, b: f64) -> f64 {
    if a > b {
        a
    } else {
        b
    }
}

/// GDScript's minf / Godot's MIN: `a < b ? a : b`.
#[inline]
pub fn gmin(a: f64, b: f64) -> f64 {
    if a < b {
        a
    } else {
        b
    }
}

/// Basis (basis.h): three rows. GDScript's `Basis(x, y, z)` takes COLUMNS.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct B3 {
    pub r: [[f32; 3]; 3],
}

pub const IDENTITY: B3 = B3 { r: [[1.0, 0.0, 0.0], [0.0, 1.0, 0.0], [0.0, 0.0, 1.0]] };

impl B3 {
    /// From nine floats, row by row.
    pub fn from_rows(f: &[f32]) -> B3 {
        B3 { r: [[f[0], f[1], f[2]], [f[3], f[4], f[5]], [f[6], f[7], f[8]]] }
    }
    /// Basis(x_axis, y_axis, z_axis): set_columns.
    pub fn from_columns(x: V3, y: V3, z: V3) -> B3 {
        B3 { r: [[x.0, y.0, z.0], [x.1, y.1, z.1], [x.2, y.2, z.2]] }
    }
    /// Basis::from_scale.
    pub fn from_scale(s: V3) -> B3 {
        B3 { r: [[s.0, 0.0, 0.0], [0.0, s.1, 0.0], [0.0, 0.0, s.2]] }
    }
    pub fn column(&self, i: usize) -> V3 {
        V3(self.r[0][i], self.r[1][i], self.r[2][i])
    }
    fn row(&self, i: usize) -> V3 {
        V3(self.r[i][0], self.r[i][1], self.r[i][2])
    }
    /// Basis::operator*: element (i, j) = m.tdot_j(rows[i]) = m[0][j]*a[i][0] + m[1][j]*a[i][1] +
    /// m[2][j]*a[i][2].
    #[inline]
    pub fn mul(&self, m: &B3) -> B3 {
        let a = &self.r;
        let b = &m.r;
        let mut o = [[0.0f32; 3]; 3];
        for i in 0..3 {
            for j in 0..3 {
                o[i][j] = b[0][j] * a[i][0] + b[1][j] * a[i][1] + b[2][j] * a[i][2];
            }
        }
        B3 { r: o }
    }
    /// Basis::xform (`Basis * Vector3`): each row dotted with v.
    #[inline]
    pub fn xform(&self, v: V3) -> V3 {
        V3(self.row(0).dot(v), self.row(1).dot(v), self.row(2).dot(v))
    }
    /// Basis::determinant.
    pub fn determinant(&self) -> f32 {
        let r = &self.r;
        r[0][0] * (r[1][1] * r[2][2] - r[2][1] * r[1][2]) - r[1][0] * (r[0][1] * r[2][2] - r[2][1] * r[0][2])
            + r[2][0] * (r[0][1] * r[1][2] - r[1][1] * r[0][2])
    }
    /// Basis::inverse -> invert(): the cofactors over the determinant. A singular basis is
    /// returned UNCHANGED: invert() is `ERR_FAIL_COND(det == 0)` under MATH_CHECKS, which the
    /// editor and debug builds define (the GDScript reference this is held to); a release export
    /// template divides by zero instead (OPEN for parity there; docs/rounds/r763.md).
    pub fn inverse(&self) -> B3 {
        let r = &self.r;
        let cofac = |r1: usize, c1: usize, r2: usize, c2: usize| r[r1][c1] * r[r2][c2] - r[r1][c2] * r[r2][c1];
        let co = [cofac(1, 1, 2, 2), cofac(1, 2, 2, 0), cofac(1, 0, 2, 1)];
        let det = r[0][0] * co[0] + r[0][1] * co[1] + r[0][2] * co[2];
        if det == 0.0 {
            SINGULAR_INVERSES.fetch_add(1, Ordering::Relaxed);
            return *self;
        }
        let s = 1.0f32 / det;
        B3 {
            r: [
                [co[0] * s, cofac(0, 2, 2, 1) * s, cofac(0, 1, 1, 2) * s],
                [co[1] * s, cofac(0, 0, 2, 2) * s, cofac(0, 2, 1, 0) * s],
                [co[2] * s, cofac(0, 1, 2, 0) * s, cofac(0, 0, 1, 1) * s],
            ],
        }
    }
    /// Basis::orthonormalized: Gram-Schmidt over the columns.
    pub fn orthonormalized(&self) -> B3 {
        let x = self.column(0).normalized();
        let y = self.column(1);
        let y = y.sub(x.scale(x.dot(y))).normalized();
        let z = self.column(2);
        let z = z.sub(x.scale(x.dot(z))).sub(y.scale(y.dot(z))).normalized();
        B3::from_columns(x, y, z)
    }
    /// Basis::is_equal_approx: row by row.
    pub fn is_equal_approx(&self, o: &B3) -> bool {
        (0..3).all(|i| self.row(i).is_equal_approx(o.row(i)))
    }
    /// Basis::scale(Vector3): each row times its factor.
    fn scaled_rows(&self, s: V3) -> B3 {
        B3 { r: [self.row(0).scale(s.0).arr(), self.row(1).scale(s.1).arr(), self.row(2).scale(s.2).arr()] }
    }
    /// Basis::get_rotation_quaternion: orthonormalized, a mirror flipped by scale(-1, -1, -1), then
    /// get_quaternion. (x, y, z, w).
    pub fn rotation_quaternion(&self) -> [f32; 4] {
        let mut m = self.orthonormalized();
        if m.determinant() < 0.0 {
            m = m.scaled_rows(V3(-1.0, -1.0, -1.0));
        }
        m.quaternion()
    }
    /// Basis::get_quaternion (MATH_CHECKS' is_rotation test only prints).
    pub fn quaternion(&self) -> [f32; 4] {
        let m = &self.r;
        let trace = m[0][0] + m[1][1] + m[2][2];
        let mut t = [0.0f32; 4];
        if trace > 0.0 {
            let mut s = (trace + 1.0f32).sqrt();
            t[3] = s * 0.5f32;
            s = 0.5f32 / s;
            t[0] = (m[2][1] - m[1][2]) * s;
            t[1] = (m[0][2] - m[2][0]) * s;
            t[2] = (m[1][0] - m[0][1]) * s;
        } else {
            let i = if m[0][0] < m[1][1] {
                if m[1][1] < m[2][2] {
                    2
                } else {
                    1
                }
            } else if m[0][0] < m[2][2] {
                2
            } else {
                0
            };
            let j = (i + 1) % 3;
            let k = (i + 2) % 3;
            let mut s = (m[i][i] - m[j][j] - m[k][k] + 1.0f32).sqrt();
            t[i] = s * 0.5f32;
            s = 0.5f32 / s;
            t[3] = (m[k][j] - m[j][k]) * s;
            t[j] = (m[j][i] + m[i][j]) * s;
            t[k] = (m[k][i] + m[i][k]) * s;
        }
        t
    }
}

impl V3 {
    fn arr(self) -> [f32; 3] {
        [self.0, self.1, self.2]
    }
}

/// Godot's RandomPCG with RandomNumberGenerator's increment (random_pcg.h, thirdparty/misc/pcg.cpp).
#[derive(Clone, Debug)]
pub struct Pcg {
    state: u64,
    inc: u64,
}

/// PCG_DEFAULT_INC_64, RandomPCG::DEFAULT_INC.
pub const PCG_DEFAULT_INC: u64 = 1442695040888963407;

impl Pcg {
    /// RandomPCG::seed(seed): pcg32_srandom_r(seed, DEFAULT_INC) -- what `RandomNumberGenerator.seed
    /// = s` and `randomize()` both do.
    pub fn seeded(seed: u64) -> Pcg {
        let mut p = Pcg { state: 0, inc: (PCG_DEFAULT_INC << 1) | 1 };
        p.next_u32();
        p.state = p.state.wrapping_add(seed);
        p.next_u32();
        p
    }
    pub fn state(&self) -> u64 {
        self.state
    }
    /// pcg32_random_r.
    #[inline]
    pub fn next_u32(&mut self) -> u32 {
        let old = self.state;
        self.state = old.wrapping_mul(6364136223846793005).wrapping_add(self.inc | 1);
        let xs = (((old >> 18) ^ old) >> 27) as u32;
        let rot = (old >> 59) as u32;
        xs.rotate_right(rot)
    }
    /// RandomPCG::randf (the CLZ32 build): ldexp((float)(rand() | 0x80000001), -32 - clz(first)),
    /// 0 when the first draw is 0.
    #[inline]
    pub fn randf(&mut self) -> f32 {
        let first = self.next_u32();
        if first == 0 {
            return 0.0;
        }
        let m = (self.next_u32() | 0x8000_0001) as f32;
        let e = -32 - first.leading_zeros() as i32; // -63 ..= -32: 2^e is a normal f32, the product exact
        m * f32::from_bits(((127 + e) as u32) << 23)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pcg_reference_stream() {
        // pcg32's demo: srandom(42, 54) gives 0xa15c02b7 0x7b47f409 ...; ours uses Godot's
        // increment, so check the generator with the demo's own increment.
        let mut p = Pcg { state: 0, inc: (54u64 << 1) | 1 };
        p.next_u32();
        p.state = p.state.wrapping_add(42);
        p.next_u32();
        assert_eq!(p.next_u32(), 0xa15c02b7);
        assert_eq!(p.next_u32(), 0x7b47f409);
        assert_eq!(p.next_u32(), 0xba1d3330);
    }

    #[test]
    fn randf_in_unit_range() {
        let mut p = Pcg::seeded(1000);
        for _ in 0..10000 {
            let f = p.randf();
            assert!((0.0..=1.0).contains(&f));
        }
    }

    #[test]
    fn inverse_and_identity() {
        let b = B3::from_rows(&[2.0, 0.0, 0.0, 0.0, 4.0, 0.0, 0.0, 0.0, 8.0]);
        assert_eq!(b.inverse(), B3::from_rows(&[0.5, 0.0, 0.0, 0.0, 0.25, 0.0, 0.0, 0.0, 0.125]));
        let z = B3::from_rows(&[0.0; 9]);
        assert_eq!(z.inverse(), z);
        // -0 through the identity becomes +0, as in Godot.
        let v = IDENTITY.xform(V3(-0.0, 1.0, 2.0));
        assert!(v.0.to_bits() == 0);
    }
}
