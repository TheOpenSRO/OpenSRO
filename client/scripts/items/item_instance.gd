extends RefCounted
class_name ItemInstance

## One item's own data (round 732): the plus, the white-stat variance, the
## durability, the blue options and the advanced elixir, decoded from the
## retail item record the server appends to the bag, warehouse and
## equipment lists. docs/protocol/item_tooltip.md "The item instance on the
## wire"; the server side is server/internal/session/iteminfo.go.
##
## The RECORD is retail's (the client's SOItem::FUN_008be4f0, equipment
## branch; the GameServer's writer gs:0x42e230):
##   u32 rent block (c:0x8bb130: 0, or bit 0 adds u16 u32 u32, bit 1 adds
##   u16 u32), u32 RefItemID, u8 OptLevel, u64 Variance, u32 Durability (the
##   period word active<<31|seconds for TypeID3 14 gear), u8 MagParamNum
##   (<= 12), MagParamNum x u64 (low u16 the magicoption.txt id, high u32
##   the value), then two binding blocks [u8 type, u8 count, count x (u8
##   nSlot, u64: low u32 nOptID | nOptLvl<<16, high u32 the value)] -- type 1
##   sockets, type 2 the advanced elixir, whose value's low byte adds to the
##   plus (a u8 add, c:0x8bb070).
## The CONTAINER is OpenSRO's own (OURS): a trailing block, u16 count, then
## per entry a u32 container slot and the record. Only equipment is listed.
## Round 838 (OURS): the models block may follow the entries -- u16 count,
## then per entry a u32 slot and the u32 ref id of the row the item there is
## drawn with (a model switcher's choice; server iteminfo.go) -- written only
## when some entry has one, and always the message's last field.
##
## For the tooltip (lane A): ListResult.instances / Result.instances map a
## slot to its ItemInstance; the fields below plus effective_plus(),
## variance_group(k), option_id(i) and option_value(i), with ItemQuality for
## the stats and percentages and MagicOptionTable for the blue lines.

const MAX_MAG_PARAMS := 12
## The entries a list could not fit in its own frame (OURS, round 732
## review F8; session/iteminfomore.go): u8 container, then the same block.
## Only a full warehouse needs it.
const OP_MORE := 0x00FB
const CONTAINER_BAG := 0
const CONTAINER_WORN := 1
const CONTAINER_WAREHOUSE := 2
const BINDING_SOCKET := 1
const BINDING_ADV_ELIXIR := 2

var slot: int = -1
var ref_item_id: int = 0
## The record's OptLevel: the plus as the server stores it.
var opt_level: int = 0
## Twelve 5-bit white-stat groups, group k at bits 5k..5k+4.
var variance: int = 0
var durability: int = 0
## The blue options, each the packed u64 (see option_id / option_value).
var mag_params: Array[int] = []
## The advanced elixir's plus, the sum of the type-2 binding entries.
var adv_elixir: int = 0

## Round 795: a record that is not equipment's (read only once types_of is
## bound): the stack's count (an expendable), or a COS summon item's pet.
var is_equipment := true
var count: int = 1
## A specialty good's buyer (round 801): the job alias it was bought under.
var creator := ""
## A pet item's state (CosNet.ITEM_STATE_*), its pet's RefObjID, name, and an
## ability pet's rent: the seconds left when read, at rent_read_msec.
var cos_state: int = 0
var cos_ref: int = 0
var cos_name := ""
var cos_rent_secs: int = 0
var rent_read_msec: int = 0
## Round 838 (OURS): the ref id of the row whose model this item is drawn
## with (an archive _SWITCHnn twin), 0 for its own. Visual only.
var model: int = 0

## The id the item is drawn as: its model's row when it has one.
func display_ref() -> int:
	return model if model > 0 else ref_item_id

## Round 795: the item table the reader dispatches on (RefItemID ->
## PackedInt32Array [TypeID1..4], empty when unknown), and the COS table
## (RefObjID -> TypeID4). Unbound, every record is read as equipment's, as
## before round 795.
static var types_of: Callable
static var cos_kind_of: Callable

## The plus every stat and "(+x%)" uses: the client adds the advanced
## elixir onto OptLevel as it reads the record (c:0x8bb070) and the line
## builder adds the byte at item +0x70 (FUN_008ba4d0), whose writer is OPEN
## -- OpenSRO has nothing there, so it is 0.
func effective_plus() -> int:
	return opt_level + adv_elixir

## Variance group k (0..11), 0..31.
func variance_group(k: int) -> int:
	return (variance >> (5 * k)) & 0x1f

