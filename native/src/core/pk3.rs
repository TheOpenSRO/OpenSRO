//! Read-only `.pk3` asset pack reader (round 789). Everything about packs is OURS: retail has only
//! `.pk2`. A `.pk3` is a plain zip archive (`.zip` is accepted too); its paths are the pk2's own
//! paths, matched case-insensitively with `/` and `\` alike (docs/TODO.md, "Asset packs"). The
//! zip layout is PKWARE's APPNOTE.TXT (the public specification): the end-of-central-directory
//! record, its zip64 form, the central directory and the local headers. The GDScript twin is
//! client/scripts/pk2/pk3_reader.gd; the two answer alike (client/scripts/pk2/pk3_reader_test.gd
//! holds them to it).
//!
//! What it does:
//! - opens by reading the central directory once (zip64 included: a converted Data.pk2 is 3.8 GB,
//!   MEASURED on the box) and indexes every file and every folder by its lower-cased path;
//! - reads stored entries positionally, without unpacking, as pk2.rs reads a pk2 file;
//! - inflates deflated entries with miniz_oxide into a buffer of exactly the declared size and
//!   checks the CRC-32;
//! - every call takes &self: threads share no file cursor (pread / seek_read) and the index is
//!   read-only after open.
//!
//! Safety (OURS, docs/TODO.md's "Safety" item): an entry is refused -- left out of the index,
//! counted, and named in `refused` -- when its name escapes the archive (`..`, an absolute path, a
//! drive letter or any `:`, a NUL, an empty segment), when it is encrypted or uses a method other
//! than stored (0) or deflate (8), when it is a symbolic link (a Unix-made entry's mode), when it
//! declares more than MAX_ENTRY_BYTES, when it declares more than MAX_RATIO times its packed size
//! (over 64 bytes), or when its data would lie past the end of the file. A pack whose entries
//! together declare more than MAX_RATIO times the pack file's size is not opened at all (many
//! directory records over one stream: the "better zip bomb"). These are the rules of
//! docs/protocol/asset_packs.md ("Safety"), which the Go reader (server/internal/assetfs) follows
//! too. A read never produces more than the declared size (the output buffer is that size), so a
//! bomb that lies about its size fails to inflate instead of filling memory.

use std::collections::HashMap;
use std::fs::File;
use std::sync::atomic::{AtomicU64, Ordering};

use super::pk2::{lower, path_segments, read_full_at, ENTRY_TYPE_FILE, ENTRY_TYPE_FOLDER};

/// The largest entry a pack may hold, uncompressed (OURS): 256 MiB, twelve times the largest
/// file in the retail archives (MEASURED 2026-10-16: Data.pk2's navmesh\ainavdata_32773.dat,
/// 21,352,219 bytes; Map 1,048,724; Media 5,357,440; Music 4,454,280; Particles 1,398,276).
pub const MAX_ENTRY_BYTES: u64 = 256 << 20;
/// The ratio cap, unpacked to packed, per entry (over RATIO_MIN_SIZE bytes) and per pack (all
/// entries against the file's size): 1100:1 (asset_packs.md, "Safety"). Deflate cannot pack better
/// than about 1032:1 (zlib's technical notes), and retail itself reaches 974.6:1 (MEASURED by lane
/// G: Media.pk2's script\image\qno_script_background_white.ddj), so no honest entry passes it.
pub const MAX_RATIO: u64 = 1100;
const RATIO_MIN_SIZE: u64 = 64;
/// A bound on the central directory (OURS): 4 million entries, 1 GiB of records. The largest
/// retail archive holds 73,139 files (Data.pk2, MEASURED).
pub const MAX_ENTRIES: u64 = 4_000_000;
const MAX_CD_BYTES: u64 = 1 << 30;
/// How many refusals are kept by name (the rest are counted).
const REFUSED_KEPT: usize = 64;

const SIG_LOCAL: u32 = 0x0403_4b50;
const SIG_CENTRAL: u32 = 0x0201_4b50;
const SIG_EOCD: u32 = 0x0605_4b50;
const SIG_EOCD64: u32 = 0x0606_4b50;
const SIG_LOCATOR64: u32 = 0x0706_4b50;
const EOCD_LEN: usize = 22;
const CENTRAL_LEN: usize = 46;
const LOCAL_LEN: usize = 30;
const FLAG_ENCRYPTED: u16 = 0x0001;
const FLAG_UTF8: u16 = 0x0800;
pub const METHOD_STORED: u16 = 0;
pub const METHOD_DEFLATE: u16 = 8;

/// CRC-32 (IEEE 802.3, reflected 0xEDB88320), as zip stores it: crc32fast (SIMD where the CPU
/// has it). A byte-at-a-time table cost more than the inflate itself: MEASURED, round 789, every
/// file of the converted Data.pk3 read natively in 15.1 s with it against 11.0 s through Godot's
/// zlib (pk3_parity.gd); the numbers with crc32fast are in docs/rounds/r789k.md.
pub fn crc32(data: &[u8]) -> u32 {
    crc32fast::hash(data)
}

