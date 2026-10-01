//! The UTF-16 text tables (round 671): the client's `server_dep\silkroad\textdata\*.txt` readers,
//! ported one to one from GDScript. Each public function here is ONE GDScript function's row loop:
//!
//! | here | GDScript (client/scripts/...) |
//! |---|---|
//! | `npc_positions` | npc/npc_table_reader.gd `parse_positions` |
//! | `char_codes` | `parse_codes` |
//! | `char_models` | `parse_models` |
//! | `char_models_by_code` | `parse_models_by_code` |
//! | `char_org_codes` | `parse_org_codes` |
//! | `char_speeds_by_code` | `parse_speeds_by_code` |
//! | `char_country_by_code` | `parse_country_by_code` |
//! | `char_bc_radius_by_code` | `parse_bc_radius_by_code` |
//! | `char_name_keys` | `parse_name_keys`, and `parse_names` up to its `names.get_text` |
//! | `char_models_name_keys` | `parse_models_by_name` up to its `names.get_text` |
//! | `items` | npc/item_table_reader.gd `parse`, up to `Item.new()` |
//! | `ui_text_rows` | ui/ui_text_table.gd `_pp_parse`, up to its keep-first insert |
//!
//! What stays in GDScript, and why: the merge into the caller's Dictionary (`into[k] = v`, in row
//! order, so a later duplicate id overwrites an earlier one exactly as before -- "last wins"; the
//! UI table's "first wins" check runs there too), building `Item`/`Spawn` objects and `Vector3`s
//! (the readers' API), and every `to_lower`/`to_upper`/`get_text` whose RESULT is kept: a key
//! formed by Godot's full-Unicode case tables (ucaps.h) is left to the engine that defines it,
//! rather than ported with its 600-odd entries (OURS: a choice, not a known difference). Where
//! the GDScript only TESTS a lower-cased value against a fixed ASCII string (`.bsr`, `.ddj`,
//! `.efp`, `xxx`, `none`), an ASCII case-insensitive compare is exact: no code point outside
//! ASCII lower-cases into ASCII in Godot 4.2.2 (MEASURED by round 671's review on the box, over
//! every code point), and 'I' lower-cases to 'i' (its {0x0049, 0x0131} entry is commented out,
//! ucaps.h:716, READ; `"I".to_lower()` is U+0069, MEASURED). Round 671 first said 'I' became
//! U+0131 here, from a parse of ucaps.h that did not skip comments; that was wrong.
//!
//! Godot's own string semantics are ported here from the 4.2.2 source (core/string/ustring.cpp,
//! READ): `parse_utf16`, `strip_edges`, `split`, `is_valid_int`, `to_int`, `is_valid_float` and
//! `to_float` (`built_in_strtod`, which is NOT a correctly rounded parse, so Rust's own parse
//! would differ in the last bit on some inputs). GDScript's `int(s)` and `float(s)` are
//! `to_int()` and `to_float()` (variant_construct.h, `VariantConstructorFromString`).
//!
//! Inputs whose GDScript path is not ported answer `Err(Fallback)`, and the caller runs the
//! GDScript reader instead, so behaviour on them is unchanged: a decode that comes out empty
//! (the GDScript then tries UTF-8), an unpaired UTF-16 surrogate (Godot keeps it as a lone
//! surrogate character, which a Rust `String` cannot hold), a U+FEFF after the leading BOM
//! (gdext 0.5.5 hands a string back through `String::parse_utf8`, which drops a LEADING BOM, so a
//! field beginning with one would lose it; round 671's review), and the UI table with a negative
//! language column. Nothing here panics on any input (cargo tests feed truncated and random
//! bytes); every index is checked.

/// Why a table was handed back to the GDScript reader.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Fallback(pub &'static str);

// ---------------------------------------------------------------------------------------------
// Godot 4.2.2 string semantics (ustring.cpp, READ)
// ---------------------------------------------------------------------------------------------

/// `String::strip_edges()`: drops every leading and trailing character whose code is <= 32.
pub fn strip(s: &str) -> &str {
    s.trim_matches(|c: char| (c as u32) <= 32)
}

fn is_digit(b: u8) -> bool {
    b.is_ascii_digit()
}

/// `String::is_valid_int()`. Byte-wise on UTF-8 is exact: every test is against an ASCII byte,
/// and a non-ASCII character fails the digit test in either form.
pub fn is_valid_int(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() {
        return false;
    }
    // `len != 1` counts characters; a lone multi-byte character is not '+'/'-' either way.
    let from = usize::from(b.len() != 1 && (b[0] == b'+' || b[0] == b'-'));
    b[from..].iter().all(|&c| is_digit(c))
}

/// `String::to_int()`: digits up to the first '.', every other character ignored except a '-'
/// seen while the value is still 0, which flips the sign. On overflow Godot prints an error and
/// returns INT64_MAX / INT64_MIN; this returns the same value without the print.
pub fn to_int(s: &str) -> i64 {
    let b = s.as_bytes();
    if b.is_empty() {
        return 0;
    }
    let to = b.iter().position(|&c| c == b'.').unwrap_or(b.len());
    let mut integer: i64 = 0;
    let mut sign: i64 = 1;
    for &c in &b[..to] {
        if is_digit(c) {
            let overflow = integer > i64::MAX / 10
                || (integer == i64::MAX / 10 && ((sign == 1 && c > b'7') || (sign == -1 && c > b'8')));
            if overflow {
                return if sign == 1 { i64::MAX } else { i64::MIN };
            }
            // "-9223372036854775808" reaches i64::MAX + 1 here, which the C++ wraps (as the
            // two's-complement machine does); wrapping keeps that and never panics.
            integer = integer.wrapping_mul(10).wrapping_add(i64::from(c - b'0'));
        } else if integer == 0 && c == b'-' {
            sign = -sign;
        }
    }
    integer.wrapping_mul(sign)
}

/// `String::is_valid_float()`.
pub fn is_valid_float(s: &str) -> bool {
    let b = s.as_bytes();
    if b.is_empty() {
        return false;
    }
    let from = usize::from(b[0] == b'+' || b[0] == b'-');
    let (mut exponent_found, mut period_found, mut sign_found) = (false, false, false);
    let (mut exponent_values_found, mut numbers_found) = (false, false);
    for &c in &b[from..] {
        if is_digit(c) {
            if exponent_found {
                exponent_values_found = true;
            } else {
                numbers_found = true;
            }
        } else if numbers_found && !exponent_found && c == b'e' {
            exponent_found = true;
        } else if !period_found && !exponent_found && c == b'.' {
            period_found = true;
        } else if (c == b'-' || c == b'+') && exponent_found && !exponent_values_found && !sign_found {
            sign_found = true;
        } else {
            return false;
        }
    }
    numbers_found
}

/// `String::to_float()`: 0 for "", else `built_in_strtod` ported line for line (including its
/// quirks: at most 18 mantissa digits, the exponent applied by repeated powers of ten, and a
/// dangling "e" that returns the mantissa digits WITHOUT the decimal point's scaling -- "1.5e"
/// is 15). `None` only for an exponent so long that the C++ overflows `int` (undefined
/// behaviour there); the caller falls back.
pub fn to_float(s: &str) -> Option<f64> {
    if s.is_empty() {
        return Some(0.0);
    }
    if cfg!(feature = "parity-negative") {
        // The NEGATIVE (native/README.md, "Parity"): Rust's correctly rounded parse in place of
        // built_in_strtod, falling back to the port on anything it does not accept.
        if let Ok(v) = s.parse::<f64>() {
            return Some(v);
        }
    }
    strtod(s.as_bytes())
}

