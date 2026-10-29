extends RefCounted
class_name StallNetworkNet

## Round 840 (lane N): the stall network on the retail wire, mirroring
## server/internal/session/stallnet.go (docs/protocol/stall_network.md; c:
## the client's addresses, READ unless marked).
##
##   C->S 0x7461 {u8 mode, u8 page, u32 group, u8 degree}     search (c:0x821ae0)
##   S->C 0xB461 {1, u8 n, u8 pages, n x record} | {2, u16}   (c:0x88dca0, 0x6c98e0)
##   C->S 0x7462 {}                                           leave (c:0x821bd0)
##   S->C 0xB462 {u8}                                         (c:0x88df60, dropped)
##   C->S 0x7463 {u32 owner, u8 slot, u64 price, u16 count, u8 level, u64 serial}  buy (c:0x821c70)
##   S->C 0xB463 {1} | {2, u16}                               (c:0x88dec0)
##
## A record (c:0x6c98e0): the item record (SOItem::FUN_008be4f0 mode 1,
## ItemInstance.read_record), u32 owner, str seller, u8 slot, u16 count,
## u8 level, u64 price, u64 serial. Strings are a u16 length and the bytes.

const OP_SEARCH := 0x7461
const OP_SEARCH_RESULT := 0xB461
const OP_LEAVE := 0x7462
const OP_LEAVE_RESULT := 0xB462
const OP_BUY := 0x7463
const OP_BUY_RESULT := 0xB463

## 0x7461's modes (c:0x6c9f29 / 0x6c9f1a / 0x6c71ca).
const MODE_FIRST := 1
const MODE_SEARCH := 2
const MODE_PAGE := 3

## The window's fifteen rows (`res_ui\stallnetwork.2dt`, ids 120..234).
const ROWS := 15

## The codes the network answers with (c:0x7b8b40 case 10, the jump table
## 0x7bb9f4), READ. BOX: shown in a box (0x46e3d0 then 0x7b9ddd) -- the
## others are a game line.
const CODE_TEXTS := {
	0x3c41: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c42: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c43: "UIIT_MSG_WARENETWORK_ERROR_FAIL",
	0x3c46: "UIIT_MSG_WARENETWORK_SCAN_FAIL",
	0x3c49: "UIIT_MSG_WARENETWORK_USE_CITY",
	0x3c4a: "UIIT_MSG_WARENETWORK_USE_CITY",
	0x3c4f: "UIIT_MSG_WARENETWORK_BUY_ERROR",
	0x3c50: "UIIT_MSG_WARENETWORK_BUY_ERROR",
	0x3c51: "UIIT_MSG_WARENETWORK_BUY_ERROR",
	0x3c52: "UIIT_MSG_FLEAMARKET_ERR_NOT_ENOUGH_GOLD",
	0x3c53: "UIIT_MSG_FLEAMARKET_ERR_INVENTORY_FULL",
}
const BOX_CODES := [0x3c46, 0x3c49]
const CODE_USE_CITY := 0x3c49
const CODE_USE_CITY_STALL := 0x3c4a

## 0x70BA's network values while the stall is on the network (+0x864, READ
## c:0x6b99a0 / 0x6b4bb6 / 0x6b5ed1 / 0x6b9a20 / 0x6b9940).
const NET_PRICE := 4
const NET_ADD := 2
const NET_REMOVE := 5
const NET_REGISTER := 1
const NET_MODIFY := 3

## The commission the owner's client prints (c:0x87a4bf..0x87a4ec): ftol of
## the price times the float 0.01 (0xe1b820, read as a double), at least 1,
## at most 100,000; none for a price of 0.
const COMMISSION_RATE := 0.009999999776482582
const COMMISSION_MIN := 1
const COMMISSION_MAX := 100000

## One search record.
class Record:
	var item: ItemInstance
	var owner: int
	var seller: String
	var slot: int
	var count: int
	var level: int
	var price: int
	var serial: int
	## The Number column (rec+0x40): page * 15 + i, the client's own.
	var number: int

	func same_as(o: Record) -> bool:
		return o != null and o.owner == owner and o.slot == slot and o.price == price and o.count == count \
			and o.level == level and o.serial == serial

static func _str(s: String) -> PackedByteArray:
	var b := s.to_utf8_buffer()
	var out := PackedByteArray()
	out.resize(2)
	out.encode_u16(0, b.size())
	out.append_array(b)
	return out