fn u16_at(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn u32_at(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn u64_at(b: &[u8], o: usize) -> u64 {
    let mut a = [0u8; 8];
    a.copy_from_slice(&b[o..o + 8]);
    u64::from_le_bytes(a)
}

/// The name as the client sees it: UTF-8 when the entry says so (general purpose flag bit 11),
/// else each byte one Latin-1 code point -- the pk2 reader's own decoding, so a converted
/// archive's names come back as the pk2 gave them either way.
fn decode_name(raw: &[u8], flags: u16) -> String {
    if flags & FLAG_UTF8 != 0 {
        String::from_utf8_lossy(raw).into_owned()
    } else {
        raw.iter().map(|&c| c as char).collect()
    }
}

/// A pack path made plain: `\` -> `/`, a trailing `/` marks a folder. Err with why when the name
/// could escape the archive or is not a plain relative path.
pub fn safe_path(name: &str) -> Result<(String, bool), &'static str> {
    if name.is_empty() {
        return Err("empty name");
    }
    if name.contains('\0') {
        return Err("NUL in the name");
    }
    let p = name.replace('\\', "/");
    if p.starts_with('/') {
        return Err("absolute path");
    }
    if p.contains(':') {
        return Err("drive letter or ':' in the name");
    }
    let is_dir = p.ends_with('/');
    let body = if is_dir { &p[..p.len() - 1] } else { &p[..] };
    if body.is_empty() {
        return Err("empty name");
    }
    for seg in body.split('/') {
        match seg {
            "" => return Err("empty path segment"),
            "." | ".." => return Err("'.' or '..' segment"),
            _ => {}
        }
    }
    Ok((body.to_string(), is_dir))
}

/// One central-directory record as read, before the checks.
struct Record {
    name: String,
    flags: u16,
    method: u16,
    crc: u32,
    csize: u64,
    size: u64,
    local: u64,
    symlink: bool,
}

#[derive(Clone, Debug)]
pub struct FileEntry {
    /// The last segment, as written.
    pub name: String,
    /// The whole path with `/`, as written.
    pub path: String,
    pub method: u16,
    pub crc: u32,
    pub csize: u64,
    pub size: u64,
    pub local: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Child {
    File(u32),
    Dir(u32),
}

#[derive(Debug)]
pub struct DirNode {
    pub name: String,
    pub children: Vec<Child>,
}

/// What `find` answers: pk2::Entry's shape, the id standing where pk2 has an offset (a file's
/// index, or a folder's -- the root's is 0).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Found {
    pub name: String,
    pub is_dir: bool,
    pub id: u64,
    pub size: u64,
}

#[derive(Default)]
pub struct Stats {
    pub file_reads: AtomicU64,
    pub file_bytes: AtomicU64,
    pub inflated: AtomicU64,
}

pub struct Pk3 {
    file: File,
    len: u64,
    pub zip64: bool,
    pub files: Vec<FileEntry>,
    pub dirs: Vec<DirNode>,
    /// Lower-cased path ("a/b/c.ddj"; "" is the root) -> what it names.
    index: HashMap<String, Child>,
    /// "name: why" for the first REFUSED_KEPT refusals, in central-directory order.
    pub refused: Vec<String>,
    pub refused_count: u64,
    pub stats: Stats,
}

impl Pk3 {
    pub fn open(path: &str) -> Result<Pk3, String> {
        let file = File::open(path).map_err(|e| format!("pk3: could not open {path}: {e}"))?;
        let len = file.metadata().map_err(|e| format!("pk3: reading {path}: {e}"))?.len();
        Pk3::from_file(file, len).map_err(|e| format!("pk3: {path}: {e}"))
    }

    fn from_file(file: File, len: u64) -> Result<Pk3, String> {
        if len < EOCD_LEN as u64 {
            return Err("too small to be a zip archive".into());
        }
        // The end record sits in the last 22 + 65,535 (its comment) bytes.
        let tail_len = len.min(EOCD_LEN as u64 + 0xFFFF) as usize;
        let tail_off = len - tail_len as u64;
        let mut tail = vec![0u8; tail_len];
        read_full_at(&file, &mut tail, tail_off).map_err(|e| e.to_string())?;
        let mut eocd_at = None;
        let mut i = tail_len - EOCD_LEN;
        loop {
            if u32_at(&tail, i) == SIG_EOCD && i + EOCD_LEN + u16_at(&tail, i + 20) as usize <= tail_len {
                eocd_at = Some(i);
                break;
            }
            if i == 0 {
                break;
            }
            i -= 1;
        }
        let e = eocd_at.ok_or_else(|| "not a zip archive (no end of central directory record)".to_string())?;
        let eocd_abs = tail_off + e as u64;
        let mut disk = u16_at(&tail, e + 4) as u32;
        let mut cd_disk = u16_at(&tail, e + 6) as u32;
        let mut total = u16_at(&tail, e + 10) as u64;
        let mut cd_size = u32_at(&tail, e + 12) as u64;
        let mut cd_off = u32_at(&tail, e + 16) as u64;
        // The zip64 locator, when present, sits right before the end record.
        let mut zip64 = false;
        if eocd_abs >= 20 {
            let mut loc = [0u8; 20];
            read_full_at(&file, &mut loc, eocd_abs - 20).map_err(|e| e.to_string())?;
            if u32_at(&loc, 0) == SIG_LOCATOR64 {
                let rec_off = u64_at(&loc, 8);
                let mut rec = [0u8; 56];
                if rec_off.checked_add(56).is_none_or(|end| end > eocd_abs) {
                    return Err("zip64 end record lies outside the file".into());
                }
                read_full_at(&file, &mut rec, rec_off).map_err(|e| e.to_string())?;
                if u32_at(&rec, 0) != SIG_EOCD64 {
                    return Err("zip64 locator points at no zip64 end record".into());
                }
                zip64 = true;
                disk = u32_at(&rec, 16);
                cd_disk = u32_at(&rec, 20);
                total = u64_at(&rec, 32);
                cd_size = u64_at(&rec, 40);
                cd_off = u64_at(&rec, 48);
            }
        }
        if disk != 0 || cd_disk != 0 {
            return Err("split (multi-disk) archives are not supported".into());
        }
        if total > MAX_ENTRIES || cd_size > MAX_CD_BYTES {
            return Err(format!("central directory too large ({total} entries, {cd_size} bytes)"));
        }
        if cd_off.checked_add(cd_size).is_none_or(|end| end > eocd_abs) {
            return Err("central directory lies outside the file".into());
        }
        let mut cd = Vec::new();
        cd.try_reserve_exact(cd_size as usize).map_err(|_| "cannot allocate the central directory".to_string())?;
        cd.resize(cd_size as usize, 0);
        let got = read_full_at(&file, &mut cd, cd_off).map_err(|e| e.to_string())?;
        if got != cd.len() {
            return Err("central directory is truncated".into());
        }

        let mut pk3 = Pk3 {
            file,
            len,
            zip64,
            files: Vec::new(),
            dirs: vec![DirNode { name: String::new(), children: Vec::new() }],
            index: HashMap::new(),
            refused: Vec::new(),
            refused_count: 0,
            stats: Stats::default(),
        };
        pk3.index.insert(String::new(), Child::Dir(0));
        let mut p = 0usize;
        let mut records = Vec::new();
        let mut declared = 0u64;
        for _ in 0..total {
            if p + CENTRAL_LEN > cd.len() || u32_at(&cd, p) != SIG_CENTRAL {
                return Err("central directory is truncated or corrupt".into());
            }
            let made_by = u16_at(&cd, p + 4);
            let flags = u16_at(&cd, p + 8);
            let method = u16_at(&cd, p + 10);
            let crc = u32_at(&cd, p + 16);
            let mut csize = u32_at(&cd, p + 20) as u64;
            let mut size = u32_at(&cd, p + 24) as u64;
            let nlen = u16_at(&cd, p + 28) as usize;
            let xlen = u16_at(&cd, p + 30) as usize;
            let clen = u16_at(&cd, p + 32) as usize;
            let ext_attr = u32_at(&cd, p + 38);
            let mut local = u32_at(&cd, p + 42) as u64;
            let rec_end = p + CENTRAL_LEN + nlen + xlen + clen;
            if rec_end > cd.len() {
                return Err("central directory is truncated or corrupt".into());
            }
            let raw_name = &cd[p + CENTRAL_LEN..p + CENTRAL_LEN + nlen];
            let extra = &cd[p + CENTRAL_LEN + nlen..p + CENTRAL_LEN + nlen + xlen];
            // The zip64 extended information field: each saturated value, in this order.
            let mut x = 0usize;
            while x + 4 <= extra.len() {
                let id = u16_at(extra, x);
                let sz = u16_at(extra, x + 2) as usize;
                let body = &extra[x + 4..(x + 4 + sz).min(extra.len())];
                if id == 0x0001 {
                    let mut q = 0usize;
                    for v in [&mut size, &mut csize, &mut local] {
                        if *v == 0xFFFF_FFFF && q + 8 <= body.len() {
                            *v = u64_at(body, q);
                            q += 8;
                        }
                    }
                }
                x += 4 + sz;
            }
            let name = decode_name(raw_name, flags);
            // A Unix-made entry (the high byte of "version made by" is 3) keeps its st_mode in the
            // external attributes' high 16 bits; S_IFLNK is 0o120000.
            let symlink = made_by >> 8 == 3 && (ext_attr >> 16) & 0o170000 == 0o120000;
            declared = declared.saturating_add(size);
            records.push(Record { name, flags, method, crc, csize, size, local, symlink });
            p = rec_end;
        }
        if declared > MAX_RATIO.saturating_mul(len) {
            return Err(format!("its entries unpack to {declared} bytes from a {len}-byte file (over {MAX_RATIO}:1): a zip bomb"));
        }
        for r in records {
            pk3.add(r);
        }
        Ok(pk3)
    }

    fn refuse(&mut self, name: &str, why: &str) {
        self.refused_count += 1;
        if self.refused.len() < REFUSED_KEPT {
            self.refused.push(format!("{name}: {why}"));
        }
    }

    /// The folder for `segs[..n]`, made (with its parents) when missing; Err when a file holds a
    /// name on the way.
    fn ensure_dir(&mut self, segs: &[&str]) -> Result<u32, &'static str> {
        let mut cur = 0u32;
        let mut key = String::new();
        for seg in segs {
            if !key.is_empty() {
                key.push('/');
            }
            key.push_str(&lower(seg));
            match self.index.get(&key) {
                Some(Child::Dir(d)) => cur = *d,
                Some(Child::File(_)) => return Err("a folder on its path is a file"),
                None => {
                    let id = self.dirs.len() as u32;
                    self.dirs.push(DirNode { name: seg.to_string(), children: Vec::new() });
                    self.dirs[cur as usize].children.push(Child::Dir(id));
                    self.index.insert(key.clone(), Child::Dir(id));
                    cur = id;
                }
            }
        }
        Ok(cur)
    }

    fn add(&mut self, r: Record) {
        let Record { name, flags, method, crc, csize, size, local, symlink } = r;
        let (path, is_dir) = match safe_path(&name) {
            Ok(v) => v,
            Err(why) => return self.refuse(&name, why),
        };
        let segs: Vec<&str> = path.split('/').collect();
        if is_dir {
            if let Err(why) = self.ensure_dir(&segs) {
                self.refuse(&name, why);
            }
            return;
        }
        let why = if flags & FLAG_ENCRYPTED != 0 {
            Some("encrypted")
        } else if method != METHOD_STORED && method != METHOD_DEFLATE {
            Some("compression method is neither stored nor deflate")
        } else if symlink {
            Some("a symbolic link")
        } else if size > MAX_ENTRY_BYTES {
            Some("larger than the 256 MiB entry cap")
        } else if method == METHOD_STORED && csize != size {
            Some("stored entry whose sizes differ")
        } else if size > RATIO_MIN_SIZE && size > csize.saturating_mul(MAX_RATIO) {
            Some("unpacks to more than 1100 times its packed size: a zip bomb")
        } else if local.checked_add(LOCAL_LEN as u64 + csize).is_none_or(|end| end > self.len) {
            Some("its data lies past the end of the file")
        } else {
            None
        };
        if let Some(why) = why {
            return self.refuse(&name, why);
        }
        let key = lower(&path);
        match self.index.get(&key) {
            Some(Child::File(_)) => return self.refuse(&name, "duplicate name (the first is kept)"),
            Some(Child::Dir(_)) => return self.refuse(&name, "the same name is a folder"),
            None => {}
        }
        let parent = match self.ensure_dir(&segs[..segs.len() - 1]) {
            Ok(d) => d,
            Err(why) => return self.refuse(&name, why),
        };
        let id = self.files.len() as u32;
        self.files.push(FileEntry {
            name: segs[segs.len() - 1].to_string(),
            path: path.clone(),
            method,
            crc,
            csize,
            size,
            local,
        });
        self.dirs[parent as usize].children.push(Child::File(id));
        self.index.insert(key, Child::File(id));
    }

    /// ObjectLoader.find_file's answer: `\` or `/` separated, case-insensitive, empty segments
    /// skipped; None for an unsafe or empty path (pk2::path_segments, as the pk2 lookup).
    pub fn find(&self, path: &str) -> Option<Found> {
        let key = lower(&path_segments(path)?.join("/"));
        match self.index.get(&key)? {
            Child::File(i) => {
                let f = &self.files[*i as usize];
                Some(Found { name: f.name.clone(), is_dir: false, id: *i as u64, size: f.size })
            }
            Child::Dir(d) => Some(Found { name: self.dirs[*d as usize].name.clone(), is_dir: true, id: *d as u64, size: 0 }),
        }
    }

    /// A folder's entries in the order the central directory first named them.
    pub fn list_dir(&self, id: u64) -> Vec<Found> {
        let Some(d) = self.dirs.get(id as usize) else { return Vec::new() };
        d.children
            .iter()
            .map(|c| match *c {
                Child::File(i) => {
                    let f = &self.files[i as usize];
                    Found { name: f.name.clone(), is_dir: false, id: i as u64, size: f.size }
                }
                Child::Dir(j) => Found { name: self.dirs[j as usize].name.clone(), is_dir: true, id: j as u64, size: 0 },
            })
            .collect()
    }

    /// Every file's path with `/`, as written ("Prim/Mtrl/Foo.ddj"), in central-directory order.
    pub fn paths(&self) -> Vec<String> {
        self.files.iter().map(|f| f.path.clone()).collect()
    }

    /// A file's bytes: stored ones read straight from the file, deflated ones inflated into a
    /// buffer of the declared size and checked against the CRC-32.
    pub fn read(&self, id: u64) -> Result<Vec<u8>, String> {
        let f = self.files.get(id as usize).ok_or_else(|| format!("pk3: no entry {id}"))?;
        let mut lh = [0u8; LOCAL_LEN];
        if read_full_at(&self.file, &mut lh, f.local).map_err(|e| e.to_string())? != LOCAL_LEN || u32_at(&lh, 0) != SIG_LOCAL {
            return Err(format!("pk3: {}: no local header at {}", f.path, f.local));
        }
        let data = f.local + LOCAL_LEN as u64 + u16_at(&lh, 26) as u64 + u16_at(&lh, 28) as u64;
        if data.checked_add(f.csize).is_none_or(|end| end > self.len) {
            return Err(format!("pk3: {}: data lies past the end of the file", f.path));
        }
        if f.size == 0 {
            // Nothing to inflate (and nothing to check: the CRC-32 of no bytes is 0). The GDScript
            // twin answers the same; Godot's decompress refuses a zero-sized buffer.
            return Ok(Vec::new());
        }
        let mut comp = alloc(f.csize).map_err(|e| format!("pk3: {}: {e}", f.path))?;
        let got = read_full_at(&self.file, &mut comp, data).map_err(|e| e.to_string())?;
        if got != comp.len() {
            return Err(format!("pk3: {}: truncated", f.path));
        }
        self.stats.file_reads.fetch_add(1, Ordering::Relaxed);
        self.stats.file_bytes.fetch_add(f.size, Ordering::Relaxed);
        if f.method == METHOD_STORED {
            return Ok(comp);
        }
        let mut out = alloc(f.size).map_err(|e| format!("pk3: {}: {e}", f.path))?;
        let n = miniz_oxide::inflate::decompress_slice_iter_to_slice(&mut out, std::iter::once(comp.as_slice()), false, true)
            .map_err(|s| format!("pk3: {}: inflate failed ({s:?}) -- larger than its declared {} bytes, or corrupt", f.path, f.size))?;
        if n as u64 != f.size {
            return Err(format!("pk3: {}: inflates to {n} bytes, not the declared {}", f.path, f.size));
        }
        if crc32(&out) != f.crc {
            return Err(format!("pk3: {}: CRC-32 mismatch", f.path));
        }
        self.stats.inflated.fetch_add(1, Ordering::Relaxed);
        Ok(out)
    }

    pub fn kind_of(is_dir: bool) -> u8 {
        if is_dir {
            ENTRY_TYPE_FOLDER
        } else {
            ENTRY_TYPE_FILE
        }
    }
}

