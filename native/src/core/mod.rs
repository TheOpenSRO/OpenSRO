//! The plain-Rust core: no Godot types, unit-tested with `cargo test`, and callable from any
//! binding (the gdext layer in ../gd.rs today; a C ABI for static linking later).
/// The interface number the client checks before it uses the library
/// (client/scripts/pk2/native_assets.gd, NATIVE_API). Bump it with any change to a binding's
/// name, arguments or results, or to what a parser returns: a library whose number differs from
/// the client's is refused, and the client reads in GDScript (round 667's review, M2).
/// 4: rounds 669-671 merged (models, terrain, tables). Each lane said 3 on its own branch, so a
/// library built from any one lane is refused by the merged client (round 669's review).
/// 5: round 677 adds `char_decay_by_code` (SrNativeTables).
/// 6: round 695 adds `ddj_dxt1_has_transparent` (SrNativeParsers, core::dxt).
pub const API: i64 = 6;

pub mod ban;
pub mod blowfish;
pub mod bms;
pub mod bsk;
mod blowfish_constants;
pub mod ddj;
pub mod dxt;
pub mod pk2;
pub mod tables;
pub mod terrain;
