//! The model readers' gdext binding (round 669): `SrNativeModels`, over core/bms.rs,
//! core/ban.rs and core/bsk.rs. Like gd.rs it parses nothing itself; each call returns one Dictionary of packed
//! arrays (never a Variant per element), or `{error: String}`, and the client then reads in
//! GDScript. GDScript reaches the class by name (NativeAssets.models()), so the client compiles
//! and runs without the library.
//!
//! Stateless, every method `&self`: one shared instance serves the main thread and the
//! WorkerThreadPool tasks at once (`experimental-threads`, Cargo.toml).

use godot::prelude::*;

use crate::core::{ban, bms, bsk};

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrNativeModels {}

fn v3(p: &[f32; 3]) -> Vector3 {
    Vector3::new(p[0], p[1], p[2])
}

fn strings(v: &[String]) -> PackedStringArray {
    let mut out = PackedStringArray::new();
    out.resize(v.len());
    for (slot, s) in out.as_mut_slice().iter_mut().zip(v) {
        *slot = GString::from(s.as_str());
    }
    out
}

fn error(e: String) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("error", &GString::from(e.as_str()));
    d
}

#[godot_api]
impl SrNativeModels {
    /// BmsReader.parse: the ParsedMesh as packed arrays (BmsReader._from_native has the keys), or
    /// {error}.
    #[func]
    fn bms_parse(&self, data: PackedByteArray) -> VarDictionary {
        let m = match bms::parse(data.as_slice()) {
            Ok(m) => m,
            Err(e) => return error(e),
        };
        let mut d = VarDictionary::new();
        d.set("mesh_name", &GString::from(m.mesh_name.as_str()));
        d.set("material_name", &GString::from(m.material_name.as_str()));
        d.set("positions", &PackedVector3Array::from(m.positions.iter().map(v3).collect::<Vec<_>>()));
        d.set("normals", &PackedVector3Array::from(m.normals.iter().map(v3).collect::<Vec<_>>()));
        d.set("uvs", &PackedVector2Array::from(m.uvs.iter().map(|u| Vector2::new(u[0], u[1])).collect::<Vec<_>>()));
        d.set("extra", &PackedByteArray::from(m.extra));
        d.set("extra_size", m.extra_size as i64);
        if let Some(s) = m.skin {
            d.set("bone0", &PackedInt32Array::from(s.bone0));
            d.set("bone1", &PackedInt32Array::from(s.bone1));
            d.set("weight0", &PackedFloat64Array::from(s.weight0));
            d.set("weight1", &PackedFloat64Array::from(s.weight1));
        }
        d.set("bone_names", &strings(&m.bone_names));
        d.set("object_space_vertices", m.object_space_vertices);
        d.set("indices", &PackedInt32Array::from(m.indices));
        if let Some((lo, hi)) = m.bounds {
            d.set("bounds_min", v3(&lo));
            d.set("bounds_max", v3(&hi));
        }
        d.set("vertex_motion", &PackedFloat32Array::from(m.vertex_motion));
        d.set("vertex_pinned", &PackedByteArray::from(m.vertex_pinned));
        d.set("vertex_links", &PackedInt32Array::from(m.vertex_links));
        d.set("vertex_link_lengths", &PackedFloat32Array::from(m.vertex_link_lengths));
        d.set("vertex_link_order", &PackedInt32Array::from(m.vertex_link_order));
        d.set("cloth_params", &PackedFloat32Array::from(m.cloth_params));
        d
    }

    /// BmsReader.to_arrays' index buffer: the winding reversed.
    #[func]
    fn bms_wound_indices(&self, indices: PackedInt32Array) -> PackedInt32Array {
        PackedInt32Array::from(bms::wound_indices(indices.as_slice()))
    }

    /// BmsReader.to_arrays' {bones: PackedInt32Array, weights: PackedFloat32Array}, four a vertex,
    /// from bms_parse's bone0/bone1/weight0/weight1 and the palette's size; {error} when the four
    /// arrays differ in length.
    #[func]
    fn bms_skin_arrays(&self, bone0: PackedInt32Array, bone1: PackedInt32Array, weight0: PackedFloat64Array, weight1: PackedFloat64Array, palette_size: i64) -> VarDictionary {
        let n = bone0.len();
        if bone1.len() != n || weight0.len() != n || weight1.len() != n {
            return error("bms: skin arrays of different lengths".into());
        }
        let skin = bms::Skin {
            bone0: bone0.as_slice().to_vec(),
            bone1: bone1.as_slice().to_vec(),
            weight0: weight0.as_slice().to_vec(),
            weight1: weight1.as_slice().to_vec(),
        };
        let (bones, weights) = bms::skin_arrays(&skin, palette_size as i32);
        let mut d = VarDictionary::new();
        d.set("bones", &PackedInt32Array::from(bones));
        d.set("weights", &PackedFloat32Array::from(weights));
        d
    }

    /// BskReader.parse: {root_name, root_transform, bone_names, parent_names, transforms (every
    /// bone's raw record, concatenated), offsets (bone i is offsets[i]..offsets[i + 1])}, or {error}.
    #[func]
    fn bsk_parse(&self, data: PackedByteArray) -> VarDictionary {
        let s = match bsk::parse(data.as_slice()) {
            Ok(s) => s,
            Err(e) => return error(e),
        };
        let mut d = VarDictionary::new();
        d.set("root_name", &GString::from(s.root_name.as_str()));
        d.set("root_transform", &PackedByteArray::from(s.root_transform));
        d.set("bone_names", &strings(&s.bone_names));
        d.set("parent_names", &strings(&s.parent_names));
        d.set("transforms", &PackedByteArray::from(s.transforms));
        d.set("offsets", &PackedInt32Array::from(s.offsets));
        d
    }

    /// BanReader.parse: {animation_name, duration_ms, authored_fps, cyclic, key_times,
    /// bone_names, key_counts, rotations (x, y, z, w a key), positions}, or {error}.
    #[func]
    fn ban_parse(&self, data: PackedByteArray) -> VarDictionary {
        let a = match ban::parse(data.as_slice()) {
            Ok(a) => a,
            Err(e) => return error(e),
        };
        let mut d = VarDictionary::new();
        d.set("animation_name", &GString::from(a.animation_name.as_str()));
        d.set("duration_ms", a.duration_ms);
        d.set("authored_fps", a.authored_fps);
        d.set("cyclic", a.cyclic);
        d.set("key_times", &PackedInt32Array::from(a.key_times));
        d.set("bone_names", &strings(&a.bone_names));
        d.set("key_counts", &PackedInt32Array::from(a.key_counts));
        d.set("rotations", &PackedFloat32Array::from(a.rotations));
        d.set("positions", &PackedVector3Array::from(a.positions.iter().map(v3).collect::<Vec<_>>()));
        d
    }
}
