extends RefCounted
class_name NpcServiceReader

## Reads, from the player's own Media.pk2, what services an NPC offers and its
## greeting -- so the talk window lists the real options, not a placeholder.
## All grounded in the client's own textdata; nothing invented.
##
## refshopgroup.txt (tab, 0-indexed): [3]=shop group code (GROUP_STORE_CH_SMITH),
##   [4]=the NPC codename that runs it (NPC_CH_SMITH). An NPC that appears here
##   sells a shop -> the "Buy" service.
## npcchat.txt (tab): [1]=NPC codename, [2]/[3]=greeting string ids (SN_*),
##   resolved through the UI text table.
## Storage / guild / stable / special are named by the NPC's own codename
## (NPC_*_WAREHOUSE, _GUILD, _HORSE, _SPECIAL) -- the game's own self-describing
## codes, not a guess.

const SHOP_TABLE := "server_dep\\silkroad\\textdata\\refshopgroup.txt"
const CHAT_TABLE := "server_dep\\silkroad\\textdata\\npcchat.txt"

const SHOP_NPC_COL := 4
const CHAT_CODE_COL := 1
const CHAT_MSG1_COL := 2
const CHAT_MSG2_COL := 3

## One service a talk window offers: a stable key (for wiring later) and the
## UI label to show.
class Service:
	var key: String
	var label: String

	func _init(k: String, l: String) -> void:
		key = k
		label = l

## Parses refshopgroup.txt into a set of NPC codenames (upper-cased) that run a
## shop.
static func parse_shop_npcs(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= SHOP_NPC_COL:
			continue
		var npc := cols[SHOP_NPC_COL].strip_edges()
		if npc.begins_with("NPC_"):
			out[npc.to_upper()] = true
	return out

## Parses npcchat.txt into NPC codename (upper) -> [msg1_strid, msg2_strid].
static func parse_greetings(data: PackedByteArray) -> Dictionary:
	var out: Dictionary = {}
	for line in _lines(data):
		if line.begins_with("//"):
			continue
		var cols := line.split("\t")
		if cols.size() <= CHAT_MSG1_COL:
			continue
		var code := cols[CHAT_CODE_COL].strip_edges()
		if not code.begins_with("NPC_"):
			continue
		var m1 := cols[CHAT_MSG1_COL].strip_edges()
		var m2 := cols[CHAT_MSG2_COL].strip_edges() if cols.size() > CHAT_MSG2_COL else ""
		out[code.to_upper()] = [m1, m2]
	return out

## The services an NPC offers, from its codename + the shop set. Which services
## an NPC has is GROUNDED (shop = refshopgroup membership; the rest are named by
## the NPC's own self-describing codename). The labels here are this project's
## own plain-English UI text, NOT recovered UIIT tokens -- the greeting text is
## the grounded string (see the caller). "End conversation" is added by the talk
## window.
static func services_for(code: String, shop_npcs: Dictionary) -> Array:
	var out: Array = []
	var up := code.to_upper()
	# A shop (buy) -- grounded by refshopgroup membership.
	if shop_npcs.has(up):
		out.append(Service.new("shop", "Buy"))
	# The rest are named by the NPC's own codename (self-describing game codes).
	if up.contains("WAREHOUSE"):
		out.append(Service.new("storage", "Storage"))
	if up.contains("GUILD"):
		out.append(Service.new("guild", "Guild"))
	if up.contains("SMITH"):
		# A smith both sells (shop, above) and repairs.
		out.append(Service.new("repair", "Repair"))
	return out

static func _lines(data: PackedByteArray) -> PackedStringArray:
	if data.is_empty():
		return PackedStringArray()
	var raw := data
	if raw.size() >= 2 and raw[0] == 0xFF and raw[1] == 0xFE:
		raw = raw.slice(2)
	var text := raw.get_string_from_utf16()
	if text.is_empty():
		text = raw.get_string_from_utf8()
	return text.replace("\r", "").split("\n")