/// A zeroed buffer of `n` bytes whose allocation may fail without aborting the process (round
/// 667's review, M3: an untrusted size must not abort).
fn alloc(n: u64) -> Result<Vec<u8>, String> {
    let n = usize::try_from(n).map_err(|_| "entry too large".to_string())?;
    let mut v = Vec::new();
    v.try_reserve_exact(n).map_err(|_| format!("cannot allocate {n} bytes"))?;
    v.resize(n, 0);
    Ok(v)
}

/// Writes synthetic zips: the tests here and nothing else (the client's tests write their own in
/// GDScript, pk3_test_zip.gd). Never real game data.
pub mod synth {
    use super::*;

    pub struct Item {
        pub name: Vec<u8>,
        pub data: Vec<u8>,
        pub deflate: bool,
        pub flags: u16,
        /// Overrides the declared uncompressed size (a bomb's lie).
        pub declared_size: Option<u64>,
        pub crc: Option<u32>,
        pub method: Option<u16>,
        /// A Unix st_mode for the external attributes (made on Unix): 0o120777 is a symlink.
        pub unix_mode: Option<u32>,
        /// More central records pointing at this one entry's data.
        pub copies: usize,
    }

    impl Item {
        pub fn new(name: &str, data: &[u8], deflate: bool) -> Item {
            Item {
                name: name.as_bytes().to_vec(),
                data: data.to_vec(),
                deflate,
                flags: 0,
                declared_size: None,
                crc: None,
                method: None,
                unix_mode: None,
                copies: 0,
            }
        }
    }

