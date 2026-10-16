//! Read-only pk2 (JMXVFS) archive reader: a port of client/scripts/pk2/pk2_reader.gd plus the
//! path lookup of ObjectLoader.find_file (client/scripts/assets/object_loader.gd). The format is
//! docs/protocol/PK2_FORMAT.md; every constant below is the GDScript reader's.
//!
//! What differs from the GDScript reader is how, never what:
//! - a directory is decrypted once and indexed by lower-cased name (the first entry of a name
//!   wins, as find_file's linear scan does), so a lookup is one hash probe per path segment;
//! - file and block reads are positional (pread / seek_read), so threads share no file cursor and
//!   need no lock around a read; only the directory cache is behind a mutex, and a directory is
//!   decrypted outside it.

use std::collections::HashMap;
use std::fs::File;
use std::io;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use super::blowfish::Blowfish;

pub const HEADER_SIZE: usize = 256;
pub const ENTRY_SIZE: usize = 128;
pub const ENTRIES_PER_BLOCK: usize = 20;
pub const BLOCK_SIZE: usize = ENTRY_SIZE * ENTRIES_PER_BLOCK;
pub const ENTRY_TYPE_FOLDER: u8 = 1;
pub const ENTRY_TYPE_FILE: u8 = 2;
const ENTRY_OFF_NAME: usize = 0x01;
const ENTRY_NAME_LEN: usize = 89;
const ENTRY_OFF_POSITION: usize = 0x6A;
const ENTRY_OFF_SIZE: usize = 0x72;
const ENTRY_OFF_NEXT_BLOCK: usize = 0x76;
/// A cycle/corruption guard, as MAX_CHAIN_BLOCKS in pk2_reader.gd -- not an observed limit.
const MAX_CHAIN_BLOCKS: usize = 100_000;
/// The long-published default key of the directory obfuscation (pk2_reader.gd DEFAULT_KEY).
pub const DEFAULT_KEY: &[u8] = b"169841";
/// XORed over the key before the key schedule (pk2_reader.gd KEY_XOR_TABLE).
const KEY_XOR_TABLE: [u8; 10] = [0x03, 0xf8, 0xe4, 0x44, 0x88, 0x99, 0x3f, 0x64, 0xfe, 0x35];
const MAGIC_PREFIX: &[u8] = b"JoyMax File Manager";

