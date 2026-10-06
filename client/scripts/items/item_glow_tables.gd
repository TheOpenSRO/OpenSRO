extends RefCounted
class_name ItemGlowTables

## The tables the weapon and shield glow is chosen from (round 734,
## docs/protocol/weapon_glow.md §1), read from the player's Media.pk2 at
## runtime as the client's two loaders read them (READ; both are called from
## `Client_LoadAllRefData`, 0x846750..0x84676e):
##
## - `UI_ALCHEMYBOX::FUN_00a9f2e0`: `resinfo\itemoption.txt`, item code name
##   -> glow type number, and `resinfo\itemtypenumber.txt`, type number -> its
##   glow rows, one per plus threshold (GlowRow);
## - `UI_ALCHEMYBOX::FUN_00aa0270`, called twice into one map:
##   `resinfo\itemrare.txt` first, then `resinfo\itemoptionefp.txt`, item code
##   name -> its particle rows (ParticleRow; itemrare.txt since round 740).
##
## **Inheritance through OrgObjCodeName (round 740, READ in both loaders).**
## Before parsing, each loader walks the item table and groups every weapon
## or shield (inherits_glow) whose OrgObjCodeName is not empty under that
## name. After parsing, for each group in name order, the group's name is
## looked up as a code name; if that item has a type (a particle list), every
## member of the group that has none gets the same type (the SAME list: the
## map holds a vector pointer, so a later file's rows for either land in
## both). inherit() replays this over the item rows it is given.
##
## The client keys the maps by RefID, the code name resolved through the item
## table; keyed here by the code name itself, which names the same item (OURS:
## compared in upper case; MEASURED round 740: no two item rows share a code
## name, even ignoring case).
##
## The lookups are the client's own:
## - glow_row: the row with the HIGHEST threshold <= plus, none for plus 0
##   (READ: `FUN_00a5f3e0` asks only when plus != 0, `FUN_00a93900` keeps
##   `row[0] <= plus && row[0] > best`);
## - particle_rows: every row with min <= plus <= max, at any plus, 0 too
##   (READ, FUN_00a5f3e0: the particle loop is outside the plus test).
## The plus is the u8 the character holds per slot (`CObjCharacter+0x3c +
## slot*0xc`): for your own gear the item's +0x8c byte, OptLevel plus the
## advanced elixir (round 734 READ, weapon_glow.md §5).

const OPTION_PATH := "resinfo\\itemoption.txt"
const TYPE_PATH := "resinfo\\itemtypenumber.txt"
const EFP_PATH := "resinfo\\itemoptionefp.txt"
## The seal particles (round 740): `FUN_00aa0270` is called with
## `resinfo\itemrare.txt` at 0x84675f, before itemoptionefp.txt at 0x84676e
## (READ: the pushed strings 0xdd30f8 and 0xdd30dc). Its rows have five
## columns and no plus range, so they show at every plus.
const RARE_PATH := "resinfo\\itemrare.txt"

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

var _direct_types := {}  # code name (upper) -> type number, itemoption.txt's own
var _types := {}      # code name (upper) -> type number, inherited ones too
var _rows := {}       # type number -> Array of GlowRow
## code name (upper) -> Array of ParticleRow. An item that inherited shares
## its base's Array (the client's map holds a vector pointer).
var _particles := {}
## Each particle file's rows in file order, [code name (upper), ParticleRow],
## one entry per load call (itemrare.txt, then itemoptionefp.txt), so the
## inheritance can be replayed call by call.
var _particle_calls: Array = []
## OrgObjCodeName (as written) -> {member code name (upper): true}: the
## groups of weapons and shields inherit() has seen.
var _groups := {}
## Every item code name (upper) inherit() has been given (round 746, the
## review's finding 3): the client resolves a group's name as a code name in
## its item walk's map first (READ, FUN_00aa0270 via FUN_004f19f0, and
## FUN_00a9f2e0 the same), and a table row whose code is no item never enters
## its maps. So a group whose name is not an item's code gives nothing.
var _item_codes := {}
## How many items gained a type, a particle list, through inheritance.
var inherited_types := 0
var inherited_particles := 0
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
	# The client's order (READ, above): itemrare.txt's particle rows before
	# itemoptionefp.txt's.
	for p in [OPTION_PATH, TYPE_PATH, RARE_PATH, EFP_PATH]:
		var e := ObjectLoader.find_file(media, p)
		if e == null:
			continue
		found += 1
		var bytes := media.read_file(e)
		match p:
			OPTION_PATH: t.load_options(bytes)
			TYPE_PATH: t.load_types(bytes)
			RARE_PATH, EFP_PATH: t.load_particles(bytes)
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
		_direct_types[c[0].to_upper()] = int(c[1])
	_rebuild_types()
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

## One particle file, one call of the client's loader: its rows go after
## those of the files loaded before it (itemrare.txt, then itemoptionefp.txt).
func load_particles(bytes: PackedByteArray) -> ItemGlowTables:
	var file_rows: Array = []
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
		file_rows.append([c[0].to_upper(), p])
	_particle_calls.append(file_rows)
	_rebuild_particles()
	return self