static func encode_search(mode: int, page: int, group: int, degree: int) -> PackedByteArray:
	var out := PackedByteArray([mode & 0xff, page & 0xff, 0, 0, 0, 0, degree & 0xff])
	out.encode_u32(2, group)
	return out

## 0x7463 from a record (c:0x6c7c20: owner, slot, price, count, level, serial).
static func encode_buy(r: Record) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(24)
	out.encode_u32(0, r.owner)
	out[4] = r.slot & 0xff
	out.encode_u64(5, r.price)
	out.encode_u16(13, r.count)
	out[15] = r.level & 0xff
	out.encode_u64(16, r.serial)
	return out

## {1} -> 1, {2, code} -> the code, anything else -> -1.
static func decode_result(data: PackedByteArray) -> int:
	if data.size() >= 1 and data[0] == 1:
		return 1
	if data.size() >= 3 and data[0] == 2:
		return data.decode_u16(1)
	return -1

## One record at `at`: [Record, next] or [null, -1].
static func read_record(data: PackedByteArray, at: int) -> Array:
	var rec := ItemInstance.read_record(data, at)
	if rec[0] == null:
		return [null, -1]
	at = int(rec[1])
	if at + 6 > data.size():
		return [null, -1]
	var r := Record.new()
	r.item = rec[0]
	r.owner = data.decode_u32(at)
	var n := data.decode_u16(at + 4)
	at += 6
	if at + n + 20 > data.size():
		return [null, -1]
	r.seller = data.slice(at, at + n).get_string_from_utf8()
	at += n
	r.slot = data[at]
	r.count = data.decode_u16(at + 1)
	r.level = data[at + 3]
	r.price = data.decode_u64(at + 4)
	r.serial = data.decode_u64(at + 12)
	return [r, at + 20]

## 0xB461: {"code"} for a refusal; {"code": 1, "pages", "records"} -- the
## records' Number is filled from `page` (c:0x6c99a4: page * 15 + i, i from
## 1); {} when it does not parse.
static func decode_search(data: PackedByteArray, page := 0) -> Dictionary:
	if data.size() >= 3 and data[0] == 2:
		return {"code": data.decode_u16(1)}
	if data.size() < 3 or data[0] != 1:
		return {}
	var n: int = data[1]
	var pages: int = data[2]
	var records: Array = []
	var at := 3
	for i in n:
		var r := read_record(data, at)
		if r[0] == null:
			return {}
		var rec: Record = r[0]
		rec.number = page * ROWS + i + 1
		records.append(rec)
		at = int(r[1])
	return {"code": 1, "pages": pages, "records": records}

## The owner's commission line's figure (READ, see COMMISSION_RATE); 0 for a
## price of 0 (no line).
static func commission(price: int) -> int:
	if price <= 0:
		return 0
	var c := int(float(price) * COMMISSION_RATE)
	if c < COMMISSION_MIN:
		return COMMISSION_MIN
	return mini(c, COMMISSION_MAX)

## The 0xB0BA type-1/2/3 answer values the client takes as success (c:0x8783f2
## 4, 0x878432 2, 0x878472 5; 0 always).
static func update_net_ok(update_type: int, net: int) -> bool:
	if net == 0:
		return true
	match update_type:
		StallNet.UPDATE_PRICE:
			return net == NET_PRICE
		StallNet.UPDATE_ADD:
			return net == NET_ADD
		StallNet.UPDATE_REMOVE:
			return net == NET_REMOVE
	return true

# --- the category tree (fmncategorytreedata.txt) ------------------------------------

## A class (a row whose parent is `xxx`) and its types.
class Category:
	var key: String
	var text_key: String
	var group: int
	var degrees: int
	var types: Array = []

const TREE_PATH := "server_dep\\silkroad\\textdata\\fmncategorytreedata.txt"
const TREE_ROOT := "xxx"

## The tree's rows (Service, key, text key, parent key, TidGroupID, degrees),
## Service 1 only, in file order: the classes, each with its types.
static func parse_tree(text: String) -> Array:
	var classes: Array = []
	var by_key := {}
	for line in text.split("\n", false):
		var f := line.strip_edges().split("\t", false)
		if f.size() < 6 or f[0] != "1":
			continue
		var c := Category.new()
		c.key = f[1]
		c.text_key = f[2]
		c.group = int(f[4]) if f[4].is_valid_int() else 0
		c.degrees = int(f[5]) if f[5].is_valid_int() else 0
		if f[3] == TREE_ROOT:
			classes.append(c)
			by_key[c.key] = c
		elif by_key.has(f[3]):
			(by_key[f[3]] as Category).types.append(c)
	return classes