fn strtod(b: &[u8]) -> Option<f64> {
    const MAX_EXPONENT: i32 = 511;
    const POWERS_OF_10: [f64; 9] = [10., 100., 1.0e4, 1.0e8, 1.0e16, 1.0e32, 1.0e64, 1.0e128, 1.0e256];
    // The C++ reads a NUL-terminated buffer; past the end reads as that NUL.
    let at = |i: usize| -> u8 { b.get(i).copied().unwrap_or(0) };
    let mut p = 0usize;
    while matches!(at(p), b' ' | b'\t' | b'\n') {
        p += 1;
    }
    let sign = if at(p) == b'-' {
        p += 1;
        true
    } else {
        if at(p) == b'+' {
            p += 1;
        }
        false
    };
    let signed = |f: f64| if sign { -f } else { f };

    let mut dec_pt: i32 = -1;
    let mut mant_size: i32 = 0;
    loop {
        let c = at(p);
        if !is_digit(c) {
            if c != b'.' || dec_pt >= 0 {
                break;
            }
            dec_pt = mant_size;
        }
        p += 1;
        mant_size += 1;
    }
    let p_exp = p;
    p -= mant_size as usize;
    if dec_pt < 0 {
        dec_pt = mant_size;
    } else {
        mant_size -= 1;
    }
    let frac_exp;
    if mant_size > 18 {
        frac_exp = dec_pt - 18;
        mant_size = 18;
    } else {
        frac_exp = dec_pt - mant_size;
    }
    if mant_size == 0 {
        return Some(signed(0.0));
    }
    let mut frac1: i32 = 0;
    while mant_size > 9 {
        let mut c = at(p);
        p += 1;
        if c == b'.' {
            c = at(p);
            p += 1;
        }
        frac1 = 10 * frac1 + i32::from(c.wrapping_sub(b'0'));
        mant_size -= 1;
    }
    let mut frac2: i32 = 0;
    while mant_size > 0 {
        let mut c = at(p);
        p += 1;
        if c == b'.' {
            c = at(p);
            p += 1;
        }
        frac2 = 10 * frac2 + i32::from(c.wrapping_sub(b'0'));
        mant_size -= 1;
    }
    let mut fraction = (1.0e9 * f64::from(frac1)) + f64::from(frac2);

    p = p_exp;
    let mut exp: i32 = 0;
    let mut exp_sign = false;
    if at(p) == b'E' || at(p) == b'e' {
        p += 1;
        if at(p) == b'-' {
            exp_sign = true;
            p += 1;
        } else if at(p) == b'+' {
            p += 1;
        }
        if !is_digit(at(p)) {
            // `goto done`: the fraction is returned as it stands, unscaled.
            return Some(signed(fraction));
        }
        while is_digit(at(p)) {
            exp = exp.checked_mul(10)?.checked_add(i32::from(at(p) - b'0'))?;
            p += 1;
        }
    }
    exp = if exp_sign { frac_exp.checked_sub(exp)? } else { frac_exp.checked_add(exp)? };
    if exp < 0 {
        exp_sign = true;
        exp = exp.checked_neg()?;
    } else {
        exp_sign = false;
    }
    if exp > MAX_EXPONENT {
        exp = MAX_EXPONENT; // Godot also prints "Exponent too high"
    }
    let mut dbl_exp = 1.0f64;
    let mut d = 0usize;
    while exp != 0 {
        if exp & 1 != 0 {
            dbl_exp *= POWERS_OF_10[d];
        }
        exp >>= 1;
        d += 1;
    }
    if exp_sign {
        fraction /= dbl_exp;
    } else {
        fraction *= dbl_exp;
    }
    Some(signed(fraction))
}

/// `s.to_lower().ends_with(suffix)` for an ASCII `suffix` without 'i' (see the module comment).
fn ends_with_lower(s: &str, suffix: &str) -> bool {
    debug_assert!(suffix.is_ascii() && !suffix.contains(['i', 'I']));
    let (b, x) = (s.as_bytes(), suffix.as_bytes());
    // A UTF-8 tail that equals an ASCII suffix byte for byte is those ASCII characters.
    b.len() >= x.len() && b[b.len() - x.len()..].eq_ignore_ascii_case(x)
}

/// `s.to_lower() == word` for an ASCII `word` without 'i'.
fn equals_lower(s: &str, word: &str) -> bool {
    debug_assert!(word.is_ascii() && !word.contains(['i', 'I']));
    s.len() == word.len() && s.as_bytes().eq_ignore_ascii_case(word.as_bytes())
}

// ---------------------------------------------------------------------------------------------
// The decode: `_lines` and UiTextTable's prologue
// ---------------------------------------------------------------------------------------------

/// The text of `data` as the readers decode it: the bytes FF FE stripped, then
/// `PackedByteArray.get_string_from_utf16()` (`String::parse_utf16` over `size / 2` units: a
/// second BOM -- FEFF as is, FFFE to byte-swap the rest -- skipped, decoding stops at the first
/// NUL unit, surrogate pairs combined). With `drop_cr`, every '\r' is removed as
/// `text.replace("\r", "")` does. `Ok(None)` for empty `data` (`_lines` returns no lines).
/// `Err` for an empty decode (GDScript then tries UTF-8) and an unpaired surrogate.
pub fn decode(data: &[u8], drop_cr: bool) -> Result<Option<String>, Fallback> {
    if data.is_empty() {
        return Ok(None);
    }
    let raw = if data.len() >= 2 && data[0] == 0xFF && data[1] == 0xFE { &data[2..] } else { data };
    let units = raw.len() / 2;
    let mut swap = false;
    let mut start = 0usize;
    if units >= 1 {
        match u16::from_le_bytes([raw[0], raw[1]]) {
            0xFEFF => start = 1,
            0xFFFE => {
                start = 1;
                swap = true;
            }
            _ => {}
        }
    }
    let body = raw.get(2 * start..2 * units).unwrap_or(&[]);
    let unit = |b: &[u8]| {
        let u = u16::from_le_bytes([b[0], b[1]]);
        if swap {
            u.swap_bytes()
        } else {
            u
        }
    };
    // UTF-8 out. Fallible and clamped to the data: at most 3 bytes a unit (a pair, 2 units, is 4),
    // reserved once so no push reallocates.
    let mut out: Vec<u8> = Vec::new();
    out.try_reserve(units.saturating_mul(3)).map_err(|_| Fallback("out of memory decoding a table"))?;
    let mut decoded = 0usize;
    let mut it = body.chunks_exact(2);
    while let Some(b) = it.next() {
        let u = unit(b);
        if u < 0x80 {
            // The tables are almost all ASCII: one byte, no further test.
            if u == 0 {
                break;
            }
            decoded += 1;
            if !(drop_cr && u == 0x0D) {
                out.push(u as u8);
            }
            continue;
        }
        decoded += 1;
        if u == 0xFEFF {
            // A BOM after the one stripped above (concatenated UTF-16 files). The GDScript keeps
            // it as a character (strip_edges leaves code points over 32), but a native string
            // that BEGINS with it would lose it on the way back: gdext 0.5.5 hands strings to
            // Godot through string_new_with_utf8_chars_and_len, i.e. String::parse_utf8, which
            // skips a leading UTF-8 BOM (READ, ustring.cpp 4.2.2). Round 671's review.
            return Err(Fallback("a byte-order mark inside the text"));
        }
        let c = if (0xD800..0xDC00).contains(&u) {
            // A lead needs a trail next; a NUL, the end, or anything else leaves it unpaired.
            let next = it.next().map_or(0, unit);
            if !(0xDC00..0xE000).contains(&next) {
                return Err(Fallback("unpaired UTF-16 surrogate"));
            }
            0x10000 + ((u32::from(u) - 0xD800) << 10) + (u32::from(next) - 0xDC00)
        } else if (0xDC00..0xE000).contains(&u) {
            return Err(Fallback("unpaired UTF-16 surrogate"));
        } else {
            u32::from(u)
        };
        let ch = char::from_u32(c).ok_or(Fallback("invalid character"))?;
        out.extend_from_slice(ch.encode_utf8(&mut [0u8; 4]).as_bytes());
    }
    if decoded == 0 {
        return Err(Fallback("empty UTF-16 decode (the reader tries UTF-8)"));
    }
    // Always valid: every byte above came from a char's own encoding.
    String::from_utf8(out).map(Some).map_err(|_| Fallback("internal: invalid UTF-8"))
}