# --- inheritance through OrgObjCodeName (round 740) ---------------------------

## Whether an item joins its OrgObjCodeName's group: the type-word tests both
## loaders make before reading +0x40 (READ, `FUN_00a9f2e0` 0xa9f45b..0xa9f4d7,
## the same in `FUN_00aa0270`): not Bionic (`w & 2`), TypeID1 3 (`b & 0x1c ==
## 0xc`), TypeID2 1 (`b & 0x60 == 0x20`), and TypeID3 6 (`w & 0x780 ==
## 0x300`, a weapon), or TypeID3 4 (`== 0x200`) with TypeID4 (`w >> 11`) 1 or
## 2 (a shield). The word is packed from the columns as characterdata.md
## gives it (bit 0 CashItem, 1 Bionic, 2-4 TypeID1, 5-6 TypeID2, 7-10
## TypeID3, 11-15 TypeID4), and the client's tests are made on it as written.
static func inherits_glow(cash_item: int, bionic: int, type_ids: PackedInt32Array) -> bool:
	if type_ids.size() < 4:
		return false
	var w := (cash_item & 1) | ((bionic & 1) << 1) | ((type_ids[0] & 7) << 2) | ((type_ids[1] & 3) << 5) \
		| ((type_ids[2] & 15) << 7) | ((type_ids[3] & 31) << 11)
	var b := w & 0xFF
	if (w & 2) != 0 or (b & 0x1c) != 0xc or (b & 0x60) != 0x20:
		return false
	if (w & 0x780) == 0x300:
		return true
	return (w & 0x780) == 0x200 and ((w >> 11) == 1 or (w >> 11) == 2)

## Adds the groups of `items` (id -> ItemTableReader.Item: its code name,
## OrgObjCodeName, CashItem, Bionic and TypeIDs) and replays the inheritance.
## An item whose OrgObjCodeName is empty (`xxx` in the table) joins none
## (READ: the +0x54 length test). Members already seen add nothing, so a
## partial table and then the whole one (the world's seven parts, then
## CharacterAppearance's full load) end where the whole one alone would.
## Returns the members added.
func inherit(items: Dictionary) -> int:
	var added := 0
	var new_codes := 0
	for id in items:
		var it: ItemTableReader.Item = items[id]
		if it == null:
			continue
		var code := it.code_name.to_upper()
		if code != "" and not _item_codes.has(code):
			_item_codes[code] = true
			new_codes += 1
		if it.org_code_name == "" or not inherits_glow(it.cash_item, it.bionic, it.type_ids):
			continue
		if not _groups.has(it.org_code_name):
			_groups[it.org_code_name] = {}
		var g: Dictionary = _groups[it.org_code_name]
		var key := it.code_name.to_upper()
		if not g.has(key):
			g[key] = true
			added += 1
	# A group named by an item seen only now resolves now (the review's
	# finding 3): rebuild when new item codes arrive too.
	if added > 0 or (new_codes > 0 and not _groups.is_empty()):
		_rebuild_types()
		_rebuild_particles()
		print("ItemGlowTables: %d weapon(s)/shield(s) in %d OrgObjCodeName group(s); %d inherit a glow type, %d a particle list" % [
			group_member_count(), _groups.size(), inherited_types, inherited_particles])
	return added

## The groups' names in the client's order: its map is keyed by the wide
## string, so ordinal order (OURS: String's < compares code points, the same
## order for these ASCII names). The order matters only when a group's name
## item itself inherits (MEASURED round 740: none does).
func _group_names() -> Array:
	var names := _groups.keys()
	names.sort()
	return names

## The glow types' last step (READ, FUN_00a9f2e0 from 0xa9f940): for each
## group, the type its name's item has by then (one inherited from an earlier
## group counts), given to each member that has none.
func _rebuild_types() -> void:
	_types = _direct_types.duplicate()
	inherited_types = 0
	for org in _group_names():
		var base := String(org).to_upper()
		if not _item_codes.has(base) or not _types.has(base):
			continue
		for key in _groups[org]:
			if not _types.has(key):
				_types[key] = _types[base]
				inherited_types += 1

## The particle map, call by call (READ, FUN_00aa0270): a file's rows go to
## the item's list (made at its first row, or the one it holds already, which
## may be a base's it shares: asm 0xaa090f, the append at 0xaa0ae0 on that
## pointer), then each group's members with no list share their name item's
## (0xaa0cf1, the base's pointer inserted).
func _rebuild_particles() -> void:
	_particles = {}
	inherited_particles = 0
	var names := _group_names()
	for file_rows in _particle_calls:
		for pair in file_rows:
			var key: String = pair[0]
			if not _particles.has(key):
				_particles[key] = []
			(_particles[key] as Array).append(pair[1])
		for org in names:
			var base := String(org).to_upper()
			if not _item_codes.has(base) or not _particles.has(base):
				continue
			for member in _groups[org]:
				if not _particles.has(member):
					_particles[member] = _particles[base]
					inherited_particles += 1

## The weapons and shields in a group, over every group.
func group_member_count() -> int:
	var n := 0
	for org in _groups:
		n += (_groups[org] as Dictionary).size()
	return n

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