func option_count() -> int:
	return mag_params.size()

## The i-th blue option's magicoption.txt id: the low u16 (c:0x8bcdf0).
func option_id(i: int) -> int:
	return mag_params[i] & 0xffff

## The i-th blue option's value: the high u32.
func option_value(i: int) -> int:
	return (mag_params[i] >> 32) & 0xffffffff

func describe() -> String:
	var opts := PackedStringArray()
	for i in option_count():
		opts.append("%d=%d" % [option_id(i), option_value(i)])
	return "slot %d item %d +%d (opt %d, adv %d) variance %x durability %d options [%s]" % [
		slot, ref_item_id, effective_plus(), opt_level, adv_elixir, variance, durability, ", ".join(opts)]

## The log line a tester's report carries for this instance: the record,
## the twelve variance groups, the durability "(+x%)" and each blue option
## with its row's range, "(+x%)" and line, when the shared table is loaded.
func log_line(container: String) -> String:
	var groups := PackedStringArray()
	for k in 12:
		groups.append(str(variance_group(k)))
	var out := "[item] %s %s groups [%s] durability (+%d%%)" % [container, describe(), " ".join(groups),
		ItemQuality.durability_pct(variance_group(0))]
	if model > 0:
		out += " model %d" % model
	for i in option_count():
		var id := option_id(i)
		var value := option_value(i)
		var t: MagicOptionTable = MagicOptionTable.shared
		var r: MagicOptionTable.Row = t.row(id) if t != null else null
		if r == null:
			out += " | option %d=%d (no magicoption row)" % [id, value]
			continue
		var pct := MagicOptionTable.blue_pct(r, value)
		var line := ""
		if MagicOptionTable.shared_text.is_valid():
			line = MagicOptionTable.format_line(r.code, value, pct, MagicOptionTable.shared_text)
		out += " | option %d %s degree %d value %d range %d..%d (+%d%%) \"%s\"" % [id, r.code, r.degree, value,
			r.min_value(), r.max_value(), pct, line]
	return out

## Reads one record at offset. Returns [ItemInstance, offset after], or
## [null, -1] on a truncated or out-of-range record.
static func read_record(data: PackedByteArray, offset: int) -> Array:
	if offset + 4 > data.size():
		return [null, -1]
	var rent := data.decode_u32(offset)
	offset += 4
	if rent & 3 != 0:
		offset += 2 + (8 if rent & 1 != 0 else 0) + (6 if rent & 2 != 0 else 0)
	if offset + 4 > data.size():
		return [null, -1]
	var t := PackedInt32Array()
	if types_of.is_valid():
		t = types_of.call(data.decode_u32(offset))
	if t.size() == 4 and not (t[0] == 3 and t[1] == 1):
		return _read_tail(data, offset, t)
	if offset + 18 > data.size():
		return [null, -1]
	var it := ItemInstance.new()
	it.ref_item_id = data.decode_u32(offset)
	it.opt_level = data[offset + 4]
	it.variance = data.decode_u64(offset + 5)
	it.durability = data.decode_u32(offset + 13)
	var n: int = data[offset + 17]
	offset += 18
	if n > MAX_MAG_PARAMS or offset + 8 * n > data.size():
		return [null, -1]
	for i in n:
		it.mag_params.append(data.decode_u64(offset + 8 * i))
	offset += 8 * n
	for block in 2:
		if offset + 2 > data.size():
			return [null, -1]
		var kind: int = data[offset]
		var count: int = data[offset + 1]
		offset += 2
		if offset + 9 * count > data.size():
			return [null, -1]
		for i in count:
			var v: int = data.decode_u64(offset + 9 * i + 1)
			if kind == BINDING_ADV_ELIXIR:
				it.adv_elixir = (it.adv_elixir + ((v >> 32) & 0xff)) & 0xff
		offset += 9 * count
	return [it, offset]