/// Every line's tab-separated fields, as `for line in _lines(data): var cols := line.split("\t")`
/// sees them (Godot's `split` with allow_empty keeps every empty field, and an empty line is one
/// empty field). One field vector is reused across lines.
fn for_each_row(text: &str, mut row: impl FnMut(&[&str])) {
    let mut cols: Vec<&str> = Vec::new();
    for line in text.split('\n') {
        split_tabs(line, &mut cols);
        row(&cols);
    }
}

/// `line.split("\t")` into `cols` (cleared first): every field, empty ones included. A byte scan:
/// a tab byte in UTF-8 is always the tab character, so every cut is on a character boundary.
fn split_tabs<'a>(line: &'a str, cols: &mut Vec<&'a str>) {
    cols.clear();
    let mut from = 0;
    for (i, &b) in line.as_bytes().iter().enumerate() {
        if b == b'\t' {
            cols.push(&line[from..i]);
            from = i + 1;
        }
    }
    cols.push(&line[from..]);
}

/// Every row's fields, flattened, with each row's end index: `_lines(data)` split on tabs with
/// `drop_cr`, UiTextTable's `split("\n")` (no '\r' removal) without. For the parity check, which
/// holds the decode and the splits to Godot's on every text table in the archive.
pub fn split_rows(data: &[u8], drop_cr: bool) -> Result<(Vec<String>, Vec<i64>), Fallback> {
    let mut cells = Vec::new();
    let mut ends = Vec::new();
    if let Some(text) = decode(data, drop_cr)? {
        for_each_row(&text, |cols| {
            cells.extend(cols.iter().map(|c| (*c).to_owned()));
            ends.push(cells.len() as i64);
        });
    }
    Ok((cells, ends))
}

/// Runs `row` over `_lines(data)`'s rows (none for empty data).
fn rows_of(data: &[u8], row: impl FnMut(&[&str])) -> Result<(), Fallback> {
    if let Some(text) = decode(data, true)? {
        for_each_row(&text, row);
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------
// characterdata*.txt and npcpos.txt (npc/npc_table_reader.gd)
// ---------------------------------------------------------------------------------------------

const COL_POS_NPC_ID: usize = 0;
const COL_POS_REGION: usize = 1;
const COL_POS_X: usize = 2;
const COL_POS_Y: usize = 3;
const COL_POS_Z: usize = 4;
const COL_MODEL_ID: usize = 1;
const COL_CODE_NAME: usize = 2;
const COL_ORG_CODE_NAME: usize = 4;
const COL_COUNTRY: usize = 14;
const COL_SPEED_WALK: usize = 46;
const COL_SPEED_RUN: usize = 47;
const COL_BC_RADIUS: usize = 50;

/// `_find_model_path`: the first field whose stripped text ends in ".bsr" (any case), cut at its
/// first ',' and stripped again; "" when none.
fn find_model_path<'a>(cols: &[&'a str]) -> &'a str {
    for col in cols {
        let trimmed = strip(col);
        if ends_with_lower(trimmed, ".bsr") {
            if cfg!(feature = "parity-negative") {
                // The NEGATIVE: the whole comma list, as before round 655.
                return trimmed;
            }
            return strip(trimmed.split(',').next().unwrap_or(""));
        }
    }
    ""
}

/// `_find_name_key`: the first stripped field starting "SN_"; "" when none.
fn find_name_key<'a>(cols: &[&'a str]) -> &'a str {
    cols.iter().map(|c| strip(c)).find(|t| t.starts_with("SN_")).unwrap_or("")
}

/// Rows of int keys and string values, in file order.
#[derive(Debug, Default, PartialEq)]
pub struct IdStrings {
    pub ids: Vec<i64>,
    pub values: Vec<String>,
}

/// Rows of string keys and string values, in file order.
#[derive(Debug, Default, PartialEq)]
pub struct StrStrings {
    pub keys: Vec<String>,
    pub values: Vec<String>,
}

/// Rows of string keys and int values, in file order.
#[derive(Debug, Default, PartialEq)]
pub struct StrInts {
    pub keys: Vec<String>,
    pub values: Vec<i64>,
}

/// npcpos.txt's kept rows: id, region id, and the three coordinates as `float()` reads them.
#[derive(Debug, Default, PartialEq)]
pub struct Positions {
    pub npc_ids: Vec<i64>,
    pub regions: Vec<i64>,
    pub x: Vec<f64>,
    pub y: Vec<f64>,
    pub z: Vec<f64>,
}

/// `parse_positions`: rows with five fields whose first two strip to integers.
pub fn npc_positions(data: &[u8]) -> Result<Positions, Fallback> {
    let mut out = Positions::default();
    let mut bad = None;
    rows_of(data, |cols| {
        if cols.len() <= COL_POS_Z || bad.is_some() {
            return;
        }
        let id_text = strip(cols[COL_POS_NPC_ID]);
        let region_text = strip(cols[COL_POS_REGION]);
        if !(is_valid_int(id_text) && is_valid_int(region_text)) {
            return;
        }
        let xyz = (to_float(strip(cols[COL_POS_X])), to_float(strip(cols[COL_POS_Y])), to_float(strip(cols[COL_POS_Z])));
        let (Some(x), Some(y), Some(z)) = xyz else {
            bad = Some(Fallback("a coordinate the C++ parse overflows on"));
            return;
        };
        out.npc_ids.push(to_int(id_text));
        out.regions.push(to_int(region_text));
        out.x.push(x);
        out.y.push(y);
        out.z.push(z);
    })?;
    bad.map_or(Ok(out), Err)
}

/// `parse_codes`: {id -> code name} rows.
pub fn char_codes(data: &[u8]) -> Result<IdStrings, Fallback> {
    let mut out = IdStrings::default();
    rows_of(data, |cols| {
        if cols.len() <= COL_CODE_NAME {
            return;
        }
        let id_text = strip(cols[COL_MODEL_ID]);
        if !is_valid_int(id_text) {
            return;
        }
        let code = strip(cols[COL_CODE_NAME]);
        if !code.is_empty() {
            out.ids.push(to_int(id_text));
            out.values.push(code.to_owned());
        }
    })?;
    Ok(out)
}

/// `parse_models`: {id -> .bsr path} rows.
pub fn char_models(data: &[u8]) -> Result<IdStrings, Fallback> {
    let mut out = IdStrings::default();
    rows_of(data, |cols| {
        if cols.len() <= COL_MODEL_ID {
            return;
        }
        let id_text = strip(cols[COL_MODEL_ID]);
        if !is_valid_int(id_text) {
            return;
        }
        let model = find_model_path(cols);
        if !model.is_empty() {
            out.ids.push(to_int(id_text));
            out.values.push(model.to_owned());
        }
    })?;
    Ok(out)
}

