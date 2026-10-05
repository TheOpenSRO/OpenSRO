//! The gdext binding of the text-table readers (round 671; core/tables.rs). One `RefCounted`
//! class, `SrNativeTables`, stateless, one method per GDScript function it replaces. Each answers
//! ONE Dictionary of packed arrays -- the reader's kept rows in file order -- or
//! `{"fallback": reason}`, on which the GDScript reader runs its own path (core/tables.rs says
//! which inputs those are). GDScript reaches the class by name through ClassDB
//! (client/scripts/pk2/native_assets.gd, `new_tables`), so nothing names it as a type.
//!
//! Threading: every method takes &self and touches no shared state, so the worker-thread caller
//! (World3D's name-key index task) and the main thread can both use it.

use godot::prelude::*;

use crate::core::tables::{self, Fallback, IdStrings, StrInts, StrStrings};

#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrNativeTables {}

fn strings(v: &[String]) -> PackedStringArray {
    v.iter().map(|s| GString::from(s.as_str())).collect()
}

fn ints(v: Vec<i64>) -> PackedInt64Array {
    PackedInt64Array::from(v)
}

fn floats(v: Vec<f64>) -> PackedFloat64Array {
    PackedFloat64Array::from(v)
}

fn fallback(f: Fallback) -> VarDictionary {
    let mut d = VarDictionary::new();
    d.set("fallback", &GString::from(f.0));
    d
}

fn id_strings(r: Result<IdStrings, Fallback>) -> VarDictionary {
    match r {
        Ok(t) => {
            let mut d = VarDictionary::new();
            d.set("values", &strings(&t.values));
            d.set("ids", &ints(t.ids));
            d
        }
        Err(f) => fallback(f),
    }
}

fn str_strings(r: Result<StrStrings, Fallback>) -> VarDictionary {
    match r {
        Ok(t) => {
            let mut d = VarDictionary::new();
            d.set("keys", &strings(&t.keys));
            d.set("values", &strings(&t.values));
            d
        }
        Err(f) => fallback(f),
    }
}

fn str_ints(r: Result<StrInts, Fallback>) -> VarDictionary {
    match r {
        Ok(t) => {
            let mut d = VarDictionary::new();
            d.set("keys", &strings(&t.keys));
            d.set("values", &ints(t.values));
            d
        }
        Err(f) => fallback(f),
    }
}

#[godot_api]
impl SrNativeTables {
    /// NpcTableReader.parse_positions: {npc_ids, regions, x, y, z}.
    #[func]
    fn npc_positions(&self, data: PackedByteArray) -> VarDictionary {
        match tables::npc_positions(data.as_slice()) {
            Ok(p) => {
                let mut d = VarDictionary::new();
                d.set("npc_ids", &ints(p.npc_ids));
                d.set("regions", &ints(p.regions));
                d.set("x", &floats(p.x));
                d.set("y", &floats(p.y));
                d.set("z", &floats(p.z));
                d
            }
            Err(f) => fallback(f),
        }
    }

    /// NpcTableReader.parse_codes: {ids, values (code names)}.
    #[func]
    fn char_codes(&self, data: PackedByteArray) -> VarDictionary {
        id_strings(tables::char_codes(data.as_slice()))
    }

    /// NpcTableReader.parse_models: {ids, values (.bsr paths)}.
    #[func]
    fn char_models(&self, data: PackedByteArray) -> VarDictionary {
        id_strings(tables::char_models(data.as_slice()))
    }

    /// NpcTableReader.parse_models_by_code: {keys (code names), values (.bsr paths)}.
    #[func]
    fn char_models_by_code(&self, data: PackedByteArray, prefix: GString) -> VarDictionary {
        str_strings(tables::char_models_by_code(data.as_slice(), &prefix.to_string()))
    }

    /// NpcTableReader.parse_org_codes: {keys (code names), values (Org code names)}.
    #[func]
    fn char_org_codes(&self, data: PackedByteArray) -> VarDictionary {
        str_strings(tables::char_org_codes(data.as_slice()))
    }

    /// NpcTableReader.parse_speeds_by_code: {keys, walk, run}.
    #[func]
    fn char_speeds_by_code(&self, data: PackedByteArray, prefix: GString) -> VarDictionary {
        match tables::char_speeds_by_code(data.as_slice(), &prefix.to_string()) {
            Ok(s) => {
                let mut d = VarDictionary::new();
                d.set("keys", &strings(&s.codes));
                d.set("walk", &floats(s.walk));
                d.set("run", &floats(s.run));
                d
            }
            Err(f) => fallback(f),
        }
    }

    /// NpcTableReader.parse_country_by_code: {keys, values}.
    #[func]
    fn char_country_by_code(&self, data: PackedByteArray, prefix: GString) -> VarDictionary {
        str_ints(tables::char_country_by_code(data.as_slice(), &prefix.to_string()))
    }

    /// NpcTableReader.parse_bc_radius_by_code: {keys, values}.
    #[func]
    fn char_bc_radius_by_code(&self, data: PackedByteArray, prefix: GString) -> VarDictionary {
        str_ints(tables::char_bc_radius_by_code(data.as_slice(), &prefix.to_string()))
    }

    /// NpcTableReader.parse_decay_by_code (round 677): {keys, values}.
    #[func]
    fn char_decay_by_code(&self, data: PackedByteArray, prefix: GString) -> VarDictionary {
        str_ints(tables::char_decay_by_code(data.as_slice(), &prefix.to_string()))
    }