## Round 795: a non-equipment record's tail after the RefItemID at offset
## (c:SOItem::FUN_008be4f0's other branches, READ): a COS summon item's pet
## (3/2/1), nothing more for another 3/2 item (a u32 for 3/2/2), a u16 count
## for an expendable, plus the alchemy stones' byte (3/3/11/1-2) or a 3/3/14/2's
## options. Returns [ItemInstance, offset after] or [null, -1].
static func _read_tail(data: PackedByteArray, offset: int, t: PackedInt32Array) -> Array:
	var it := ItemInstance.new()
	it.is_equipment = false
	it.ref_item_id = data.decode_u32(offset)
	offset += 4
	if t[1] == 2:
		if t[2] == 1:
			if offset + 1 > data.size():
				return [null, -1]
			it.cos_state = data[offset]
			offset += 1
			if it.cos_state == 1:
				return [it, offset]
			if offset + 4 > data.size():
				return [null, -1]
			it.cos_ref = data.decode_u32(offset)
			offset += 4
			var kind := 0
			if cos_kind_of.is_valid():
				kind = int(cos_kind_of.call(it.cos_ref))
			if kind != 3 and kind != 4:
				return [it, offset]
			if offset + 2 > data.size():
				return [null, -1]
			var n := data.decode_u16(offset)
			if offset + 2 + n > data.size():
				return [null, -1]
			it.cos_name = data.slice(offset + 2, offset + 2 + n).get_string_from_utf8()
			offset += 2 + n
			if kind == 4:
				if offset + 4 > data.size():
					return [null, -1]
				it.cos_rent_secs = data.decode_u32(offset)
				it.rent_read_msec = Time.get_ticks_msec()
				offset += 4
			if offset + 1 > data.size():
				return [null, -1]
			var jobs: int = data[offset]
			offset += 1
			for j in jobs:
				if offset + 9 > data.size():
					return [null, -1]
				var cat: int = data[offset]
				offset += 9
				if cat == 5:
					offset += 5
			if offset > data.size():
				return [null, -1]
			return [it, offset]
		if t[2] == 2:
			offset += 4
		return [it, offset] if offset <= data.size() else [null, -1]
	if offset + 2 > data.size():
		return [null, -1]
	it.count = data.decode_u16(offset)
	offset += 2
	if t[1] == 3 and t[2] == 8:
		# A specialty good (round 801, READ c:0x8be6a1..0x8be715): the count,
		# then its buyer's name, a u16-length string -- nothing else.
		if offset + 2 > data.size():
			return [null, -1]
		var n := data.decode_u16(offset)
		if offset + 2 + n > data.size():
			return [null, -1]
		it.creator = data.slice(offset + 2, offset + 2 + n).get_string_from_utf8()
		return [it, offset + 2 + n]
	if t[2] == 11 and (t[3] == 1 or t[3] == 2):
		offset += 1
	if t[2] == 14 and t[3] == 2:
		if offset + 1 > data.size():
			return [null, -1]
		var m: int = data[offset]
		offset += 1
		for i in m:
			if offset + 8 > data.size():
				return [null, -1]
			it.mag_params.append(data.decode_u64(offset))
			offset += 8
	return [it, offset] if offset <= data.size() else [null, -1]

## An ability pet's rent seconds left now.
func rent_left_secs() -> int:
	if rent_read_msec <= 0:
		return cos_rent_secs
	return maxi(0, cos_rent_secs - (Time.get_ticks_msec() - rent_read_msec) / 1000)

## The record read_record reads (round 789, for the avatar golden vectors and
## fixtures): no rent block, the magic params as held, and the two binding
## blocks empty -- the advanced elixir is not written (no golden carries one).
func encode_record() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(22)
	out.encode_u32(0, 0)
	out.encode_u32(4, ref_item_id)
	out[8] = opt_level & 0xff
	out.encode_u64(9, variance)
	out.encode_u32(17, durability)
	out[21] = mag_params.size()
	for p in mag_params:
		var b := PackedByteArray()
		b.resize(8)
		b.encode_u64(0, p)
		out.append_array(b)
	out.append_array(PackedByteArray([BINDING_SOCKET, 0, BINDING_ADV_ELIXIR, 0]))
	return out

## Reads the trailing block at offset: {slot: ItemInstance}. An absent block
## (an older server) is an empty map; a truncated one keeps what was read.
static func decode_block(data: PackedByteArray, offset: int) -> Dictionary:
	var out := {}
	if offset < 0 or offset + 2 > data.size():
		return out
	var count := data.decode_u16(offset)
	offset += 2
	for i in count:
		if offset + 4 > data.size():
			break
		var at := data.decode_u32(offset)
		var rec := read_record(data, offset + 4)
		if rec[0] == null:
			push_warning("item instance block: entry %d truncated" % i)
			break
		var it: ItemInstance = rec[0]
		it.slot = at
		out[at] = it
		offset = rec[1]
	# Round 838: the models block, when the sender wrote one.
	if offset + 2 <= data.size():
		var models := data.decode_u16(offset)
		offset += 2
		for k in models:
			if offset + 8 > data.size():
				push_warning("item instance block: models entry %d truncated" % k)
				break
			var it: ItemInstance = out.get(data.decode_u32(offset))
			if it != null:
				it.model = data.decode_u32(offset + 4)
			offset += 8
	return out