/// `parse_models_by_code`: {code name -> .bsr path} rows whose code starts with `prefix`.
pub fn char_models_by_code(data: &[u8], prefix: &str) -> Result<StrStrings, Fallback> {
    let mut out = StrStrings::default();
    rows_of(data, |cols| {
        if cols.len() <= COL_CODE_NAME {
            return;
        }
        let model = find_model_path(cols);
        if model.is_empty() {
            return;
        }
        let code = strip(cols[COL_CODE_NAME]);
        if code.is_empty() || !code.starts_with(prefix) {
            return;
        }
        out.keys.push(code.to_owned());
        out.values.push(model.to_owned());
    })?;
    Ok(out)
}

/// `parse_org_codes`: {code name -> OrgObjCodeName} rows, `xxx` (any case) and "" naming none.
pub fn char_org_codes(data: &[u8]) -> Result<StrStrings, Fallback> {
    let mut out = StrStrings::default();
    rows_of(data, |cols| {
        if cols.len() <= COL_ORG_CODE_NAME {
            return;
        }
        let code = strip(cols[COL_CODE_NAME]);
        let org = strip(cols[COL_ORG_CODE_NAME]);
        if code.is_empty() || org.is_empty() || equals_lower(org, "xxx") {
            return;
        }
        out.keys.push(code.to_owned());
        out.values.push(org.to_owned());
    })?;
    Ok(out)
}

/// `parse_speeds_by_code`'s rows: code, walk, run.
#[derive(Debug, Default, PartialEq)]
pub struct Speeds {
    pub codes: Vec<String>,
    pub walk: Vec<f64>,
    pub run: Vec<f64>,
}

/// `parse_speeds_by_code`: {code -> [walk, run]} rows whose two columns are valid floats.
pub fn char_speeds_by_code(data: &[u8], prefix: &str) -> Result<Speeds, Fallback> {
    let mut out = Speeds::default();
    let mut bad = None;
    rows_of(data, |cols| {
        if cols.len() <= COL_SPEED_RUN || bad.is_some() {
            return;
        }
        let code = strip(cols[COL_CODE_NAME]);
        if code.is_empty() || !code.starts_with(prefix) {
            return;
        }
        let walk = strip(cols[COL_SPEED_WALK]);
        let run = strip(cols[COL_SPEED_RUN]);
        if !is_valid_float(walk) || !is_valid_float(run) {
            return;
        }
        let (Some(w), Some(r)) = (to_float(walk), to_float(run)) else {
            bad = Some(Fallback("a speed the C++ parse overflows on"));
            return;
        };
        out.codes.push(code.to_owned());
        out.walk.push(w);
        out.run.push(r);
    })?;
    bad.map_or(Ok(out), Err)
}

fn code_int_rows(data: &[u8], prefix: &str, col: usize) -> Result<StrInts, Fallback> {
    let mut out = StrInts::default();
    rows_of(data, |cols| {
        if cols.len() <= col {
            return;
        }
        let code = strip(cols[COL_CODE_NAME]);
        if code.is_empty() || !code.starts_with(prefix) {
            return;
        }
        let value = strip(cols[col]);
        if !is_valid_int(value) {
            return;
        }
        out.keys.push(code.to_owned());
        out.values.push(to_int(value));
    })?;
    Ok(out)
}

/// `parse_country_by_code`: {code -> Country (column 14)}.
pub fn char_country_by_code(data: &[u8], prefix: &str) -> Result<StrInts, Fallback> {
    code_int_rows(data, prefix, COL_COUNTRY)
}

/// `parse_bc_radius_by_code`: {code -> BCRadius (column 50)}.
pub fn char_bc_radius_by_code(data: &[u8], prefix: &str) -> Result<StrInts, Fallback> {
    code_int_rows(data, prefix, COL_BC_RADIUS)
}

/// `parse_name_keys`'s rows {id -> SN_ key}; also `parse_names`' rows before it resolves the key.
pub fn char_name_keys(data: &[u8]) -> Result<IdStrings, Fallback> {
    let mut out = IdStrings::default();
    rows_of(data, |cols| {
        if cols.len() <= COL_MODEL_ID {
            return;
        }
        let id_text = strip(cols[COL_MODEL_ID]);
        if !is_valid_int(id_text) {
            return;
        }
        let key = find_name_key(cols);
        if !key.is_empty() {
            out.ids.push(to_int(id_text));
            out.values.push(key.to_owned());
        }
    })?;
    Ok(out)
}

/// `parse_models_by_name`'s rows before it resolves the key: (model, SN_ key) for every row that
/// has both. `keys` are the models, `values` the name keys.
pub fn char_models_name_keys(data: &[u8]) -> Result<StrStrings, Fallback> {
    let mut out = StrStrings::default();
    rows_of(data, |cols| {
        let model = find_model_path(cols);
        if model.is_empty() {
            return;
        }
        let key = find_name_key(cols);
        if key.is_empty() {
            return;
        }
        out.keys.push(model.to_owned());
        out.values.push(key.to_owned());
    })?;
    Ok(out)
}

// ---------------------------------------------------------------------------------------------
// itemdata*.txt (npc/item_table_reader.gd)
// ---------------------------------------------------------------------------------------------

const ITEM_COL_ID: usize = 1;
const ITEM_COL_CODE_NAME: usize = 2;
const ITEM_COL_NAME: usize = 3;
const ITEM_COL_NAME_STRID: usize = 5;
const ITEM_COL_SELL_PRICE: usize = 31;
const ITEM_COL_MAX_STACK: usize = 57;
const ITEM_COL_TYPE_ID1: usize = 9;
const ITEM_COL_TYPE_ID4: usize = 12;
const ITEM_COL_COUNTRY: usize = 14;
const ITEM_COL_REQ_LEVEL_TYPE1: usize = 32;
const ITEM_COL_REQ_LEVEL1: usize = 33;
const ITEM_COL_MODEL: usize = 52;
const ITEM_COL_DROP_MODEL: usize = 53;
const ITEM_COL_REQ_GENDER: usize = 58;
const ITEM_COL_DURABILITY: usize = 63;
const ITEM_COL_RANGE: usize = 94;
const ITEM_COL_PARAM1: usize = 118;
const ITEM_REQ_LEVEL_PAIRS: usize = 4;
/// The weapon int pairs, in the order `items` stores them: phys atk, mag atk, phys reinforce,
/// mag reinforce, each (min, max).
const ITEM_ATTACK_COLS: [usize; 8] = [95, 97, 100, 102, 105, 107, 109, 111];
const ITEM_COL_ATTACK_RATE: usize = 113;
const ITEM_COL_CRITICAL: usize = 116;
/// The defence float pairs, in the order `items` stores them: phys def, mag def, block.
const ITEM_DEFENCE_COLS: [usize; 6] = [65, 66, 76, 77, 74, 75];
pub const ICON_PREFIX: &str = "icon\\";

/// itemdata's kept rows as columns, one entry (or a fixed group) per row in file order.
#[derive(Debug, Default, PartialEq)]
pub struct Items {
    pub ids: Vec<i64>,
    pub code_names: Vec<String>,
    pub item_names: Vec<String>,
    pub name_strids: Vec<String>,
    pub icon_paths: Vec<String>,
    pub drop_models: Vec<String>,
    /// Every row's `_models_at` list, flattened; `model_counts[row]` entries each.
    pub models: Vec<String>,
    pub model_counts: Vec<i64>,
    pub max_stacks: Vec<i64>,
    pub sell_prices: Vec<i64>,
    pub countries: Vec<i64>,
    pub req_genders: Vec<i64>,
    pub durabilities: Vec<i64>,
    pub attack_rates: Vec<i64>,
    pub criticals: Vec<i64>,
    pub ranges: Vec<i64>,
    pub param1s: Vec<i64>,
    /// 4 a row: TypeID1..4.
    pub type_ids: Vec<i64>,
    /// 4 a row each.
    pub req_types: Vec<i64>,
    pub req_levels: Vec<i64>,
    /// 8 a row: ITEM_ATTACK_COLS' values.
    pub attacks: Vec<i64>,
    /// 6 a row: ITEM_DEFENCE_COLS' values.
    pub defences: Vec<f64>,
}

