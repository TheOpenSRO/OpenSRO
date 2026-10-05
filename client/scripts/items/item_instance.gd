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
	return out
