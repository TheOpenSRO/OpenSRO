//! Census (round 695): the DXT1 textures in a real archive that mark a texel transparent -- the
//! ones Forward+ drew opaque before round 695 (src/core/dxt.rs) and DdjReader now decodes to
//! RGBA8 there -- with their bytes as DXT1 and as RGBA8, and the scan's time.
//!
//!   cargo run --release --no-default-features --example dxt1_alpha_census -- /path/Data.pk2 [-v]
//!
//! Prints nothing from the archive but paths and numbers (docs/LEGAL.md).
use opensro_native::core::dxt;
use opensro_native::core::pk2::Archive;
use std::time::Instant;

#[derive(Default)]
struct Totals {
    ddj: u64,
    dxt1: u64,
    dxt1_bytes: u64,
    pt: u64,
    pt_mip0_only: u64,
    pt_bytes: u64,
    secs: f64,
}

fn walk(a: &Archive, offset: u64, prefix: &str, verbose: bool, t: &mut Totals) {
    let Ok(dir) = a.dir_at(offset) else { return };
    for e in dir.entries.iter() {
        if e.name == "." || e.name == ".." {
            continue;
        }
        let path = format!("{prefix}{}", e.name);
        if e.is_dir {
            walk(a, e.offset, &format!("{path}\\"), verbose, t);
            continue;
        }
        if !path.to_ascii_lowercase().ends_with(".ddj") {
            continue;
        }
        t.ddj += 1;
        let Ok(data) = a.read(e.offset, e.size) else { continue };
        // 20-byte JMXVDDJ wrapper, then "DDS " and the 124-byte header (docs/protocol/DDJ_FORMAT.md).
        if data.len() < 20 + 4 + 124 || &data[20..24] != b"DDS " {
            continue;
        }
        let dds = &data[20..];
        let h = u32::from_le_bytes(dds[12..16].try_into().unwrap()) as usize;
        let w = u32::from_le_bytes(dds[16..20].try_into().unwrap()) as usize;
        let flags = u32::from_le_bytes(dds[4 + 76..4 + 80].try_into().unwrap());
        if flags & 4 == 0 || &dds[4 + 80..4 + 84] != b"DXT1" {
            continue;
        }
        let px = &dds[4 + 124..];
        t.dxt1 += 1;
        t.dxt1_bytes += px.len() as u64;
        let t0 = Instant::now();
        let has = dxt::has_transparent(px);
        t.secs += t0.elapsed().as_secs_f64();
        if !has {
            continue;
        }
        t.pt += 1;
        t.pt_bytes += px.len() as u64;
        let mip0 = (w.div_ceil(4) * h.div_ceil(4) * 8).min(px.len());
        if !dxt::has_transparent(&px[..mip0]) {
            t.pt_mip0_only += 1;
        }
        if verbose {
            println!("{path}\t{w}x{h}\tbytes={}\ttransparent_blocks={}", px.len(), dxt::transparent_blocks(px));
        }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = args.get(1).expect("usage: dxt1_alpha_census <archive.pk2> [-v]");
    let verbose = args.iter().any(|a| a == "-v");
    let a = Archive::open(path).expect("open");
    let mut t = Totals::default();
    walk(&a, a.root_offset(), "", verbose, &mut t);
    println!(
        "ddj={} dxt1={} ({} bytes) with-transparent-texels={} ({} only below mip 0; {} bytes as DXT1, {} as RGBA8) scan={:.3}s",
        t.ddj, t.dxt1, t.dxt1_bytes, t.pt, t.pt_mip0_only, t.pt_bytes, t.pt_bytes * 8, t.secs
    );
}