    fn p16(v: &mut Vec<u8>, x: u16) {
        v.extend_from_slice(&x.to_le_bytes());
    }
    fn p32(v: &mut Vec<u8>, x: u32) {
        v.extend_from_slice(&x.to_le_bytes());
    }
    fn p64(v: &mut Vec<u8>, x: u64) {
        v.extend_from_slice(&x.to_le_bytes());
    }

    /// A zip of `items`; with `zip64`, every size and offset goes through the zip64 extra field
    /// and the zip64 end records, as a writer does for an archive past 4 GiB.
    pub fn build(items: &[Item], zip64: bool) -> Vec<u8> {
        let mut out = Vec::new();
        let mut central = Vec::new();
        let mut n = 0u64;
        for it in items {
            let body = if it.deflate { miniz_oxide::deflate::compress_to_vec(&it.data, 6) } else { it.data.clone() };
            let method = it.method.unwrap_or(if it.deflate { METHOD_DEFLATE } else { METHOD_STORED });
            let crc = it.crc.unwrap_or_else(|| crc32(&it.data));
            let size = it.declared_size.unwrap_or(it.data.len() as u64);
            let csize = body.len() as u64;
            let local = out.len() as u64;
            let sat = |v: u64| if zip64 { 0xFFFF_FFFFu32 } else { v as u32 };
            let mut x64 = Vec::new();
            if zip64 {
                p16(&mut x64, 1);
                p16(&mut x64, 24);
                p64(&mut x64, size);
                p64(&mut x64, csize);
                p64(&mut x64, local);
            }
            // Local header.
            p32(&mut out, SIG_LOCAL);
            p16(&mut out, if zip64 { 45 } else { 20 });
            p16(&mut out, it.flags);
            p16(&mut out, method);
            p32(&mut out, 0);
            p32(&mut out, crc);
            p32(&mut out, sat(csize));
            p32(&mut out, sat(size));
            p16(&mut out, it.name.len() as u16);
            p16(&mut out, if zip64 { 20 } else { 0 });
            out.extend_from_slice(&it.name);
            if zip64 {
                p16(&mut out, 1);
                p16(&mut out, 16);
                p64(&mut out, size);
                p64(&mut out, csize);
            }
            out.extend_from_slice(&body);
            // Central record(s): `copies` more of them point at the same local entry, named
            // "<name>.<i>" (the overlapping "better zip bomb").
            for c in 0..=it.copies {
                let mut name = it.name.clone();
                if c > 0 {
                    name.extend_from_slice(format!(".{c}").as_bytes());
                }
                let made_by: u16 = if it.unix_mode.is_some() { 3 << 8 | 20 } else if zip64 { 45 } else { 20 };
                p32(&mut central, SIG_CENTRAL);
                p16(&mut central, made_by);
                p16(&mut central, if zip64 { 45 } else { 20 });
                p16(&mut central, it.flags);
                p16(&mut central, method);
                p32(&mut central, 0);
                p32(&mut central, crc);
                p32(&mut central, sat(csize));
                p32(&mut central, sat(size));
                p16(&mut central, name.len() as u16);
                p16(&mut central, x64.len() as u16);
                p16(&mut central, 0);
                p16(&mut central, 0);
                p16(&mut central, 0);
                p32(&mut central, it.unix_mode.map_or(0, |m| m << 16));
                p32(&mut central, sat(local));
                central.extend_from_slice(&name);
                central.extend_from_slice(&x64);
                n += 1;
            }
        }
        let cd_off = out.len() as u64;
        let cd_size = central.len() as u64;
        out.extend_from_slice(&central);
        if zip64 {
            let rec = out.len() as u64;
            p32(&mut out, SIG_EOCD64);
            p64(&mut out, 44);
            p16(&mut out, 45);
            p16(&mut out, 45);
            p32(&mut out, 0);
            p32(&mut out, 0);
            p64(&mut out, n);
            p64(&mut out, n);
            p64(&mut out, cd_size);
            p64(&mut out, cd_off);
            p32(&mut out, SIG_LOCATOR64);
            p32(&mut out, 0);
            p64(&mut out, rec);
            p32(&mut out, 1);
        }
        p32(&mut out, SIG_EOCD);
        p16(&mut out, 0);
        p16(&mut out, 0);
        p16(&mut out, if zip64 { 0xFFFF } else { n as u16 });
        p16(&mut out, if zip64 { 0xFFFF } else { n as u16 });
        p32(&mut out, if zip64 { 0xFFFF_FFFF } else { cd_size as u32 });
        p32(&mut out, if zip64 { 0xFFFF_FFFF } else { cd_off as u32 });
        p16(&mut out, 0);
        out
    }
}

