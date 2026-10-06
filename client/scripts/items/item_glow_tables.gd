extends RefCounted
class_name ItemGlowTables

## The three tables the weapon and shield glow is chosen from (round 734,
## docs/protocol/weapon_glow.md §1), read from the player's Media.pk2 at
## runtime as `UI_ALCHEMYBOX::FUN_00a9f2e0` reads them (READ):
##
## - `resinfo\itemoption.txt`: item code name -> glow type number;
## - `resinfo\itemtypenumber.txt`: type number -> its glow rows, one per plus
##   threshold (GlowRow);
## - `resinfo\itemoptionefp.txt`: item code name -> its particle rows
##   (ParticleRow).
##
## The client keys the first and third by RefID, the code name resolved
## through the item table; keyed here by the code name itself, which names
## the same item (OURS: compared in upper case).
##
## The lookups are the client's own:
## - glow_row: the row with the HIGHEST threshold <= plus, none for plus 0
##   (READ: `FUN_00a5f3e0` asks only when plus != 0, `FUN_00a93900` keeps
##   `row[0] <= plus && row[0] > best`);
## - particle_rows: every row with min <= plus <= max (READ, FUN_00a5f3e0).
## The plus is the u8 the character holds per slot (`CObjCharacter+0x3c +
## slot*0xc`): for your own gear the item's +0x8c byte, OptLevel plus the
## advanced elixir (round 734 READ, weapon_glow.md §5).

const OPTION_PATH := "resinfo\\itemoption.txt"
const TYPE_PATH := "resinfo\\itemtypenumber.txt"
const EFP_PATH := "resinfo\\itemoptionefp.txt"

## D3DTEXTUREOP values the glow rows name (col 5 and col 6).
const OP_MODULATE := 4
const OP_MODULATE2X := 5
const OP_ADD := 7
const OP_ADDSIGNED2X := 9

## One `itemtypenumber.txt` row (the 0x4c-byte row at 0xa9f2e0, READ).
class GlowRow:
	var type_number: int = 0
	## The plus threshold (+0x00, a byte).
	var plus: int = 0
	## The UV scroll, texture units per 20 ms (+0x04): the offset grows by
	## ms x uv / 20.0 (READ, CRTModProgEquipPow::vslot_002).
	var uv := Vector2.ZERO
	## The option texture, in Data.pk2 (+0x0c).
	var texture: String = ""
	## Stage 0's COLOROP, MODULATE or MODULATE2X (+0x28).
	var op0: int = OP_MODULATE
	## Stage 1's COLOROP, ADD or ADDSIGNED2X (+0x29).
	var op1: int = OP_ADD
	## The pulse's two colours (+0x2c, +0x38), 0..1 as written.
	var color1 := Vector3.ONE
	var color2 := Vector3.ONE
	## Milliseconds from one colour to the other (+0x44); a full cycle is two.
	var period_ms: int = 0
	## The alpha-test flag (+0x48): 1 tests alpha >= 1/255.
	var alpha_test: bool = false

	## The scroll in texture units a second: uv x 1000 / 20 = uv x 50.
	func uv_per_second() -> Vector2:
		return uv * (1000.0 / UV_DIVISOR)

## The divisor of the UV step: `_DAT_00e1b830` = 20.0 (MEASURED, .rdata).
const UV_DIVISOR := 20.0
## The colour scale: `_DAT_00d83108` = 255.0 (MEASURED).
const COLOR_SCALE := 255.0

## One `itemoptionefp.txt` row (READ, the parser at 0xaa0622..).
class ParticleRow:
	var efp: String = ""
	## col 3 / 100.0 (`_DAT_00e1b7d8`): the effect's uniform scale (round 734
	## READ: CRTModParticle +0xc0 -> CEFEffect::vslot_010).
	var scale: float = 1.0
	var bone: String = ""
	## col 5, `none` (every row) -> zero.
	var offset := Vector3.ZERO
	var min_plus: int = 0
	var max_plus: int = 0xFF

## The tables the world loaded (World3D, CharacterAppearance); null before.
static var shared: ItemGlowTables = null