    /// NpcTableReader.parse_name_keys (and parse_names before its lookup): {ids, values (SN_ keys)}.
    #[func]
    fn char_name_keys(&self, data: PackedByteArray) -> VarDictionary {
        id_strings(tables::char_name_keys(data.as_slice()))
    }

    /// NpcTableReader.parse_models_by_name before its lookup: {keys (models), values (SN_ keys)}.
    #[func]
    fn char_models_name_keys(&self, data: PackedByteArray) -> VarDictionary {
        str_strings(tables::char_models_name_keys(data.as_slice()))
    }

    /// ItemTableReader.parse's columns (core/tables.rs `Items`; grouped columns hold 4, 8 or 6
    /// entries a row).
    #[func]
    fn items(&self, data: PackedByteArray) -> VarDictionary {
        match tables::items(data.as_slice()) {
            Ok(o) => {
                let mut d = VarDictionary::new();
                d.set("ids", &ints(o.ids));
                d.set("code_names", &strings(&o.code_names));
                d.set("item_names", &strings(&o.item_names));
                d.set("name_strids", &strings(&o.name_strids));
                d.set("icon_paths", &strings(&o.icon_paths));
                d.set("drop_models", &strings(&o.drop_models));
                d.set("models", &strings(&o.models));
                d.set("model_counts", &ints(o.model_counts));
                d.set("max_stacks", &ints(o.max_stacks));
                d.set("sell_prices", &ints(o.sell_prices));
                d.set("keeping_fees", &ints(o.keeping_fees));
                d.set("countries", &ints(o.countries));
                d.set("req_genders", &ints(o.req_genders));
                d.set("durabilities", &ints(o.durabilities));
                d.set("attack_rates", &ints(o.attack_rates));
                d.set("criticals", &ints(o.criticals));
                d.set("ranges", &ints(o.ranges));
                d.set("param1s", &ints(o.param1s));
                d.set("type_ids", &ints(o.type_ids));
                d.set("cash_items", &ints(o.cash_items));
                d.set("bionics", &ints(o.bionics));
                d.set("req_types", &ints(o.req_types));
                d.set("req_levels", &ints(o.req_levels));
                d.set("attacks", &ints(o.attacks));
                d.set("defences", &floats(o.defences));
                d.set("ext_ints", &ints(o.ext_ints));
                d.set("ext_floats", &floats(o.ext_floats));
                d
            }
            Err(f) => fallback(f),
        }
    }

    /// UiTextTable.parse's accepted rows, before its keep-first insert: {keys (tokens), values}.
    #[func]
    fn ui_text_rows(&self, data: PackedByteArray, lang_col: i64) -> VarDictionary {
        str_strings(tables::ui_text_rows(data.as_slice(), lang_col))
    }

    /// SkillEffectReader.parse_all's rows (core/tables.rs `SkillEffects`): {hit_codes, hit_efps,
    /// set_codes, set_groups, set_priorities, set_defenses, set_names, set_name_counts}.
    #[func]
    fn skill_effects(&self, data: PackedByteArray) -> VarDictionary {
        match tables::skill_effects(data.as_slice()) {
            Ok(e) => {
                let mut d = VarDictionary::new();
                d.set("hit_codes", &strings(&e.hit_codes));
                d.set("hit_efps", &strings(&e.hit_efps));
                d.set("set_codes", &strings(&e.set_codes));
                d.set("set_groups", &strings(&e.set_groups));
                d.set("set_priorities", &ints(e.set_priorities));
                d.set("set_defenses", &strings(&e.set_defenses));
                d.set("set_names", &strings(&e.set_names));
                d.set("set_name_counts", &ints(e.set_name_counts));
                d
            }
            Err(f) => fallback(f),
        }
    }

    /// For the parity check (client/tools/table_parity.gd): every row of `_lines(data)` split on
    /// tabs, as {cells: every field in order, row_ends: the end index in `cells` of each row}.
    #[func]
    fn split_rows(&self, data: PackedByteArray, drop_cr: bool) -> VarDictionary {
        match tables::split_rows(data.as_slice(), drop_cr) {
            Ok((cells, ends)) => {
                let mut d = VarDictionary::new();
                d.set("cells", &strings(&cells));
                d.set("row_ends", &ints(ends));
                d
            }
            Err(f) => fallback(f),
        }
    }

    /// For the parity check: Godot's number semantics on each string as ported here --
    /// {valid_int, valid_float, float_ok: PackedByteArray (0/1), ints, floats}.
    #[func]
    fn numbers(&self, texts: PackedStringArray) -> VarDictionary {
        let n = texts.len();
        let (mut vi, mut vf, mut ok) = (Vec::with_capacity(n), Vec::with_capacity(n), Vec::with_capacity(n));
        let (mut iv, mut fv) = (Vec::with_capacity(n), Vec::with_capacity(n));
        for t in texts.as_slice() {
            let s = t.to_string();
            vi.push(u8::from(tables::is_valid_int(&s)));
            vf.push(u8::from(tables::is_valid_float(&s)));
            iv.push(tables::to_int(&s));
            let f = tables::to_float(&s);
            ok.push(u8::from(f.is_some()));
            fv.push(f.unwrap_or(0.0));
        }
        let mut d = VarDictionary::new();
        d.set("valid_int", &PackedByteArray::from(vi));
        d.set("valid_float", &PackedByteArray::from(vf));
        d.set("float_ok", &PackedByteArray::from(ok));
        d.set("ints", &ints(iv));
        d.set("floats", &floats(fv));
        d
    }
}