#[cfg(test)]
mod tests {
    use super::synth::*;
    use super::*;
    use std::sync::Arc;

    struct Tmp(std::path::PathBuf);
    impl Tmp {
        fn with(bytes: &[u8]) -> Tmp {
            use std::sync::atomic::AtomicUsize;
            static N: AtomicUsize = AtomicUsize::new(0);
            let n = N.fetch_add(1, Ordering::Relaxed);
            let p = std::env::temp_dir().join(format!("opensro_pk3_test_{}_{n}.pk3", std::process::id()));
            std::fs::write(&p, bytes).unwrap();
            Tmp(p)
        }
        fn open(&self) -> Result<Pk3, String> {
            Pk3::open(self.0.to_str().unwrap())
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
        }
    }

    fn text(n: usize) -> Vec<u8> {
        (0..n).map(|i| b"OpenSRO pack test "[i % 18]).collect()
    }

    fn sample() -> Vec<Item> {
        vec![
            Item::new("Prim/Mtrl/Foo.DDJ", &text(5000), false),
            Item::new("prim\\mtrl\\bar.txt", &text(7000), true),
            Item::new("textdata/", b"", false),
            Item::new("textdata/a.txt", b"", true),
            Item::new("readme.txt", b"hello", false),
        ]
    }

    #[test]
    fn reads_stored_and_deflated_with_and_without_zip64() {
        for zip64 in [false, true] {
            let t = Tmp::with(&build(&sample(), zip64));
            let a = t.open().unwrap();
            assert_eq!(a.zip64, zip64);
            assert_eq!(a.refused_count, 0, "{:?}", a.refused);
            let foo = a.find("prim\\MTRL\\foo.ddj").unwrap();
            assert_eq!((foo.name.as_str(), foo.is_dir, foo.size), ("Foo.DDJ", false, 5000));
            assert_eq!(a.read(foo.id).unwrap(), text(5000));
            let bar = a.find("PRIM/mtrl/BAR.TXT").unwrap();
            assert_eq!(a.read(bar.id).unwrap(), text(7000));
            assert!(a.files[bar.id as usize].csize < 7000, "deflated");
            let empty = a.find("textdata\\a.txt").unwrap();
            assert_eq!(a.read(empty.id).unwrap(), Vec::<u8>::new());
            let mtrl = a.find("prim/mtrl").unwrap();
            assert!(mtrl.is_dir);
            let names: Vec<String> = a.list_dir(mtrl.id).into_iter().map(|f| f.name).collect();
            assert_eq!(names, ["Foo.DDJ", "bar.txt"], "the first spelling of a folder is kept; order is the directory's");
            let root: Vec<String> = a.list_dir(0).into_iter().map(|f| f.name).collect();
            assert_eq!(root, ["Prim", "textdata", "readme.txt"]);
            assert!(a.find("").is_none());
            assert!(a.find("/prim//mtrl\\").unwrap().is_dir, "empty segments are skipped");
            assert!(a.find("prim/../readme.txt").is_none() && a.find("prim/./mtrl").is_none() && a.find("c:readme.txt").is_none(), "an unsafe lookup finds nothing");
            assert!(a.find("missing.txt").is_none());
            assert_eq!(a.paths(), ["Prim/Mtrl/Foo.DDJ", "prim/mtrl/bar.txt", "textdata/a.txt", "readme.txt"]);
        }
    }