/// `_int_at`: 0 past the row's end or for a field that does not strip to an integer.
fn int_at(cols: &[&str], col: usize) -> i64 {
    match cols.get(col).map(|c| strip(c)) {
        Some(t) if is_valid_int(t) => to_int(t),
        _ => 0,
    }
}

/// `_float_at`; `None` only where `to_float` is.
fn float_at(cols: &[&str], col: usize) -> Option<f64> {
    match cols.get(col).map(|c| strip(c)) {
        Some(t) if is_valid_float(t) => to_float(t),
        _ => Some(0.0),
    }
}

/// `_model_at` on one field: its stripped text with '/' made '\\' when it ends in ".bsr".
fn model_of(field: &str) -> Option<String> {
    let value = strip(field);
    ends_with_lower(value, ".bsr").then(|| value.replace('/', "\\"))
}

/// `ItemTableReader.parse`'s row loop. The GDScript builds each `Item` from these columns.
pub fn items(data: &[u8]) -> Result<Items, Fallback> {
    let mut o = Items::default();
    let mut bad = None;
    rows_of(data, |cols| {
        if cols.len() <= ITEM_COL_NAME || bad.is_some() {
            return;
        }
        let id_text = strip(cols[ITEM_COL_ID]);
        if !is_valid_int(id_text) {
            return;
        }
        let item_name = strip(cols[ITEM_COL_NAME]);
        // _find_icon_path: the first field that strips to a ".ddj" path.
        let icon = cols.iter().map(|c| strip(c)).find(|t| ends_with_lower(t, ".ddj")).unwrap_or("");
        // A row with neither a name nor an icon tells the player nothing.
        if item_name.is_empty() && icon.is_empty() {
            return;
        }
        let mut defences = [0.0f64; 6];
        for (slot, &col) in defences.iter_mut().zip(ITEM_DEFENCE_COLS.iter()) {
            match float_at(cols, col) {
                Some(v) => *slot = v,
                None => {
                    bad = Some(Fallback("a defence the C++ parse overflows on"));
                    return;
                }
            }
        }
        o.ids.push(to_int(id_text));
        o.code_names.push(strip(cols[ITEM_COL_CODE_NAME]).to_owned());
        o.item_names.push(item_name.to_owned());
        o.name_strids.push(cols.get(ITEM_COL_NAME_STRID).map_or("", |c| strip(c)).to_owned());
        o.icon_paths.push(if icon.is_empty() { String::new() } else { format!("{ICON_PREFIX}{icon}") });
        // _models_at: the column split on ',' without empty pieces, each kept when it is a model.
        let before = o.models.len();
        if let Some(field) = cols.get(ITEM_COL_MODEL) {
            o.models.extend(field.split(',').filter(|t| !t.is_empty()).filter_map(model_of));
        }
        o.model_counts.push((o.models.len() - before) as i64);
        o.drop_models.push(cols.get(ITEM_COL_DROP_MODEL).and_then(|c| model_of(c)).unwrap_or_default());
        let stack = int_at(cols, ITEM_COL_MAX_STACK);
        o.max_stacks.push(if stack > 0 { stack } else { 1 });
        o.sell_prices.push(int_at(cols, ITEM_COL_SELL_PRICE));
        o.type_ids.extend((ITEM_COL_TYPE_ID1..=ITEM_COL_TYPE_ID4).map(|c| int_at(cols, c)));
        o.countries.push(int_at(cols, ITEM_COL_COUNTRY));
        o.req_genders.push(int_at(cols, ITEM_COL_REQ_GENDER));
        for pair in 0..ITEM_REQ_LEVEL_PAIRS {
            o.req_types.push(int_at(cols, ITEM_COL_REQ_LEVEL_TYPE1 + pair * 2));
            o.req_levels.push(int_at(cols, ITEM_COL_REQ_LEVEL1 + pair * 2));
        }
        o.durabilities.push(int_at(cols, ITEM_COL_DURABILITY));
        o.attacks.extend(ITEM_ATTACK_COLS.iter().map(|&c| int_at(cols, c)));
        o.attack_rates.push(int_at(cols, ITEM_COL_ATTACK_RATE));
        o.criticals.push(int_at(cols, ITEM_COL_CRITICAL));
        o.ranges.push(int_at(cols, ITEM_COL_RANGE));
        o.param1s.push(int_at(cols, ITEM_COL_PARAM1));
        o.defences.extend_from_slice(&defences);
    })?;
    bad.map_or(Ok(o), Err)
}

// ---------------------------------------------------------------------------------------------
// The UI string tables (ui/ui_text_table.gd): textuisystem, textdata_object, textquest_speechname
// ---------------------------------------------------------------------------------------------

const UI_COL_SERVICE: usize = 0;
const UI_COL_TOKEN: usize = 1;
const UI_FIRST_LANGUAGE_COL: usize = 3;

/// `_is_usable(field) and _has_latin_letter(field)`.
fn usable_latin(field: &str) -> bool {
    let t = strip(field);
    !t.is_empty() && t != "0" && field.bytes().any(|b| b.is_ascii_alphabetic())
}

fn scan_left_to_right<'a>(cols: &[&'a str], lowest: usize) -> &'a str {
    cols.iter().skip(lowest).find(|c| usable_latin(c)).map_or("", |c| strip(c))
}

/// `_pick_language_column`.
fn pick_language_column<'a>(cols: &[&'a str], preferred: usize) -> &'a str {
    if preferred < cols.len() && usable_latin(cols[preferred]) {
        return strip(cols[preferred]);
    }
    let after = scan_left_to_right(cols, preferred + 1);
    if !after.is_empty() {
        return after;
    }
    scan_left_to_right(cols, UI_FIRST_LANGUAGE_COL)
}

/// UiTextTable's accepted rows, (token, value), in file order and BEFORE its keep-first check
/// (the GDScript applies that as it inserts). Unlike `_lines`, the UI table keeps '\r': a line is
/// split as it stands and each field is stripped. `lang_col` < 0 falls back.
pub fn ui_text_rows(data: &[u8], lang_col: i64) -> Result<StrStrings, Fallback> {
    let Ok(lang) = usize::try_from(lang_col) else {
        return Err(Fallback("negative language column"));
    };
    let mut out = StrStrings::default();
    let Some(text) = decode(data, false)? else {
        return Ok(out);
    };
    let mut cols: Vec<&str> = Vec::new();
    for line in text.split('\n') {
        let clean = strip(line);
        if clean.is_empty() || clean.starts_with("//") || clean.starts_with('#') {
            continue;
        }
        split_tabs(line, &mut cols);
        if cols.len() <= UI_COL_TOKEN {
            continue;
        }
        if to_int(strip(cols[UI_COL_SERVICE])) != 1 {
            continue;
        }
        let token = strip(cols[UI_COL_TOKEN]);
        if token.is_empty() {
            continue;
        }
        let mut val = pick_language_column(&cols, lang);
        if val.is_empty() {
            val = cols.get(lang).map_or("", |c| strip(c));
        }
        out.keys.push(token.to_owned());
        out.values.push(val.to_owned());
    }
    if cfg!(feature = "parity-negative") {
        // The NEGATIVE: the first of a duplicated token dropped (the pre-round-634 "last row
        // wins" rule, once the GDScript's keep-first check sees only the later rows).
        let mut seen = std::collections::HashMap::new();
        for (i, k) in out.keys.iter().enumerate() {
            seen.insert(k.clone(), i);
        }
        let keep: Vec<bool> = out.keys.iter().enumerate().map(|(i, k)| seen[k] == i).collect();
        let mut it = keep.iter();
        out.keys.retain(|_| *it.next().unwrap_or(&true));
        let mut it = keep.iter();
        out.values.retain(|_| *it.next().unwrap_or(&true));
    }
    Ok(out)
}

