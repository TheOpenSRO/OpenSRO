//! The thin gdext (godot-rust) binding over the plain core (core/). Nothing here parses: it
//! converts arguments and hands results back in bulk -- packed arrays and one Dictionary per
//! call -- never a Variant per element. GDScript reaches these classes by name through ClassDB
//! (client/scripts/pk2/native_assets.gd), so the client compiles and runs without the library.
//!
//! Threading: the client calls these from the main thread and from WorkerThreadPool tasks at
//! once (World3D prepares terrain and objects on tasks). Every method takes &self; the archive
//! keeps its own directory cache behind a mutex and reads files positionally, so no call blocks
//! another except on that cache's insert. `experimental-threads` makes the instance binding
//! itself safe to share (Cargo.toml).

use std::sync::atomic::Ordering;
use std::sync::Arc;

use godot::prelude::*;

use crate::core::{ddj, pk2};

struct SrNativeExtension;

#[gdextension]
unsafe impl ExtensionLibrary for SrNativeExtension {}

/// One open pk2 archive (Pk2Reader's native half).
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrNativePk2 {
    archive: Option<Arc<pk2::Archive>>,
    error: String,
}

#[godot_api]
impl SrNativePk2 {
    /// Opens `path` (an absolute file-system path). False, with last_error() set, on failure.
    #[func]
    fn open(&mut self, path: GString) -> bool {
        match pk2::Archive::open(&path.to_string()) {
            Ok(a) => {
                self.archive = Some(Arc::new(a));
                true
            }
            Err(e) => {
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
    fn is_encrypted(&self) -> bool {
        self.archive.as_ref().is_some_and(|a| a.encrypted())
    }

    /// ObjectLoader.find_file: {name, kind (1 folder, 2 file), offset, size} of the first
    /// case-insensitive match, or an empty Dictionary when any segment is missing.
    #[func]
    fn find(&self, path: GString) -> VarDictionary {
        let mut d = VarDictionary::new();
        let Some(a) = &self.archive else { return d };
        if let Some(e) = a.find(&path.to_string()) {
            d.set("name", &GString::from(e.name.as_str()));
            d.set("kind", if e.is_dir { pk2::ENTRY_TYPE_FOLDER as i64 } else { pk2::ENTRY_TYPE_FILE as i64 });
            d.set("offset", e.offset as i64);
            d.set("size", e.size as i64);
        }
        d
    }

    /// A directory's entries by its chain-start offset (the root's is root_offset()), as
    /// {names: PackedStringArray, kinds/offsets/sizes: PackedInt64Array} in on-disk order.
    #[func]
    fn list_dir(&self, offset: i64) -> VarDictionary {
        let mut out = VarDictionary::new();
        let Some(a) = &self.archive else { return out };
        let Ok(dir) = a.dir_at(offset as u64) else { return out };
        let n = dir.entries.len();
        let mut names = PackedStringArray::new();
        names.resize(n);
        let mut kinds = Vec::with_capacity(n);
        let mut offsets = Vec::with_capacity(n);
        let mut sizes = Vec::with_capacity(n);
        {
            let slots = names.as_mut_slice();
            for (i, e) in dir.entries.iter().enumerate() {
                slots[i] = GString::from(e.name.as_str());
                kinds.push(if e.is_dir { pk2::ENTRY_TYPE_FOLDER as i64 } else { pk2::ENTRY_TYPE_FILE as i64 });
                offsets.push(e.offset as i64);
                sizes.push(e.size as i64);
            }
        }
        out.set("names", &names);
        out.set("kinds", &PackedInt64Array::from(kinds));
        out.set("offsets", &PackedInt64Array::from(offsets));
        out.set("sizes", &PackedInt64Array::from(sizes));
        out
    }

    #[func]
    fn root_offset(&self) -> i64 {
        self.archive.as_ref().map_or(0, |a| a.root_offset() as i64)
    }

    /// `size` bytes at `offset` (fewer at the end of the file), as Pk2Reader.read_file.
    #[func]
    fn read(&self, offset: i64, size: i64) -> PackedByteArray {
        let Some(a) = &self.archive else { return PackedByteArray::new() };
        if offset < 0 || size < 0 {
            return PackedByteArray::new();
        }
        match a.read(offset as u64, size as u64) {
            Ok(v) => PackedByteArray::from(v),
            Err(_) => PackedByteArray::new(),
        }
    }

    /// {dir_blocks, dir_cache_hits, file_reads, file_bytes} since open.
    #[func]
    fn stats(&self) -> VarDictionary {
        let mut d = VarDictionary::new();
        if let Some(a) = &self.archive {
            d.set("dir_blocks", a.stats.dir_blocks.load(Ordering::Relaxed) as i64);
            d.set("dir_cache_hits", a.stats.dir_cache_hits.load(Ordering::Relaxed) as i64);
            d.set("file_reads", a.stats.file_reads.load(Ordering::Relaxed) as i64);
            d.set("file_bytes", a.stats.file_bytes.load(Ordering::Relaxed) as i64);
        }
        d
    }
}

/// The native parsers. Stateless: one shared instance serves every thread.
#[derive(GodotClass)]
#[class(base = RefCounted, init)]
pub struct SrNativeParsers {}

#[godot_api]
impl SrNativeParsers {
    #[func]
    fn version(&self) -> GString {
        GString::from(concat!("srrevamp_native ", env!("CARGO_PKG_VERSION")))
    }

    /// DdjReader's uncompressed decode: {rgba: PackedByteArray} or {error: String}.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn ddj_decode_masked(&self, pixels: PackedByteArray, width: i64, height: i64, bpp: i64, r: i64, g: i64, b: i64, a: i64) -> VarDictionary {
        let masks = ddj::Masks { r: r as u64, g: g as u64, b: b as u64, a: a as u64 };
        result(ddj::decode_masked(pixels.as_slice(), width.max(0) as u64, height.max(0) as u64, bpp.max(0) as u64, &masks))
    }

    /// DdjReader's A16B16G16R16F decode: {rgba} or {error}.
    #[func]
    fn ddj_decode_half(&self, pixels: PackedByteArray, width: i64, height: i64) -> VarDictionary {
        result(ddj::decode_half_rgba(pixels.as_slice(), width.max(0) as u64, height.max(0) as u64))
    }
}

fn result(r: Result<Vec<u8>, String>) -> VarDictionary {
    let mut d = VarDictionary::new();
    match r {
        Ok(v) => d.set("rgba", &PackedByteArray::from(v)),
        Err(e) => d.set("error", &GString::from(e.as_str())),
    }
    d
}