    #[test]
    fn refuses_names_that_escape() {
        let mut items = vec![];
        for n in ["../evil.txt", "a/../../b.txt", "/etc/passwd", "\\abs.txt", "C:/win.ini", "c:evil", "a//b.txt", "./x.txt", "ok/fine.txt"] {
            items.push(Item::new(n, b"x", false));
        }
        items.push(Item { name: b"nul\0.txt".to_vec(), ..Item::new("", b"x", false) });
        let t = Tmp::with(&build(&items, false));
        let a = t.open().unwrap();
        assert_eq!(a.refused_count, 9, "{:?}", a.refused);
        assert_eq!(a.paths(), ["ok/fine.txt"]);
        assert!(a.refused[0].starts_with("../evil.txt: "));
    }

    #[test]
    fn stops_bombs_and_lies() {
        let zeros = vec![0u8; 1 << 20];
        let mut lie = Item::new("lie.bin", &zeros, true);
        lie.declared_size = Some(1 << 10); // inflates past what it declares
        let mut huge = Item::new("huge.bin", b"x", false);
        huge.declared_size = Some(MAX_ENTRY_BYTES + 1);
        let mut ratio = Item::new("ratio.bin", b"abc", true);
        ratio.declared_size = Some(200 << 20); // 200 MiB from a few bytes
        let mut crc = Item::new("crc.bin", &text(100), true);
        crc.crc = Some(1);
        let mut enc = Item::new("enc.bin", b"x", false);
        enc.flags = FLAG_ENCRYPTED;
        let mut bz = Item::new("bzip2.bin", b"x", false);
        bz.method = Some(12);
        let ok = Item::new("zeros.bin", &zeros, true);
        let mut link = Item::new("link.txt", b"/etc/passwd", false);
        link.unix_mode = Some(0o120777);
        let mut plain_unix = Item::new("unix.txt", b"a plain file", false);
        plain_unix.unix_mode = Some(0o100644);
        // A stored filler, so the whole pack stays under its 1100:1 (the declared bombs above
        // add up to 456 MiB).
        let filler = Item::new("filler.bin", &text(512 << 10), false);
        let t = Tmp::with(&build(&[lie, huge, ratio, crc, enc, bz, ok, link, plain_unix, filler], false));
        let a = t.open().unwrap();
        assert_eq!(a.refused_count, 5, "{:?}", a.refused);
        assert!(a.find("link.txt").is_none() && a.find("unix.txt").is_some(), "a symlink entry is refused, a Unix file is not");
        let ok = a.find("zeros.bin").unwrap();
        assert_eq!(a.read(ok.id).unwrap(), zeros, "a real 1:1000 file still reads");
        let lie = a.find("lie.bin").unwrap();
        assert!(a.read(lie.id).unwrap_err().contains("inflate failed"));
        let crc = a.find("crc.bin").unwrap();
        assert!(a.read(crc.id).unwrap_err().contains("CRC"));
        for gone in ["huge.bin", "ratio.bin", "enc.bin", "bzip2.bin"] {
            assert!(a.find(gone).is_none(), "{gone} refused");
        }
    }