// ---------------------------------------------------------------------------------------------
// skilleffect.txt (effects/skill_effect_reader.gd `parse_all`)
// ---------------------------------------------------------------------------------------------

const E_CODE: usize = 2;
const E_HIT_EFP: usize = 14;
const A_PRIORITY: usize = 3;
const A_DEFENSE_EFP: usize = 13;
const A_GROUP: usize = 6;
const A_READY: usize = 7;
const A_WAIT: usize = 8;
const A_SHOT: usize = 9;

/// `parse_all`'s rows. The hit rows' codes and every aniset row's code, group and list names are
/// as the file writes them (stripped): the GDScript upper- and lower-cases them, looks the names
/// up in ANI_TYPES and merges the rows, as its own loop does.
#[derive(Debug, Default, PartialEq)]
pub struct SkillEffects {
    pub hit_codes: Vec<String>,
    pub hit_efps: Vec<String>,
    pub set_codes: Vec<String>,
    pub set_groups: Vec<String>,
    pub set_priorities: Vec<i64>,
    /// "" where the row names no DefenseEfp (the GDScript then leaves the key alone).
    pub set_defenses: Vec<String>,
    /// Each row's READY, WAIT and SHOT names, flattened; 3 counts a row.
    pub set_names: Vec<String>,
    pub set_name_counts: Vec<i64>,
}

/// `_hit_row`: (code, .efp) for a SKILL_ row whose column 14 -- or failing that, any field --
/// strips to a ".efp" path.
fn hit_row(cols: &[&str], out: &mut SkillEffects) {
    if cols.len() <= E_CODE {
        return;
    }
    let code = strip(cols[E_CODE]);
    if !code.starts_with("SKILL_") {
        return;
    }
    let mut efp = cols.get(E_HIT_EFP).map_or("", |c| strip(c));
    if !ends_with_lower(efp, ".efp") {
        efp = cols.iter().map(|c| strip(c)).find(|c| ends_with_lower(c, ".efp")).unwrap_or("");
    }
    if !efp.is_empty() && !equals_lower(efp, "none") {
        out.hit_codes.push(code.to_owned());
        out.hit_efps.push(efp.to_owned());
    }
}

/// `_aniset_row` up to its `.to_upper()`: the row's fields, or nothing when it is too short or
/// (in `skillaniset2`) its service column is not a non-zero integer.
fn aniset_row(cols: &[&str], second: bool, out: &mut SkillEffects) {
    // skillaniset rows sit one column left of skillaniset2's (shift -1).
    let at = |col: usize| if second { col } else { col - 1 };
    if cols.len() <= at(A_SHOT) {
        return;
    }
    if second {
        let service = strip(cols[0]);
        if !is_valid_int(service) || to_int(service) == 0 {
            return;
        }
    }
    out.set_codes.push(strip(cols[at(E_CODE)]).to_owned());
    out.set_groups.push(strip(cols[at(A_GROUP)]).to_owned());
    let prio = strip(cols[at(A_PRIORITY)]);
    out.set_priorities.push(if is_valid_int(prio) { to_int(prio) } else { 0 });
    let defense = cols.get(at(A_DEFENSE_EFP)).map_or("", |c| strip(c));
    out.set_defenses.push(if ends_with_lower(defense, ".efp") { defense.to_owned() } else { String::new() });
    for col in [A_READY, A_WAIT, A_SHOT] {
        // _ani_list: split(",", false) -- no empty pieces -- each stripped.
        let before = out.set_names.len();
        out.set_names.extend(cols[at(col)].split(',').filter(|n| !n.is_empty()).map(|n| strip(n).to_owned()));
        out.set_name_counts.push((out.set_names.len() - before) as i64);
    }
}

