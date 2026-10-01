//! The gdext binding of the terrain and navigation parsers (round 670; the core is
//! core/terrain.rs). One class, `SrNativeTerrain`, stateless, shared by every thread: World3D's
//! terrain prepare calls it from WorkerThreadPool tasks. Each call returns one Dictionary of
//! packed arrays -- `{error: String}` on a file the GDScript reader would refuse, with that
//! reader's own message -- and the GDScript reader rebuilds its ParsedRegion from it
//! (`parse_native` in mapm_reader.gd and nvm_reader.gd; not on the load path, see
//! core/terrain.rs). `lightmap_add` returns the bytes. Never a Variant per element.

use godot::prelude::*;

use crate::core::terrain;

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrNativeTerrain {}

fn err(e: String) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("error", &GString::from(e.as_str()));
    d
}

fn i32s<T: Copy + Into<i32>>(v: &[T]) -> PackedInt32Array {
    PackedInt32Array::from(v.iter().map(|&x| x.into()).collect::<Vec<i32>>())
}

fn f32s(v: Vec<f32>) -> PackedFloat32Array {
    PackedFloat32Array::from(v)
}

#[godot_api]
impl SrNativeTerrain {
    /// MapmReader.parse's decode: {version, vertex_len, flags (PackedInt64Array), environment_ids,
    /// plane_types, wave_ids (PackedInt32Array), heights, plane_heights, height_max, height_min
    /// (PackedFloat32Array), extras (PackedByteArray)} -- see core::terrain::Mapm -- or {error}.
    #[func]
    fn mapm_parse(&self, data: PackedByteArray) -> VarDictionary {
        let m = match terrain::parse_mapm(data.as_slice()) {
            Ok(m) => m,
            Err(e) => return err(e),
        };
        let mut d = VarDictionary::new();
        d.set("version", &GString::from(m.version.as_str()));
        d.set("vertex_len", m.vertex_len as i64);
        d.set("flags", &PackedInt64Array::from(m.flags.iter().map(|&x| x as i64).collect::<Vec<i64>>()));
        d.set("environment_ids", &i32s(&m.environment_ids));
        d.set("plane_types", &i32s(&m.plane_types));
        d.set("wave_ids", &i32s(&m.wave_ids));
        d.set("heights", &f32s(m.heights));
        d.set("extras", &PackedByteArray::from(m.extras));
        d.set("plane_heights", &f32s(m.plane_heights));
        d.set("height_max", &f32s(m.height_max));
        d.set("height_min", &f32s(m.height_min));
        d
    }

    /// NvmReader.parse's decode: the columns of core::terrain::Nvm under the same names, the
    /// edge lists' as `ge_*` (global) and `ie_*` (internal), or {error}.
    #[func]
    fn nvm_parse(&self, data: PackedByteArray) -> VarDictionary {
        let v = match terrain::parse_nvm(data.as_slice()) {
            Ok(v) => v,
            Err(e) => return err(e),
        };
        let mut d = VarDictionary::new();
        d.set("obj_resource_id", &PackedInt64Array::from(v.obj_resource_id.iter().map(|&x| x as i64).collect::<Vec<i64>>()));
        d.set("obj_position", &f32s(v.obj_position));
        d.set("obj_is_static", &i32s(&v.obj_is_static));
        d.set("obj_yaw", &f32s(v.obj_yaw));
        d.set("obj_uid", &i32s(&v.obj_uid));
        d.set("obj_is_big", &PackedByteArray::from(v.obj_is_big));
        d.set("obj_is_struct", &PackedByteArray::from(v.obj_is_struct));
        d.set("obj_region_id", &i32s(&v.obj_region_id));
        d.set("link_start", &PackedInt32Array::from(v.link_start.iter().map(|&x| x as i32).collect::<Vec<i32>>()));
        d.set("links", &i32s(&v.links));
        d.set("walkable_cell_count", v.walkable_cell_count as i64);
        d.set("cell_rects", &f32s(v.cell_rects));
        d.set("cell_start", &PackedInt32Array::from(v.cell_start.iter().map(|&x| x as i32).collect::<Vec<i32>>()));
        d.set("cell_objects", &i32s(&v.cell_objects));
        for (prefix, e) in [("ge_", v.global_edges), ("ie_", v.internal_edges)] {
            d.set(format!("{prefix}lines").as_str(), &f32s(e.lines));
            d.set(format!("{prefix}flags").as_str(), &i32s(&e.flags));
            d.set(format!("{prefix}dir_from").as_str(), &i32s(&e.dir_from));
            d.set(format!("{prefix}dir_to").as_str(), &i32s(&e.dir_to));
            d.set(format!("{prefix}cell_from").as_str(), &i32s(&e.cell_from));
            d.set(format!("{prefix}cell_to").as_str(), &i32s(&e.cell_to));
            d.set(format!("{prefix}region_from").as_str(), &PackedInt32Array::from(e.region_from));
            d.set(format!("{prefix}region_to").as_str(), &PackedInt32Array::from(e.region_to));
        }
        d.set("tile_cell_index", &PackedInt32Array::from(v.tile_cell_index));
        d.set("tile_flags", &i32s(&v.tile_flags));
        d.set("tile_texture_id", &i32s(&v.tile_texture_id));
        d.set("heights", &f32s(v.heights));
        d.set("plane_types", &PackedByteArray::from(v.plane_types));
        d.set("plane_heights", &f32s(v.plane_heights));
        d
    }

    /// MapmTerrainBuilder.lightmap_term's per-byte loop over RGB8 `rgb`, each channel raised by
    /// its add (0..255) and saturated. Empty on input that is not whole RGB8 pixels (the GDScript
    /// loop then runs and reports it).
    #[func]
    fn lightmap_add(&self, rgb: PackedByteArray, r: i64, g: i64, b: i64) -> PackedByteArray {
        let add = [r.clamp(0, 255) as u8, g.clamp(0, 255) as u8, b.clamp(0, 255) as u8];
        match terrain::lightmap_add(rgb.as_slice(), add) {
            Ok(v) => PackedByteArray::from(v),
            Err(_) => PackedByteArray::new(),
        }
    }
}