var _types := {}      # code name (upper) -> type number
var _rows := {}       # type number -> Array of GlowRow
var _particles := {}  # code name (upper) -> Array of ParticleRow
## Lines that did not parse, per table, for the load's log line.
var skipped := {"option": 0, "type": 0, "efp": 0}

## The tables from `media` (Media.pk2), the shared copy once one is loaded.
## Null when the archive has none of the three.
static func for_archive(media: Pk2Reader) -> ItemGlowTables:
	if shared != null:
		return shared
	if media == null:
		return null
	var t := ItemGlowTables.new()
	var found := 0
	for p in [OPTION_PATH, TYPE_PATH, EFP_PATH]:
		var e := ObjectLoader.find_file(media, p)
		if e == null:
			continue
		found += 1
		var bytes := media.read_file(e)
		match p:
			OPTION_PATH: t.load_options(bytes)
			TYPE_PATH: t.load_types(bytes)
			EFP_PATH: t.load_particles(bytes)
	if found == 0:
		return null
	shared = t
	print("ItemGlowTables: %d item(s) with a glow type, %d type(s) with %d row(s), %d item(s) with particles (skipped %s)" % [
		t._types.size(), t._rows.size(), t.row_count(), t._particles.size(), str(t.skipped)])
	return t

## The file's lines: CRLF ends, `//` comment lines and blank ones dropped.
## ASCII as the client reads it; the one comment in EUC-KR is dropped
## whole, so its bytes never reach a decoder. A UTF-16LE file (a BOM) is
## read too (OURS: no retail table is one).
static func _lines(bytes: PackedByteArray) -> PackedStringArray:
	var text := ""
	if bytes.size() >= 2 and bytes[0] == 0xFF and bytes[1] == 0xFE:
		text = bytes.slice(2).get_string_from_utf16()
	else:
		text = bytes.get_string_from_ascii()
	var out := PackedStringArray()
	for line in text.replace("\r", "").split("\n"):
		var s := line.strip_edges()
		if s == "" or s.begins_with("//"):
			continue
		out.append(line)
	return out

