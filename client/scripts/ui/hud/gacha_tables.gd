extends RefCounted
class_name GachaTables

## Magic POP's tables as the client reads them (round 838, lane 5; READ
## sro_client.exe, docs/protocol/magic_pop.md):
##
## - gachaitemset.txt (c:0x744bd0): Service (a row of 0 is skipped), Set_ID,
##   RefItemID, Ratio, Count, GachaID, Visible (parsed and dropped) and the
##   free params, which the client does not keep;
## - gachanpcmap.txt (c:0x745530): Service, RefNpcID, the prize set, the
##   consolation set;
## - refgachatreeforclientuidata.txt: Service, TypeID1..4, the class id and
##   its name key, the type id and its name key, and a last column -- the
##   select window's combo boxes.
##
## The prize list (c:0x748a30) is the NPC's prize set (the map's third
## column), filtered by the select window's choice, as {ref, gacha id,
## count} entries, twelve to a page.

const ITEM_SET := "server_dep\\silkroad\\textdata\\gachaitemset.txt"
const NPC_MAP := "server_dep\\silkroad\\textdata\\gachanpcmap.txt"
const TREE := "server_dep\\silkroad\\textdata\\refgachatreeforclientuidata.txt"

class Prize:
	var set_id: int
	var ref_id: int
	var ratio: int
	var count: int
	var gacha_id: int

class Kind:
	var types: PackedInt32Array
	var class_id: int
	var class_key: String
	var type_id: int
	var type_key: String

var prizes: Array = []        # Prize, file order
var machines: Dictionary = {} # npc ref id -> [prize set, consolation set]
var kinds: Array = []         # Kind, file order

func load(read: Callable) -> GachaTables:
	parse_items(read.call(ITEM_SET))
	parse_map(read.call(NPC_MAP))
	parse_tree(read.call(TREE))
	return self

static func _int(cols: PackedStringArray, i: int) -> int:
	return int(cols[i].strip_edges()) if i < cols.size() and cols[i].strip_edges().is_valid_int() else 0

static func _live(cols: PackedStringArray, need: int) -> bool:
	return cols.size() >= need and cols[0].strip_edges().is_valid_int() and int(cols[0].strip_edges()) != 0

func parse_items(data: PackedByteArray) -> void:
	for cols in TeleportReader._rows(data):
		if not _live(cols, 7):
			continue
		var p := Prize.new()
		p.set_id = _int(cols, 1)
		p.ref_id = _int(cols, 2)
		p.ratio = _int(cols, 3)
		p.count = _int(cols, 4)
		p.gacha_id = _int(cols, 5)
		prizes.append(p)

func parse_map(data: PackedByteArray) -> void:
	for cols in TeleportReader._rows(data):
		if _live(cols, 4):
			machines[_int(cols, 1)] = [_int(cols, 2), _int(cols, 3)]

func parse_tree(data: PackedByteArray) -> void:
	for cols in TeleportReader._rows(data):
		if not _live(cols, 9):
			continue
		var k := Kind.new()
		k.types = PackedInt32Array([_int(cols, 1), _int(cols, 2), _int(cols, 3), _int(cols, 4)])
		k.class_id = _int(cols, 5)
		k.class_key = cols[6].strip_edges()
		k.type_id = _int(cols, 7)
		k.type_key = cols[8].strip_edges()
		kinds.append(k)

## The prize set of a machine (its ref id), -1 for none.
func prize_set(npc_ref: int) -> int:
	return int(machines[npc_ref][0]) if machines.has(npc_ref) else -1

## The prizes of `set_id` whose item types pass `kind` (null: every prize;
## OURS, see GachaWindow), in file order. `types_of` maps a ref id to its
## TypeIDs.
func prizes_for(set_id: int, kind: Kind, types_of: Callable) -> Array:
	var out: Array = []
	for p in prizes:
		var pz: Prize = p
		if pz.set_id != set_id:
			continue
		if kind != null:
			var t: PackedInt32Array = types_of.call(pz.ref_id)
			if t.size() < 4 or t[0] != kind.types[0] or t[1] != kind.types[1] or t[2] != kind.types[2] or t[3] != kind.types[3]:
				continue
		out.append(pz)
	return out
