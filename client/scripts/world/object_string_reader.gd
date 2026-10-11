extends RefCounted
class_name ObjectStringReader

## Data.pk2's `navmesh\objectstring.ifo` (round 774): the named points of the
## world's event zones -- among them each walk-in teleport's centre (round
## 773, docs/protocol/dungeon.md "Walk-in teleports"; the server's twin is
## cmd/export-refdata's readObjectStrings).
##
## MEASURED (the user's Data.pk2): text, "JMXVOBJI1000", a count, then one
## line per point: `uid 0x00000000 rx rz x y z yaw "NAME"`, the four floats
## as hex bit patterns. The region id is (rz << 8) | rx -- rz 128 for a
## dungeon, 0x80xx -- and x, y, z the point, region-local in the field,
## dungeon space in a dungeon. 523 lines; in the field, the two whose name is
## a teleportdata codename are the two open-world walk-ins
## (GATE_DUNGEON_DH_IN, GATE_JINSI_OUT), the rest are other events' points
## (safe zones, fortress structures).

const MAGIC := "JMXVOBJI1000"

class Entry:
	var name: String
	## The region id, (rz << 8) | rx.
	var region: int
	var position := Vector3.ZERO
	var yaw: float

	## The client's region (x, y) -- `RealTerrain_<x>_<y>`, the id's high and
	## low bytes (TeleportReader.Building's region_x / region_y).
	func region_xy() -> Vector2i:
		return Vector2i((region >> 8) & 0xFF, region & 0xFF)

	func is_dungeon() -> bool:
		return region & 0x8000 != 0

## The file's entries in file order, or [] when it is not one (a bad line
## refuses the whole file, as the export does).
static func parse(data: PackedByteArray) -> Array:
	var lines := data.get_string_from_ascii().replace("\r", "").split("\n")
	if lines.size() < 2 or lines[0].strip_edges() != MAGIC or not lines[1].strip_edges().is_valid_int():
		return []
	var want := int(lines[1].strip_edges())
	var out: Array = []
	for i in range(2, lines.size()):
		var line := lines[i].strip_edges()
		if line == "":
			continue
		var q := line.find("\"")
		if q < 0 or not line.ends_with("\"") or q == line.length() - 1:
			return []
		var f := line.substr(0, q).split(" ", false)
		if f.size() != 8 or not f[2].is_valid_int() or not f[3].is_valid_int():
			return []
		var rx := int(f[2])
		var rz := int(f[3])
		if rx < 0 or rx > 0xFF or rz < 0 or rz > 0xFF:
			return []
		var v := PackedFloat32Array()
		for k in range(4, 8):
			var hex := f[k].to_lower().trim_prefix("0x")
			if not hex.is_valid_hex_number():
				return []
			v.append(_float_of_bits(hex.hex_to_int()))
		var e := Entry.new()
		e.name = line.substr(q + 1, line.length() - q - 2)
		e.region = (rz << 8) | rx
		e.position = Vector3(v[0], v[1], v[2])
		e.yaw = v[3]
		out.append(e)
	if out.size() != want:
		return []
	return out

static func _float_of_bits(bits: int) -> float:
	var b := PackedByteArray()
	b.resize(4)
	b.encode_u32(0, bits & 0xFFFFFFFF)
	return b.decode_float(0)