## The tab-separated columns, each trimmed (`1 ` in itemtypenumber's first
## column reads 1, as atol does).
static func _cols(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	for c in line.split("\t"):
		out.append(c.strip_edges())
	return out

## `a,b[,c]` as floats (FUN_00a76c50 / FUN_00a76cf0); a missing or
## non-numeric part reads 0.
static func _floats(s: String, n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var parts := s.split(",")
	for i in n:
		var p := parts[i].strip_edges() if i < parts.size() else ""
		out.append(float(p) if p.is_valid_float() or p.is_valid_int() else 0.0)
	return out

func load_options(bytes: PackedByteArray) -> ItemGlowTables:
	for line in _lines(bytes):
		var c := _cols(line)
		if c.size() < 2 or c[0] == "" or not c[1].is_valid_int():
			skipped["option"] += 1
			continue
		_types[c[0].to_upper()] = int(c[1])
	return self

func load_types(bytes: PackedByteArray) -> ItemGlowTables:
	for line in _lines(bytes):
		var c := _cols(line)
		if c.size() < 10 or not c[0].is_valid_int() or not c[1].is_valid_int():
			skipped["type"] += 1
			continue
		var r := GlowRow.new()
		r.type_number = int(c[0])
		r.plus = int(c[1]) & 0xFF
		var uv := _floats(c[2], 2)
		r.uv = Vector2(uv[0], uv[1])
		r.texture = c[3]
		r.op0 = int(c[4])
		r.op1 = int(c[5])
		var a := _floats(c[6], 3)
		var b := _floats(c[7], 3)
		r.color1 = Vector3(a[0], a[1], a[2])
		r.color2 = Vector3(b[0], b[1], b[2])
		r.period_ms = int(c[8])
		r.alpha_test = int(c[9]) != 0
		if not _rows.has(r.type_number):
			_rows[r.type_number] = []
		(_rows[r.type_number] as Array).append(r)
	return self

func load_particles(bytes: PackedByteArray) -> ItemGlowTables:
	for line in _lines(bytes):
		var c := _cols(line)
		if c.size() < 4 or c[0] == "" or c[1] == "":
			skipped["efp"] += 1
			continue
		var p := ParticleRow.new()
		p.efp = c[1]
		p.scale = (float(c[2]) if c[2].is_valid_float() or c[2].is_valid_int() else 0.0) / 100.0
		p.bone = c[3]
		if c.size() > 4 and c[4].to_lower() != "none":
			var o := _floats(c[4], 3)
			p.offset = Vector3(o[0], o[1], o[2])
		# READ: 0 when the column is missing, 0xFF for the max; the eighth
		# column is never read (the loop takes seven tokens).
		p.min_plus = (int(c[5]) & 0xFF) if c.size() > 5 and c[5].is_valid_int() else 0
		p.max_plus = (int(c[6]) & 0xFF) if c.size() > 6 and c[6].is_valid_int() else 0xFF
		var key := c[0].to_upper()
		if not _particles.has(key):
			_particles[key] = []
		(_particles[key] as Array).append(p)
	return self

## The item's glow type number, 0 for none.
func type_of(code_name: String) -> int:
	return int(_types.get(code_name.to_upper(), 0))

## The glow row for `code_name` at `plus` (a u8), or null: no glow at plus
## 0, for an item with no type, or below the lowest threshold (READ above).
func glow_row(code_name: String, plus: int) -> GlowRow:
	plus = plus & 0xFF
	if plus == 0:
		return null
	var rows: Array = _rows.get(type_of(code_name), [])
	var best: GlowRow = null
	for r in rows:
		var g := r as GlowRow
		if g.plus <= plus and (best == null or g.plus > best.plus):
			best = g
	return best

## The particle rows for `code_name` at `plus`: min <= plus <= max.
func particle_rows(code_name: String, plus: int) -> Array:
	plus = plus & 0xFF
	var out: Array = []
	for p in _particles.get(code_name.to_upper(), []):
		var r := p as ParticleRow
		if r.min_plus <= plus and plus <= r.max_plus:
			out.append(r)
	return out

func row_count() -> int:
	var n := 0
	for k in _rows:
		n += (_rows[k] as Array).size()
	return n

func item_count() -> int:
	return _types.size()

# --- the pulse ------------------------------------------------------------------

## The pulse's position 0..1 at `ms` milliseconds since the mod was made
## (READ, CRTModProgEquipPow::vslot_002, the direction +0xd8 starting at 1
## in the constructor FxModManager::FUN_00c847f0): colour 1 to colour 2 over
## `period_ms`, then back. The constructor's colour is colour 1 (vslot_001).
static func pulse_t(ms: float, period_ms: int) -> float:
	if period_ms <= 0:
		return 0.0
	var p := float(period_ms)
	var phase := fmod(ms, 2.0 * p) / p
	return phase if phase <= 1.0 else 2.0 - phase

## The TEXTUREFACTOR's colour at pulse `t`: round(lerp(c1, c2, t) x 255) per
## channel, as 0..255 (READ).
static func tfactor(c1: Vector3, c2: Vector3, t: float) -> Vector3i:
	var c := c1.lerp(c2, t) * COLOR_SCALE
	return Vector3i(int(roundf(c.x)) & 0xFF, int(roundf(c.y)) & 0xFF, int(roundf(c.z)) & 0xFF)

## The glow's display colour for one texel (the stage maths, weapon_glow.md
## §2.2): stage 0 `op0(option, TFACTOR)`, stage 1 `op1(item, stage 0)`, each
## clamped to 0..1 as fixed-function D3D9 does. `tf` is 0..255.
static func glow_colour(item: Vector3, option: Vector3, tf: Vector3i, op0: int, op1: int) -> Vector3:
	var f := Vector3(tf.x, tf.y, tf.z) / COLOR_SCALE
	var s0 := option * f * (2.0 if op0 == OP_MODULATE2X else 1.0)
	s0 = s0.clamp(Vector3.ZERO, Vector3.ONE)
	var out := item + s0
	if op1 == OP_ADDSIGNED2X:
		out = (item + s0 - Vector3.ONE * 0.5) * 2.0
	return out.clamp(Vector3.ZERO, Vector3.ONE)
