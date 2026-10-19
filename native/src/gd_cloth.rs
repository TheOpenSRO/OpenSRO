//! The cloth's gdext binding (round 794): `SrCloth`, one mesh's cloth (core/cloth.rs) on one body.
//! Plain data in and out: packed arrays, never a Variant per vertex. GDScript reaches the class by
//! name (client/scripts/assets/cloth_native.gd), so the client compiles and runs without the
//! library, with ClothSim (GDScript) stepping the same rules.
//!
//! Called from the main thread only.

use godot::prelude::*;

use crate::core::cloth::{self, Cloth, Params};

/// The cloth interface's own number (ClothNative.CLOTH_API): an additive class, so core::API is
/// unchanged and an older library keeps its readers.
const CLOTH_API: i64 = 1;

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrCloth {
    c: Option<Cloth>,
    error: String,
}

fn v3s(a: &PackedVector3Array) -> Vec<[f32; 3]> {
    a.as_slice().iter().map(|v| [v.x, v.y, v.z]).collect()
}

fn get<T: FromGodot>(d: &VarDictionary, k: &str) -> Result<T, String> {
    d.get(k).ok_or_else(|| format!("missing {k}"))?.try_to::<T>().map_err(|e| format!("{k}: {e}"))
}

fn build(d: &VarDictionary) -> Result<Cloth, String> {
    let amount: PackedFloat32Array = get(d, "amount")?;
    let pinned: PackedByteArray = get(d, "pinned")?;
    let links: PackedInt32Array = get(d, "links")?;
    let rest: PackedFloat32Array = get(d, "rest")?;
    let order: PackedInt32Array = get(d, "order")?;
    let params: PackedFloat32Array = get(d, "params")?;
    let positions: PackedVector3Array = get(d, "positions")?;
    let normals: PackedVector3Array = get(d, "normals")?;
    let bones: PackedInt32Array = get(d, "bones")?;
    let weights: PackedFloat32Array = get(d, "weights")?;
    let vertex_data: PackedByteArray = get(d, "vertex_data")?;
    let p = Params::from_slice(params.as_slice()).ok_or("params: nine values")?;
    Cloth::new(
        amount.as_slice(),
        pinned.as_slice(),
        links.as_slice(),
        rest.as_slice(),
        order.as_slice(),
        p,
        &v3s(&positions),
        &v3s(&normals),
        bones.as_slice(),
        weights.as_slice(),
        vertex_data.as_slice(),
    )
}

#[godot_api]
impl SrCloth {
    #[func]
    fn cloth_api(&self) -> i64 {
        CLOTH_API
    }

    /// ClothSim.setup's dictionary. False (and `last_error`) when the data is refused.
    #[func]
    fn setup(&mut self, d: VarDictionary) -> bool {
        match build(&d) {
            Ok(c) => {
                self.c = Some(c);
                self.error.clear();
                true
            }
            Err(e) => {
                self.c = None;
                self.error = e;
                false
            }
        }
    }

    #[func]
    fn last_error(&self) -> GString {
        GString::from(self.error.as_str())
    }

    #[func]
    fn reset(&mut self) {
        if let Some(c) = self.c.as_mut() {
            c.reset();
        }
    }

    /// 12 floats a bind: the basis's columns, then the origin.
    #[func]
    fn skin(&mut self, mats: PackedFloat32Array, near: bool) {
        if let Some(c) = self.c.as_mut() {
            c.skin(mats.as_slice(), near);
        }
    }

    #[func]
    fn step(&mut self, steps: i64, wind: Vector3, p: f32) {
        if let Some(c) = self.c.as_mut() {
            c.step(steps as i32, [wind.x, wind.y, wind.z], p);
        }
    }

    #[func]
    fn vertex_data(&self) -> PackedByteArray {
        self.c.as_ref().map(|c| PackedByteArray::from(c.vertex_data())).unwrap_or_default()
    }

    #[func]
    fn positions(&self) -> PackedVector3Array {
        self.c
            .as_ref()
            .map(|c| PackedVector3Array::from(c.cur.iter().map(|p| Vector3::new(p[0], p[1], p[2])).collect::<Vec<_>>()))
            .unwrap_or_default()
    }

    #[func]
    fn bounds(&self) -> Aabb {
        match self.c.as_ref() {
            Some(c) => {
                let (lo, hi) = c.bounds();
                Aabb::new(Vector3::new(lo[0], lo[1], lo[2]), Vector3::new(hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2]))
            }
            None => Aabb::default(),
        }
    }

    /// MSVC srand / the generator's state (the twin parity test seeds both).
    #[func]
    fn seed_rand(&self, seed: i64) {
        cloth::seed_rand(seed as u32);
    }

    #[func]
    fn rand_state(&self) -> i64 {
        cloth::rand_state() as i64
    }
}