/// `SkillEffectReader.parse_all`'s loop over `_lines(data)`.
pub fn skill_effects(data: &[u8]) -> Result<SkillEffects, Fallback> {
    let mut out = SkillEffects::default();
    let Some(text) = decode(data, true)? else {
        return Ok(out);
    };
    let mut section = "";
    let mut cols: Vec<&str> = Vec::new();
    for line in text.split('\n') {
        if line.starts_with("#section") {
            // split("\t", false): the second non-empty piece, stripped.
            section = line.split('\t').filter(|p| !p.is_empty()).nth(1).map_or("", strip);
            continue;
        }
        if !line.contains("SKILL_") && !line.contains("SYSTEM_") {
            continue;
        }
        split_tabs(line, &mut cols);
        hit_row(&cols, &mut out);
        if (section == "skillaniset" || section == "skillaniset2") && !strip(line).starts_with("//") {
            aniset_row(&cols, section == "skillaniset2", &mut out);
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// UTF-16LE bytes with the FF FE BOM, as the archive stores the tables.
    fn utf16(text: &str) -> Vec<u8> {
        let mut out = vec![0xFF, 0xFE];
        for u in text.encode_utf16() {
            out.extend_from_slice(&u.to_le_bytes());
        }
        out
    }

    #[test]
    fn godot_int_semantics() {
        for (s, valid, v) in [
            ("123", true, 123),
            ("+5", true, 5),
            ("-17", true, -17),
            ("-", false, 0),
            ("+", false, 0),
            ("", false, 0),
            ("1.9", false, 1),
            ("12a", false, 12),
            ("a1-2", false, 12),
            ("--5", false, 5),
            ("-a-5", false, 5),
            ("9223372036854775807", true, i64::MAX),
            ("9223372036854775808", true, i64::MAX),
            ("-9223372036854775808", true, i64::MIN),
            ("-9223372036854775809", true, i64::MIN),
            ("99999999999999999999", true, i64::MAX),
            ("\u{0661}", false, 0),
        ] {
            assert_eq!(is_valid_int(s), valid, "is_valid_int({s:?})");
            assert_eq!(to_int(s), v, "to_int({s:?})");
        }
    }

    #[test]
    fn godot_float_semantics() {
        for (s, valid) in [
            ("1.5", true),
            ("-2.", true),
            (".5", true),
            ("1e5", true),
            ("1e", true),
            ("1E5", false),
            ("e5", false),
            ("1.5.2", false),
            ("1e+5", true),
            ("1e5-", false),
            ("+", false),
            ("", false),
            ("16", true),
        ] {
            assert_eq!(is_valid_float(s), valid, "is_valid_float({s:?})");
        }
        let bits = |s: &str| to_float(s).map(f64::to_bits);
        assert_eq!(bits("16"), Some(16.0f64.to_bits()));
        assert_eq!(bits("2.5"), Some(2.5f64.to_bits()));
        assert_eq!(bits("-"), Some((-0.0f64).to_bits()));
        assert_eq!(bits(""), Some(0.0f64.to_bits()));
        assert_eq!(bits("abc"), Some(0.0f64.to_bits()));
        assert_eq!(bits("1.5e"), Some(15.0f64.to_bits()), "a dangling e skips the scaling");
        assert_eq!(bits("12x"), Some(12.0f64.to_bits()));
        assert_eq!(bits(" \t7"), Some(7.0f64.to_bits()));
        assert_eq!(bits("1e600"), Some(f64::INFINITY.to_bits()), "the exponent clamps to 511");
        assert_eq!(bits("1e99999999999"), None, "the C++ int overflows here");
        // 0.1 is 1 / 10 here, which is also the correctly rounded value.
        assert_eq!(bits("0.1"), Some(0.1f64.to_bits()));
        // 19+ mantissa digits: only 18 are kept.
        assert_eq!(bits("1234567890123456789"), Some((1.0e9 * 123456789.0 + 12345678.0) * 10.0).map(f64::to_bits));
    }

    #[test]
    fn strip_matches_godot() {
        assert_eq!(strip(" \t\r\x01a b\x20\r"), "a b");
        assert_eq!(strip("\u{a0}x\u{a0}"), "\u{a0}x\u{a0}");
        assert_eq!(strip(""), "");
    }

    #[test]
    fn decode_handles_boms_nul_and_surrogates() {
        assert_eq!(decode(&[], true), Ok(None));
        assert_eq!(decode(&utf16("a\r\nb"), true), Ok(Some("a\nb".into())));
        assert_eq!(decode(&utf16("a\r\nb"), false), Ok(Some("a\r\nb".into())));
        // No BOM at all; and a second BOM (FEFF) after the stripped bytes.
        let plain: Vec<u8> = "xy".encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
        assert_eq!(decode(&plain, true), Ok(Some("xy".into())));
        let mut double = utf16("\u{feff}z");
        assert_eq!(decode(&double, true), Ok(Some("z".into())));
        // FE FF FE FF..: the second BOM read as FFFE byte-swaps the rest (big-endian).
        double = vec![0xFF, 0xFE, 0xFE, 0xFF, 0x00, 0x41];
        assert_eq!(decode(&double, true), Ok(Some("A".into())));
        // Stops at the first NUL; an odd trailing byte is dropped.
        let mut nul = utf16("ab\0cd");
        nul.push(0x41);
        assert_eq!(decode(&nul, true), Ok(Some("ab".into())));
        // A pair decodes; a lone surrogate falls back; an empty decode falls back.
        assert_eq!(decode(&utf16("\u{1F600}"), true), Ok(Some("\u{1F600}".into())));
        assert!(decode(&[0xFF, 0xFE, 0x00, 0xD8, 0x41, 0x00], true).is_err());
        assert!(decode(&[0xFF, 0xFE, 0x00, 0xDC], true).is_err());
        assert!(decode(&[0xFF, 0xFE], true).is_err());
        assert!(decode(&[0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00], true).is_err());
        // A BOM inside the text is handed back (round 671's review): Godot keeps it as a
        // character, and a native string beginning with one would lose it in gdext's UTF-8
        // hand-over. Before or after a byte swap alike.
        assert_eq!(decode(&utf16("1\t5\tX\t\u{feff}a.bsr"), true), Err(Fallback("a byte-order mark inside the text")));
        assert!(decode(&utf16("a\n\u{feff}b"), false).is_err());
        assert!(char_models(&utf16("1\t5\tMOB_X\t\u{feff}mob\\x.bsr\n")).is_err());
        assert!(decode(&[0xFF, 0xFE, 0xFE, 0xFF, 0x00, 0x41, 0xFE, 0xFF], true).is_err());
        // "\r" alone decodes to one character, so it is not "empty" -- it just has no lines.
        assert_eq!(decode(&utf16("\r"), true), Ok(Some(String::new())));
    }

    fn chardata_row(id: &str, code: &str, extra: &[(usize, &str)]) -> String {
        let mut cols = vec![String::new(); 60];
        cols[0] = "1".into();
        cols[1] = id.into();
        cols[2] = code.into();
        for (i, v) in extra {
            cols[*i] = (*v).into();
        }
        cols.join("\t")
    }

    #[test]
    fn characterdata_rows() {
        let text = [
            "// a comment row is just a row without a number",
            &chardata_row(" 1907 ", "CHAR_CH_MAN_ADVENTURER", &[(5, "SN_CHAR_A"), (14, "0"), (46, "16"), (47, "50"), (50, "4"), (52, " char\\china\\a.bsr , b.bsr")]),
            &chardata_row("2000", "MOB_CH_X", &[(4, "XxX"), (8, "SN_MOB_X"), (14, "?"), (46, "1.5"), (47, "x"), (50, "6"), (52, "mob\\X.BSR")]),
            &chardata_row("2000", "MOB_CH_X", &[(4, "MOB_CH_ORG"), (52, "mob\\later.bsr")]),
            "",
            "short\t1",
            &chardata_row("abc", "NPC_NOID", &[(52, "n.bsr")]),
            "1\t3000\tCHAR_TRAILING\t\t\t\t\t\t\t\t\t\t\t\t1\t",
        ]
        .join("\r\n");
        let data = utf16(&text);
        let codes = char_codes(&data).unwrap();
        assert_eq!(codes.ids, vec![1907, 2000, 2000, 3000]);
        assert_eq!(codes.values, vec!["CHAR_CH_MAN_ADVENTURER", "MOB_CH_X", "MOB_CH_X", "CHAR_TRAILING"]);
        let models = char_models(&data).unwrap();
        assert_eq!(models.ids, vec![1907, 2000, 2000], "duplicates stay, in order: the merge keeps the last");
        if cfg!(not(feature = "parity-negative")) {
            assert_eq!(models.values, vec!["char\\china\\a.bsr", "mob\\X.BSR", "mob\\later.bsr"]);
        }
        let by_code = char_models_by_code(&data, "CHAR_").unwrap();
        assert_eq!(by_code.keys, vec!["CHAR_CH_MAN_ADVENTURER"]);
        let all = char_models_by_code(&data, "").unwrap();
        assert_eq!(all.keys, vec!["CHAR_CH_MAN_ADVENTURER", "MOB_CH_X", "MOB_CH_X", "NPC_NOID"]);
        let org = char_org_codes(&data).unwrap();
        assert_eq!((org.keys, org.values), (vec!["MOB_CH_X".to_string()], vec!["MOB_CH_ORG".to_string()]));
        let speeds = char_speeds_by_code(&data, "").unwrap();
        assert_eq!(speeds.codes, vec!["CHAR_CH_MAN_ADVENTURER"], "x is not a float, and a short row is skipped");
        assert_eq!((speeds.walk[0], speeds.run[0]), (16.0, 50.0));
        let country = char_country_by_code(&data, "").unwrap();
        assert_eq!((country.keys.clone(), country.values), (vec!["CHAR_CH_MAN_ADVENTURER".to_string(), "CHAR_TRAILING".to_string()], vec![0, 1]));
        let radius = char_bc_radius_by_code(&data, "MOB_").unwrap();
        assert_eq!(radius.values, vec![6]);
        let keys = char_name_keys(&data).unwrap();
        assert_eq!((keys.ids, keys.values), (vec![1907, 2000], vec!["SN_CHAR_A".to_string(), "SN_MOB_X".to_string()]));
        let mk = char_models_name_keys(&data).unwrap();
        assert_eq!(mk.values, vec!["SN_CHAR_A", "SN_MOB_X"]);
    }

    #[test]
    fn positions() {
        let data = utf16("//npcpos\r\n2001\t25000\t1002.5\t-3\t1020\r\nx\t1\t2\t3\t4\r\n7\t25257\t1e\t \t-\r\n1\t2\t3\t4\r\n");
        let p = npc_positions(&data).unwrap();
        assert_eq!(p.npc_ids, vec![2001, 7]);
        assert_eq!(p.regions, vec![25000, 25257]);
        assert_eq!((p.x[0], p.y[0], p.z[0]), (1002.5, -3.0, 1020.0));
        assert_eq!((p.x[1].to_bits(), p.y[1].to_bits(), p.z[1].to_bits()), (1.0f64.to_bits(), 0.0f64.to_bits(), (-0.0f64).to_bits()));
    }

    #[test]
    fn item_rows() {
        let mut cols = vec![String::new(); 120];
        cols[1] = "4842".into();
        cols[2] = "ITEM_CH_CLOTHES_01".into();
        cols[3] = " Cotton Suit ".into();
        cols[5] = "SN_ITEM_X".into();
        cols[9] = "1".into();
        cols[12] = "3".into();
        cols[31] = "427".into();
        cols[32] = "1".into();
        cols[33] = "5".into();
        cols[52] = "item/a_ba.bsr,,xxx, item/b_ba_fullset.BSR ".into();
        cols[53] = "xxx".into();
        cols[54] = "item\\a.ddj".into();
        cols[57] = "0".into();
        cols[65] = "2.5".into();
        cols[66] = "3".into();
        cols[95] = "15".into();
        cols[97] = "16".into();
        let row = cols.join("\t");
        let nameless = "1\t5\tCODE\t\tx";
        let short = "1\t6\tCODE";
        let data = utf16(&[row.as_str(), nameless, short, "1\t7\tC\tName"].join("\r\n"));
        let it = items(&data).unwrap();
        assert_eq!(it.ids, vec![4842, 7]);
        assert_eq!(it.item_names, vec!["Cotton Suit", "Name"]);
        assert_eq!(it.icon_paths, vec!["icon\\item\\a.ddj", ""]);
        assert_eq!(it.models, vec!["item\\a_ba.bsr", "item\\b_ba_fullset.BSR"]);
        assert_eq!(it.model_counts, vec![2, 0]);
        assert_eq!(it.drop_models, vec!["", ""]);
        assert_eq!(it.max_stacks, vec![1, 1]);
        assert_eq!(it.sell_prices, vec![427, 0]);
        assert_eq!(&it.type_ids[..4], &[1, 0, 0, 3]);
        assert_eq!(&it.req_types[..4], &[1, 0, 0, 0]);
        assert_eq!(&it.req_levels[..4], &[5, 0, 0, 0]);
        assert_eq!(&it.attacks[..2], &[15, 16]);
        assert_eq!(&it.defences[..2], &[2.5, 3.0]);
        assert_eq!(it.defences.len(), 12);
        assert_eq!(it.name_strids, vec!["SN_ITEM_X", ""]);
    }

    #[test]
    fn ui_rows() {
        let data = utf16(
            "// comment\r\n#also\r\n\r\n1\tUIIT_A\t\t\t\t\t\t\t0\tPhy. atk\r\n1\tUIIT_A\t\t\t\t\t\t\tSecond\r\n0\tUIIT_OFF\tx\r\n1\t\tnotoken\r\n\
             1\tUIIT_ZERO\t\t\t\t\t\t\t0\r\n 1.0 \tUIIT_DOT\t\t\tLeft\t\t\t\t\t\r\n1\tUIIT_TRAIL\t\t\t\t\t\t\t\t\t\r\n1",
        );
        let rows = ui_text_rows(&data, 8).unwrap();
        let expect_keys: Vec<&str> = if cfg!(feature = "parity-negative") {
            vec!["UIIT_A", "UIIT_ZERO", "UIIT_DOT", "UIIT_TRAIL"]
        } else {
            vec!["UIIT_A", "UIIT_A", "UIIT_ZERO", "UIIT_DOT", "UIIT_TRAIL"]
        };
        assert_eq!(rows.keys, expect_keys);
        if cfg!(not(feature = "parity-negative")) {
            assert_eq!(rows.values, vec!["Phy. atk", "Second", "0", "Left", ""]);
        }
        assert!(ui_text_rows(&data, -1).is_err());
    }

    #[test]
    fn skill_effect_rows() {
        let data = utf16(
            "#section\tcharacterInfo\r\nCHAR\tSKILL_IN_CHAR_SECTION\tx.efp\r\n\
             #section\t\tskillaniset2\t\r\n\
             1\t0\tSKILL_CH_A\t5\t\t\tblade\tANI_SKILL_1, none,\tANI_WAIT\t\t\t\t\tdef.EFP\r\n\
             0\t0\tSKILL_CH_OFF\t5\t\t\tblade\tANI_SKILL_1\tANI_WAIT\t\r\n\
             1\t0\tskill_ch_low\tx\t\t\tSKILL_G\t\t\t\r\n\
             //1\t0\tSKILL_CH_COMMENTED\t5\t\t\tg\ta\tb\tc\r\n\
             #section\tskillaniset\r\n\
             0\tSKILL_CH_A\t9\t\t\tsword\tANI_X\t\t\r\n\
             0\t0\tSKILL_CH_HIT\t\t\t\t\t\t\t\t\t\t\t\thiteffect\\a.efp\r\n\
             0\t0\tSKILL_CH_SCAN\tnot.efp.txt\tz\\b.EFP\r\n",
        );
        let e = skill_effects(&data).unwrap();
        assert_eq!(e.hit_codes, vec!["SKILL_CH_A", "SKILL_CH_HIT", "SKILL_CH_SCAN"], "col 2 of a skillaniset row is no code");
        assert_eq!(e.hit_efps, vec!["def.EFP", "hiteffect\\a.efp", "z\\b.EFP"]);
        assert_eq!(e.set_codes, vec!["SKILL_CH_A", "skill_ch_low", "SKILL_CH_A", "0"], "a skillaniset row reads its code one column left");
        assert_eq!(e.set_groups[1], "SKILL_G");
        assert_eq!(e.set_groups[0], "blade");
        assert_eq!(e.set_priorities[..3], [5, 0, 9]);
        assert_eq!(e.set_defenses[0], "def.EFP");
        assert_eq!(&e.set_name_counts[..3], &[2, 1, 0]);
        assert_eq!(&e.set_names[..3], &["ANI_SKILL_1", "none", "ANI_WAIT"]);
    }

    /// Truncated and random input never panics, and every reader answers.
    #[test]
    fn truncated_and_random_input() {
        let real = utf16(&[chardata_row("1", "CHAR_A", &[(52, "a.bsr"), (5, "SN_A")]), "1\tUIIT\t\t\t\t\t\t\tx".into()].join("\r\n"));
        let mut seed: u64 = 0x9E37_79B9_7F4A_7C15;
        let mut next = || {
            seed ^= seed << 13;
            seed ^= seed >> 7;
            seed ^= seed << 17;
            seed
        };
        let mut inputs: Vec<Vec<u8>> = (0..=real.len()).map(|n| real[..n].to_vec()).collect();
        for len in [1usize, 2, 3, 17, 256, 4097] {
            for _ in 0..40 {
                inputs.push((0..len).map(|_| next() as u8).collect());
                // Random UTF-16 drawn from the characters a table uses most.
                let alphabet = [0x09u16, 0x0A, 0x0D, 0x20, 0x2C, 0x2E, 0x30, 0x31, 0x2D, 0x65, 0x53, 0x4E, 0x5F, 0xD800, 0xDC00, 0xFEFF, 0];
                inputs.push((0..len).flat_map(|_| alphabet[(next() % alphabet.len() as u64) as usize].to_le_bytes()).collect());
            }
        }
        for data in &inputs {
            let _ = npc_positions(data);
            let _ = char_codes(data);
            let _ = char_models(data);
            let _ = char_models_by_code(data, "");
            let _ = char_org_codes(data);
            let _ = char_speeds_by_code(data, "");
            let _ = char_country_by_code(data, "");
            let _ = char_bc_radius_by_code(data, "");
            let _ = char_name_keys(data);
            let _ = char_models_name_keys(data);
            let _ = items(data);
            let _ = ui_text_rows(data, 8);
            let _ = ui_text_rows(data, 0);
        }
    }
}
