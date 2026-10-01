//! The plain-Rust core: no Godot types, unit-tested with `cargo test`, and callable from any
//! binding (the gdext layer in ../gd.rs today; a C ABI for static linking later).
pub mod blowfish;
mod blowfish_constants;
pub mod ddj;
pub mod pk2;
