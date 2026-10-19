extends RefCounted
class_name CosTable

## Round 795: the COS rows of characterdata -- every TypeID 1/2/3/x row, the
## rides (TypeID4 1), transports (2), growth and fellow pets (3), ability
## pets (4) and guild soldiers (5) -- which the spawn reader (CosSpawnNet:
## the record's tail hangs on TypeID4), the COS windows and the bodies read.
## Columns (0-based, MEASURED on Media.pk2's parts, docs/protocol/
## characterdata.md): 1 ID, 2 CodeName, 4 OrgObjCodeName, 5 NameStrID, 6
## DescStrID (a growth pet row's next level), 9..12 TypeID1..4, 46 walk, 47
## run, 50 BCRadius, 52 the model, 54 the icon, 57 Lvl, 59 MaxHP.

const COL_ID := 1
const COL_CODE := 2
const COL_ORG := 4
const COL_NAME_KEY := 5
const COL_NEXT := 6
const COL_TYPE1 := 9
const COL_TYPE4 := 12
const COL_WALK := 46
const COL_RUN := 47
const COL_BC := 50
const COL_MODEL := 52
const COL_ICON := 54
const COL_LEVEL := 57
const COL_MAX_HP := 59

class Row:
	var id: int
	var code := ""
	var org := ""
	var name_key := ""
	var next_code := ""
	var type4: int
	var walk: float
	var run: float
	var bc: int
	## The model as the column names it ("cos\p_wolf_01.bsr"), the form the
	## monsters' and NPCs' body loaders take (the client prefixes "res\").
	var model := ""
	## The icon, under "icon\" (cos\cos_p_wolf_01.ddj -> icon\cos\...).
	var icon := ""
	var level: int
	var max_hp: int

var by_id := {}
var by_code := {}

## A RefObjID's row, or null.
func row(id: int) -> Row:
	return by_id.get(id)

## A RefObjID's TypeID4, 0 when it is no COS.
func kind_of(id: int) -> int:
	var r: Row = by_id.get(id)
	return r.type4 if r != null else 0

func size() -> int:
	return by_id.size()

## Parses one characterdata part's COS rows into self (a later part's row
## replaces an earlier one's, as the client's loader keeps the last).
func parse(data: PackedByteArray) -> void:
	for line in NpcTableReader._lines(data):
		if not line.contains("\tCOS_"):
			continue
		var cols := line.split("\t")
		if cols.size() <= COL_MAX_HP:
			continue
		if cols[COL_TYPE1] != "1" or cols[COL_TYPE1 + 1] != "2" or cols[COL_TYPE1 + 2] != "3":
			continue
		var r := Row.new()
		r.id = cols[COL_ID].to_int()
		r.code = cols[COL_CODE].strip_edges()
		r.org = _text(cols[COL_ORG])
		r.name_key = _text(cols[COL_NAME_KEY])
		r.next_code = _text(cols[COL_NEXT])
		r.type4 = cols[COL_TYPE4].to_int()
		r.walk = cols[COL_WALK].to_float()
		r.run = cols[COL_RUN].to_float()
		r.bc = cols[COL_BC].to_int()
		var model := _text(cols[COL_MODEL])
		if model != "":
			r.model = model.split(",")[0].strip_edges()
		var icon := _text(cols[COL_ICON])
		if icon != "":
			r.icon = "icon\\" + icon
		r.level = cols[COL_LEVEL].to_int()
		r.max_hp = cols[COL_MAX_HP].to_int()
		if r.id <= 0 or r.code == "":
			continue
		by_id[r.id] = r
		by_code[r.code] = r
	# The Org fallback for a row with no model of its own (the client's own
	# rule, characterdata.md "The model of a row with none").
	for id in by_id:
		var r: Row = by_id[id]
		if r.model == "" and r.org != "":
			var o: Row = by_code.get(r.org)
			if o != null:
				r.model = o.model

static func _text(s: String) -> String:
	var t := s.strip_edges()
	return "" if t == "xxx" else t