    /// The overlapping "better zip bomb": 1,200 directory records over one 1 MiB stream. Each
    /// entry is under 1100:1; the pack is not, and is not opened.
    #[test]
    fn refuses_a_pack_over_its_whole_ratio() {
        let mut many = Item::new("zeros.bin", &vec![0u8; 1 << 20], true);
        many.copies = 1199;
        let t = Tmp::with(&build(&[many], false));
        assert!(t.open().err().unwrap().contains("zip bomb"));
        // Shared data is not refused by itself: four records over one barely compressible stream.
        let mut x = 12345u32;
        let noise: Vec<u8> = (0..65536)
            .map(|_| {
                x = x.wrapping_mul(1_103_515_245).wrapping_add(12345);
                (x >> 16) as u8
            })
            .collect();
        let mut few = Item::new("noise.bin", &noise, true);
        few.copies = 3;
        let t = Tmp::with(&build(&[few], false));
        let a = t.open().unwrap();
        assert_eq!(a.files.len(), 4, "four records over one stream, each read alike");
        assert_eq!(a.read(a.find("noise.bin.3").unwrap().id).unwrap(), noise);
    }

    #[test]
    fn first_of_a_name_wins_and_files_never_shadow_folders() {
        let items = vec![
            Item::new("a/b.txt", b"one", false),
            Item::new("A/B.TXT", b"two", false),
            Item::new("a", b"file named like a folder", false),
            Item::new("a/b.txt/c", b"under a file", false),
        ];
        let t = Tmp::with(&build(&items, false));
        let a = t.open().unwrap();
        assert_eq!(a.refused_count, 3, "{:?}", a.refused);
        assert_eq!(a.read(a.find("a/b.txt").unwrap().id).unwrap(), b"one");
        assert!(a.find("a").unwrap().is_dir);
    }