pub fn effective_key(key: &[u8]) -> Vec<u8> {
    key.iter().enumerate().map(|(i, b)| b ^ KEY_XOR_TABLE.get(i).copied().unwrap_or(0)).collect()
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Entry {
    /// As Godot's get_string_from_ascii decodes it: each byte is one Latin-1 code point.
    pub name: String,
    pub is_dir: bool,
    pub offset: u64,
    pub size: u64,
}

pub struct Dir {
    pub entries: Vec<Entry>,
    /// Lower-cased name -> index of the FIRST entry with that name.
    index: HashMap<String, usize>,
}

impl Dir {
    pub fn get(&self, lower_name: &str) -> Option<&Entry> {
        self.index.get(lower_name).map(|&i| &self.entries[i])
    }
}

/// Godot's String.to_lower: the Unicode SIMPLE lower-case mapping, code point by code point
/// (docs/protocol/asset_packs.md, rule 4; round 789). For the Latin-1 code points a pk2 name holds
/// it is what Rust's char::to_lowercase gives; above U+00FF a pack's UTF-8 name may hold one whose
/// FULL mapping is several code points (only U+0130, whose simple mapping is `i`), so the full
/// mapping is never used.
pub fn lower(s: &str) -> String {
    s.chars().map(lower_char).collect()
}

pub fn lower_char(c: char) -> char {
    if c.is_ascii() {
        return c.to_ascii_lowercase();
    }
    let mut it = c.to_lowercase();
    match (it.next(), it.next()) {
        (Some(l), None) => l,
        _ if c == '\u{130}' => 'i',
        _ => c,
    }
}

/// A lookup path's segments (asset_packs.md rule 4, round 789): split on `\` and `/`, empty
/// segments skipped (a leading, trailing or doubled separator); None when a segment is `.` or
/// `..` or holds a `:` or a NUL (no layer serves an unsafe path), or when nothing is left.
pub fn path_segments(path: &str) -> Option<Vec<&str>> {
    let parts: Vec<&str> = path.split(['\\', '/']).filter(|p| !p.is_empty()).collect();
    if parts.is_empty() || parts.iter().any(|p| *p == "." || *p == ".." || p.contains([':', '\0'])) {
        return None;
    }
    Some(parts)
}

fn latin1(b: &[u8]) -> String {
    b.iter().map(|&c| c as char).collect()
}

fn le_u32(b: &[u8], off: usize) -> u64 {
    u32::from_le_bytes([b[off], b[off + 1], b[off + 2], b[off + 3]]) as u64
}

/// Counters a caller can read back (the client logs them on the native path).
#[derive(Default)]
pub struct Stats {
    pub dir_blocks: AtomicU64,
    pub dir_cache_hits: AtomicU64,
    pub file_reads: AtomicU64,
    pub file_bytes: AtomicU64,
}

pub struct Archive {
    file: File,
    /// The file's length at open: every read is clamped to it (an entry's size is the archive's
    /// word, not the file's -- round 667's review, M3).
    len: u64,
    encrypted: bool,
    cipher: Option<Blowfish>,
    root: u64,
    dirs: Mutex<HashMap<u64, Arc<Dir>>>,
    pub stats: Stats,
}

#[cfg(unix)]
fn read_at(f: &File, buf: &mut [u8], off: u64) -> io::Result<usize> {
    use std::os::unix::fs::FileExt;
    f.read_at(buf, off)
}

#[cfg(windows)]
fn read_at(f: &File, buf: &mut [u8], off: u64) -> io::Result<usize> {
    use std::os::windows::fs::FileExt;
    f.seek_read(buf, off)
}

/// Fills as much of buf as the file has from off; returns the count (short only at end of file).
pub(crate) fn read_full_at(f: &File, buf: &mut [u8], off: u64) -> io::Result<usize> {
    let mut got = 0;
    while got < buf.len() {
        match read_at(f, &mut buf[got..], off + got as u64) {
            Ok(0) => break,
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(e),
        }
    }
    Ok(got)
}

impl Archive {
    pub fn open(path: &str) -> Result<Archive, String> {
        let file = File::open(path).map_err(|e| format!("pk2: could not open {path}: {e}"))?;
        let mut header = [0u8; HEADER_SIZE];
        let n = read_full_at(&file, &mut header, 0).map_err(|e| format!("pk2: reading {path}: {e}"))?;
        if n < HEADER_SIZE {
            return Err(format!("pk2: {path} is too small to be a pk2 archive"));
        }
        if !header.starts_with(MAGIC_PREFIX) {
            return Err(format!("pk2: {path} is not a pk2 archive (bad magic)"));
        }
        let len = file.metadata().map_err(|e| format!("pk2: reading {path}: {e}"))?.len();
        let encrypted = header[0x22] != 0;
        let cipher = if encrypted { Some(Blowfish::new(&effective_key(DEFAULT_KEY))) } else { None };
        Ok(Archive {
            file,
            len,
            encrypted,
            cipher,
            root: HEADER_SIZE as u64,
            dirs: Mutex::new(HashMap::new()),
            stats: Stats::default(),
        })
    }

    pub fn encrypted(&self) -> bool {
        self.encrypted
    }

    pub fn root_offset(&self) -> u64 {
        self.root
    }

    /// A directory's entries, following its block chain (pk2_reader.gd _read_block_chain_locked),
    /// decrypted once and cached by its chain-start offset.
    pub fn dir_at(&self, offset: u64) -> io::Result<Arc<Dir>> {
        if let Some(d) = self.dirs.lock().unwrap().get(&offset) {
            self.stats.dir_cache_hits.fetch_add(1, Ordering::Relaxed);
            return Ok(d.clone());
        }
        // Read and decrypt outside the lock: two threads asking for the same new directory both
        // decode it, and the first insert is kept -- the same rule as World3D's texture caches.
        let dir = Arc::new(self.read_block_chain(offset)?);
        let mut dirs = self.dirs.lock().unwrap();
        Ok(dirs.entry(offset).or_insert(dir).clone())
    }

    fn read_block_chain(&self, start: u64) -> io::Result<Dir> {
        let mut entries = Vec::new();
        let mut offset = start;
        let mut block = vec![0u8; BLOCK_SIZE];
        for _ in 0..MAX_CHAIN_BLOCKS {
            block.iter_mut().for_each(|b| *b = 0);
            let got = read_full_at(&self.file, &mut block, offset)?;
            self.stats.dir_blocks.fetch_add(1, Ordering::Relaxed);
            if let Some(c) = &self.cipher {
                // pk2_reader.gd decrypts the bytes it got, 8 at a time; a short read at the end of
                // the file leaves its partial tail as read.
                c.decrypt_pk2_in_place(&mut block[..got - got % 8]);
            }
            let mut next = 0u64;
            for i in 0..ENTRIES_PER_BLOCK {
                let raw = &block[i * ENTRY_SIZE..(i + 1) * ENTRY_SIZE];
                let kind = raw[0];
                // The parity negative's bug: the last slot of every block is never read.
                let skip = cfg!(feature = "parity-negative") && i == ENTRIES_PER_BLOCK - 1;
                if (kind == ENTRY_TYPE_FOLDER || kind == ENTRY_TYPE_FILE) && !skip {
                    let field = &raw[ENTRY_OFF_NAME..ENTRY_OFF_NAME + ENTRY_NAME_LEN];
                    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
                    let name = latin1(&field[..end]);
                    if name != "." && name != ".." {
                        entries.push(Entry {
                            name,
                            is_dir: kind == ENTRY_TYPE_FOLDER,
                            offset: le_u32(raw, ENTRY_OFF_POSITION),
                            size: le_u32(raw, ENTRY_OFF_SIZE),
                        });
                    }
                }
                if i == ENTRIES_PER_BLOCK - 1 {
                    next = le_u32(raw, ENTRY_OFF_NEXT_BLOCK);
                }
            }
            if next == 0 {
                break;
            }
            offset = next;
        }
        let mut index = HashMap::with_capacity(entries.len());
        for (i, e) in entries.iter().enumerate() {
            index.entry(lower(&e.name)).or_insert(i);
        }
        Ok(Dir { entries, index })
    }

    /// ObjectLoader.find_file: `\` or `/` separated, case-insensitive, the first match per
    /// segment; every segment but the last must be a folder. None when any segment is missing.
    /// Round 789: empty segments are skipped and an unsafe path finds nothing (path_segments).
    pub fn find(&self, path: &str) -> Option<Entry> {
        let parts = path_segments(path)?;
        let mut dir = self.dir_at(self.root).ok()?;
        for (i, part) in parts.iter().enumerate() {
            let found = dir.get(&lower(part))?.clone();
            if i == parts.len() - 1 {
                return Some(found);
            }
            if !found.is_dir {
                return None;
            }
            dir = self.dir_at(found.offset).ok()?;
        }
        None
    }

    /// size bytes from offset -- fewer at the end of the file, as FileAccess.get_buffer, and
    /// nothing from past it. Never allocates more than the file holds from `offset`, and the
    /// allocation itself is fallible: an untrusted size must not abort the process (Rust aborts
    /// on a failed infallible allocation, which no catch_unwind sees -- round 667's review, M3).
    pub fn read(&self, offset: u64, size: u64) -> io::Result<Vec<u8>> {
        let want = size.min(self.len.saturating_sub(offset));
        let want = usize::try_from(want).map_err(|_| io::Error::new(io::ErrorKind::OutOfMemory, "pk2: read too large"))?;
        let mut buf = Vec::new();
        buf.try_reserve_exact(want)
            .map_err(|_| io::Error::new(io::ErrorKind::OutOfMemory, format!("pk2: cannot allocate {want} bytes")))?;
        buf.resize(want, 0);
        let got = read_full_at(&self.file, &mut buf, offset)?;
        buf.truncate(got);
        self.stats.file_reads.fetch_add(1, Ordering::Relaxed);
        self.stats.file_bytes.fetch_add(got as u64, Ordering::Relaxed);
        Ok(buf)
    }
}

/// Builds a synthetic archive in memory: tests here and the client's synthetic suite use the
/// same layout (pk2_reader_test.gd builds its own the same way). Entries are (name, kind,
/// position, size); a folder's position is its block chain's start.
pub mod synth {
    use super::*;

    pub fn entry(kind: u8, name: &str, position: u32, size: u32, next_block: u32) -> [u8; ENTRY_SIZE] {
        let mut e = [0u8; ENTRY_SIZE];
        e[0] = kind;
        let nb = name.as_bytes();
        e[ENTRY_OFF_NAME..ENTRY_OFF_NAME + nb.len()].copy_from_slice(nb);
        e[ENTRY_OFF_POSITION..ENTRY_OFF_POSITION + 4].copy_from_slice(&position.to_le_bytes());
        e[ENTRY_OFF_SIZE..ENTRY_OFF_SIZE + 4].copy_from_slice(&size.to_le_bytes());
        e[ENTRY_OFF_NEXT_BLOCK..ENTRY_OFF_NEXT_BLOCK + 4].copy_from_slice(&next_block.to_le_bytes());
        e
    }

    pub fn header(encrypted: bool) -> Vec<u8> {
        let mut h = vec![0u8; HEADER_SIZE];
        h[..MAGIC_PREFIX.len()].copy_from_slice(MAGIC_PREFIX);
        h[0x22] = encrypted as u8;
        h
    }

    /// Encrypts a block the way the format stores it (the inverse of decrypt_pk2_in_place).
    pub fn encrypt_block(block: &mut [u8]) {
        let bf = Blowfish::new(&effective_key(DEFAULT_KEY));
        for c in block.chunks_exact_mut(8) {
            let l = u32::from_le_bytes([c[0], c[1], c[2], c[3]]);
            let r = u32::from_le_bytes([c[4], c[5], c[6], c[7]]);
            let (l, r) = bf.encrypt(l, r);
            c[0..4].copy_from_slice(&l.to_le_bytes());
            c[4..8].copy_from_slice(&r.to_le_bytes());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::synth::*;
    use super::*;
    use std::io::Write;

    /// root: Data (folder, 2 blocks chained), readme.txt; Data: 25 files f00..f24 plus a
    /// duplicate "F03" later in the chain (the first one wins), and "Sub" (folder) holding x.bin.
    fn build(encrypted: bool) -> (tempfile_path::TempPath, Vec<u8>) {
        let root = HEADER_SIZE as u32;
        let data_b1 = root + BLOCK_SIZE as u32;
        let data_b2 = data_b1 + BLOCK_SIZE as u32;
        let sub = data_b2 + BLOCK_SIZE as u32;
        let payload = sub + BLOCK_SIZE as u32;
        let mut img = header(encrypted);
        let mut blocks: Vec<Vec<u8>> = vec![vec![0u8; BLOCK_SIZE]; 4];
        let put = |b: &mut Vec<u8>, i: usize, e: [u8; ENTRY_SIZE]| b[i * ENTRY_SIZE..(i + 1) * ENTRY_SIZE].copy_from_slice(&e);
        put(&mut blocks[0], 0, entry(ENTRY_TYPE_FOLDER, ".", root, 0, 0));
        put(&mut blocks[0], 1, entry(ENTRY_TYPE_FOLDER, "Data", data_b1, 0, 0));
        put(&mut blocks[0], 2, entry(ENTRY_TYPE_FILE, "readme.txt", payload, 5, 0));
        for i in 0..19 {
            put(&mut blocks[1], i, entry(ENTRY_TYPE_FILE, &format!("f{i:02}"), payload + i as u32, 1, 0));
        }
        put(&mut blocks[1], 19, entry(ENTRY_TYPE_FILE, "f19", payload + 19, 1, data_b2));
        for i in 0..5 {
            put(&mut blocks[2], i, entry(ENTRY_TYPE_FILE, &format!("f{:02}", 20 + i), payload + 20 + i as u32, 1, 0));
        }
        put(&mut blocks[2], 5, entry(ENTRY_TYPE_FILE, "F03", payload + 2, 3, 0));
        put(&mut blocks[2], 6, entry(ENTRY_TYPE_FOLDER, "Sub", sub, 0, 0));
        put(&mut blocks[3], 0, entry(ENTRY_TYPE_FILE, "x.bin", payload, 25, 0));
        for b in blocks.iter_mut() {
            if encrypted {
                encrypt_block(b);
            }
            img.extend_from_slice(b);
        }
        let body: Vec<u8> = (0..25u8).map(|i| b'a' + i).collect();
        img.extend_from_slice(&body);
        let path = tempfile_path::TempPath::new();
        std::fs::File::create(&path.0).unwrap().write_all(&img).unwrap();
        (path, body)
    }

    mod tempfile_path {
        pub struct TempPath(pub std::path::PathBuf);
        impl TempPath {
            pub fn new() -> TempPath {
                use std::sync::atomic::{AtomicUsize, Ordering};
                static N: AtomicUsize = AtomicUsize::new(0);
                let n = N.fetch_add(1, Ordering::Relaxed);
                TempPath(std::env::temp_dir().join(format!("opensro_native_test_{}_{n}.pk2", std::process::id())))
            }
        }
        impl Drop for TempPath {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
    }

    #[test]
    fn reads_plain_and_encrypted_archives_alike() {
        for encrypted in [false, true] {
            let (path, body) = build(encrypted);
            let a = Archive::open(path.0.to_str().unwrap()).unwrap();
            assert_eq!(a.encrypted(), encrypted);
            let root = a.dir_at(a.root_offset()).unwrap();
            let names: Vec<&str> = root.entries.iter().map(|e| e.name.as_str()).collect();
            assert_eq!(names, ["Data", "readme.txt"], "'.' is skipped");
            let data = a.find("data").unwrap();
            assert!(data.is_dir);
            let d = a.dir_at(data.offset).unwrap();
            assert_eq!(d.entries.len(), 27, "the chain is followed into its second block");
            // The first of two case-variant names wins, as the linear scan does.
            let f03 = a.find("DATA\\f03").unwrap();
            assert_eq!((f03.name.as_str(), f03.size), ("f03", 1));
            let x = a.find("Data/Sub/X.BIN").unwrap();
            assert_eq!(a.read(x.offset, x.size).unwrap(), body);
            assert!(a.find("Data\\missing").is_none());
            assert!(a.find("readme.txt\\x").is_none(), "a file is not a folder");
            assert_eq!(a.find("\\Data\\\\f03/").unwrap().name, "f03", "empty segments are skipped (round 789)");
            assert!(a.find("Data\\..\\readme.txt").is_none() && a.find("c:\\x").is_none() && a.find("/").is_none(), "unsafe or empty: nothing");
            // Reading past the end gives what is there, as get_buffer does.
            assert_eq!(a.read(x.offset + 20, 100).unwrap(), body[20..].to_vec());
        }
    }

    /// An entry's size is the archive's word, not the file's: a read must never allocate more
    /// than the file holds (round 667's review, M3 -- `vec![0; 0xFFFFFFFF]` aborted the process
    /// under a memory limit, which no unwind can catch). The read returns what is there, as
    /// FileAccess.get_buffer does, and an offset past the end returns nothing.
    #[test]
    fn oversize_entry_reads_only_what_the_file_holds() {
        let (path, body) = build(false);
        let a = Archive::open(path.0.to_str().unwrap()).unwrap();
        let x = a.find("Data\\Sub\\x.bin").unwrap();
        let file_len = std::fs::metadata(&path.0).unwrap().len();
        let v = a.read(x.offset, 0xFFFF_FFFF).unwrap();
        assert_eq!(v, body);
        assert!(v.capacity() as u64 <= file_len, "allocated {} bytes for a {file_len}-byte file", v.capacity());
        let past = a.read(file_len + 10, 0xFFFF_FFFF).unwrap();
        assert!(past.is_empty() && past.capacity() == 0, "a read past the end allocates nothing");
    }

    #[test]
    fn rejects_non_archives() {
        let p = tempfile_path::TempPath::new();
        std::fs::write(&p.0, vec![0u8; 300]).unwrap();
        assert!(Archive::open(p.0.to_str().unwrap()).err().unwrap().contains("bad magic"));
        std::fs::write(&p.0, b"JoyMax File Manager").unwrap();
        assert!(Archive::open(p.0.to_str().unwrap()).err().unwrap().contains("too small"));
    }

    #[test]
    fn latin1_names_lower_case_like_godot() {
        assert_eq!(lower("ÀBÇ.TXT"), "àbç.txt");
        assert_eq!(lower("\u{130}×Þ"), "i×þ", "the simple mapping: U+0130 is one code point; U+00D7 stays");
        assert_eq!(latin1(&[0x41, 0xC9]), "AÉ");
    }
}