    #[test]
    fn rejects_non_zips() {
        let t = Tmp::with(&[0u8; 100]);
        assert!(t.open().err().unwrap().contains("no end of central directory"));
        let t = Tmp::with(b"PK");
        assert!(t.open().err().unwrap().contains("too small"));
        let mut z = build(&sample(), false);
        let n = z.len();
        z[n - 6..n - 2].copy_from_slice(&0x7FFF_FFF0u32.to_le_bytes()); // central directory offset
        let t = Tmp::with(&z);
        assert!(t.open().err().unwrap().contains("outside the file"));
    }

    #[test]
    fn empty_zip_opens() {
        let t = Tmp::with(&build(&[], false));
        let a = t.open().unwrap();
        assert!(a.files.is_empty() && a.list_dir(0).is_empty());
    }

    #[test]
    fn threads_share_one_archive() {
        let items: Vec<Item> = (0..40).map(|i| Item::new(&format!("d/f{i}.bin"), &text(1000 + i * 37), i % 2 == 0)).collect();
        let t = Tmp::with(&build(&items, true));
        let a = Arc::new(t.open().unwrap());
        let hs: Vec<_> = (0..8)
            .map(|k| {
                let a = a.clone();
                std::thread::spawn(move || {
                    for r in 0..200 {
                        let i = (k * 7 + r) % 40;
                        let f = a.find(&format!("D\\F{i}.BIN")).unwrap();
                        assert_eq!(a.read(f.id).unwrap(), text(1000 + i * 37));
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        assert_eq!(a.stats.file_reads.load(Ordering::Relaxed), 1600);
    }

    #[test]
    fn crc_matches_the_reference_value() {
        assert_eq!(crc32(b"123456789"), 0xCBF4_3926);
    }
}
