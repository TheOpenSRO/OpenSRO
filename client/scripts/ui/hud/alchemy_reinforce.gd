extends RefCounted
class_name AlchemyReinforce

## The strengthening tab's rules (round 768): CAlchemyMgrReinforce
## (sro_client.exe vtable 0xd8bf7c) -- which slot an item goes to, whether it
## may, when the action button lights, which request a start sends, and what
## outcome the window shows for a reply. Pure data in, data out; the window
## (AlchemyWindow) draws it. Every address is the client's
## (docs/protocol/alchemy.md, "Round 768", "The client").
##
## An item is a Dictionary the window builds from the bag:
##   {"bag": int, "item_id": int, "tids": [t1, t2, t3, t4], "item_class": int,
##    "param1": int, "param5": int, "desc1": String, "desc4": String,
##    "code": String, "plus": int, "durability": int}

## The three slots the tab uses (map keys 0..2 of the Type1 pane's OnCreate,
## 0x59cc80): controls 17, 26 and 27 of pane 12.
const SLOT_TARGET := 0
const SLOT_STUFF := 1
const SLOT_POWDER := 2
const SLOT_CONTROLS := [17, 26, 27]

## 0x570430's message indices and the names it shows (READ, the switch;
## every case writes FUN_007781b0(0, text): the system window, type 0).
const MESSAGES := {
	8: "UIIT_MSG_ENCHANT_LOAD_EQUIP_FIRST",
	9: "UIIT_MSG_REINFORCE_NOT_LOAD_INGREDIENT",
	0xa: "UIIT_MSG_REINFORCERR_RECIPE_MISMATCH",
	0xb: "UIIT_MSG_ENCHANT_NOT_LOAD_INGREDIENT2",
	0xc: "UIIT_MSG_ENCHANT_EQUIPCLASS_MISMATCH",
	0xd: "UIIT_STRGERR_CANNOT_BE_USED_TO_TARGET",
}

## The outcome bits 0x59eb20 tests (READ): 0x10 success, 0x20 failure (with
## 1 the plus changed, 2 the durability changed), 0x40 destroyed, 0x80 a
## stone's lost roll.
const OUT_SUCCESS := 0x10
const OUT_FAIL := 0x20
const OUT_PLUS := 0x01
const OUT_DURABILITY := 0x02
const OUT_BREAKDOWN := 0x40
const OUT_STONE_FAIL := 0x80

static func _is(it: Dictionary, t1: int, t2: int, t3: int = -1, t4: int = -1) -> bool:
	var t: Array = it.get("tids", [])
	if t.size() < 4:
		return false
	return int(t[0]) == t1 and int(t[1]) == t2 and (t3 < 0 or int(t[2]) == t3) and (t4 < 0 or int(t[3]) == t4)

## The TypeID predicates the manager uses (READ, re notes: 0x56fbb0 ...).
static func is_equipment(it: Dictionary) -> bool: return _is(it, 3, 1)
static func is_elixir(it: Dictionary) -> bool: return _is(it, 3, 3, 10, 1)
static func is_powder(it: Dictionary) -> bool: return _is(it, 3, 3, 10, 2)
static func is_upper_elixir(it: Dictionary) -> bool: return _is(it, 3, 3, 10, 4)
static func is_magic_stone(it: Dictionary) -> bool: return _is(it, 3, 3, 11, 1)
static func is_attr_stone(it: Dictionary) -> bool: return _is(it, 3, 3, 11, 2)
static func is_bless_stone(it: Dictionary) -> bool: return _is(it, 3, 3, 11, 7)
static func is_magic_cube(it: Dictionary) -> bool: return _is(it, 3, 2, 3, 1)
static func is_stone(it: Dictionary) -> bool:
	return is_magic_stone(it) or is_attr_stone(it) or is_bless_stone(it)
static func is_recipe(it: Dictionary) -> bool:
	return is_elixir(it) or is_magic_cube(it) or is_upper_elixir(it)

## Equipment the tab refuses as a target (message 8): job suits (3/1/7),
## avatars (3/1/13) and fortress weapons (3/1/6/16).
static func refused_target(it: Dictionary) -> bool:
	return _is(it, 3, 1, 7) or _is(it, 3, 1, 13) or _is(it, 3, 1, 6, 16)

## (ItemClass - 1) / 3 + 1 (READ, the client's 0x578ac0 and gs FUN_004775a0).
static func degree(it: Dictionary) -> int:
	return floori((int(it.get("item_class", 1)) - 1) / 3.0) + 1

## vslot 54 (0x5781f0): the slot an item goes to, from its kind -- not from
## where it was dropped. -1: none free.
static func pick_slot(it: Dictionary, slots: Array) -> int:
	var filled := func(i: int) -> bool: return slots[i] != null
	if is_equipment(it) and not _is(it, 3, 1, 7) and not _is(it, 3, 1, 13):
		return SLOT_TARGET
	if is_recipe(it) or is_stone(it):
		if filled.call(SLOT_TARGET):
			return SLOT_STUFF
	elif is_powder(it):
		if filled.call(SLOT_TARGET) and filled.call(SLOT_STUFF):
			return SLOT_POWDER
	for i in slots.size():
		if not filled.call(i):
			return i
	return -1

## vslot 52 (0x578ac0): 0 when `it` may go in `slot`, else a MESSAGES
## index. The stone checks (0xc, 0xd) are made against the magic option
## table's own rows (`options`, MagicOptionTable or null) by the server's
## rule, so a stone the server would refuse after a won roll -- which spends
## it only when the roll is lost -- is refused here first (OURS: the exact
## test the client makes for 0xd was not read).
static func validate(slot: int, it: Dictionary, slots: Array, options: MagicOptionTable) -> int:
	var target: Variant = slots[SLOT_TARGET]
	if slot == SLOT_TARGET:
		if not is_equipment(it) or refused_target(it):
			return 8
		return 0
	if target == null:
		return 8
	var tgt: Dictionary = target
	if slot == SLOT_STUFF:
		if not (is_recipe(it) or is_stone(it)):
			return 9
		if is_elixir(it) and not elixir_suits(it, tgt):
			return 0xa
		if is_stone(it):
			if int(it.get("param1", 0)) != degree(tgt):
				return 0xc
			if not stone_suits(it, tgt, options):
				return 0xd
		return 0
	# The powder slot: a powder after an elixir or cube, of the target's
	# degree.
	if not is_powder(it):
		return 9
	var stuff: Variant = slots[SLOT_STUFF]
	if stuff == null or not (is_elixir(stuff) or is_magic_cube(stuff)):
		return 9
	if int(it.get("param1", 0)) != degree(tgt):
		return 0xb
	return 0

## The elixir's TypeID3 bytes (Param1 and Param5, the server's rule, gs
## 0x505cb0) name the target's TypeID3. The client's own test reads 8 bytes
## at ref +0x2b4/+0x2c4; +0x2b4 is Param1 (round 632), which the second is
## not established (INFERRED Param5).
static func elixir_suits(elixir: Dictionary, target: Dictionary) -> bool:
	var t3: int = int(target["tids"][2])
	for w in [int(elixir.get("param1", 0)), int(elixir.get("param5", 0))]:
		var u: int = int(w) & 0xffffffff
		for k in 4:
			if (u >> (8 * k)) & 0xff == t3:
				return true
	return false

## Whether a stone may work on the target: an attribute stone's class list
## (Desc128_4) names the target's class; a magic or bless stone's option
## (Desc128_1) has a row at the target's degree that may sit on it.
static func stone_suits(stone: Dictionary, target: Dictionary, options: MagicOptionTable) -> bool:
	var t: Array = target["tids"]
	if is_attr_stone(stone):
		var word := class_word(int(t[2]))
		if word == "":
			return false
		for w in String(stone.get("desc4", "")).split(","):
			if w.strip_edges().to_lower() == word:
				return true
		return false
	if options == null:
		return true # no table loaded: the server decides
	var r := options.record(String(stone.get("desc1", "")), degree(target))
	return MagicOptionTable.allowed_on(r, int(t[2]), int(t[3]), String(target.get("code", "")))

## The word an attribute stone's list uses for a TypeID3 (MEASURED:
## "weapon", "shield", "armor", "accessory").
static func class_word(tid3: int) -> String:
	match tid3:
		6:
			return "weapon"
		4:
			return "shield"
		1, 2, 3, 9, 10, 11:
			return "armor"
		5, 12:
			return "accessory"
	return ""

## vslot 50 (0x578670): the action lights when the target and the stuff are
## both loaded. The powder is optional.
static func action_enabled(slots: Array) -> bool:
	return slots[SLOT_TARGET] != null and slots[SLOT_STUFF] != null

## vslot 38 (0x57a810): the request's op for what is in the stuff slot -- 3
## an elixir or magic cube, 8 an advanced elixir (both 0x7150), 4 a magic or
## bless stone, 5 an attribute stone (0x7151).
static func op_for(stuff: Dictionary) -> int:
	if is_upper_elixir(stuff):
		return AlchemyNet.OP_UPPER
	if is_magic_stone(stuff) or is_bless_stone(stuff):
		return AlchemyNet.OP_MAGIC
	if is_attr_stone(stuff):
		return AlchemyNet.OP_ATTR
	return AlchemyNet.OP_REINFORCE

## The request's bag indices, keys 0, 1, 2 in order, every loaded slot.
static func request_slots(slots: Array) -> Array:
	var out: Array = []
	for s in slots:
		if s != null:
			out.append(int(s["bag"]))
	return out

## The outcome bits for a reply (0x8729e0 / 0x872cd0, READ): an elixir's
## success 0x10; its failure 0x40 when destroyed, else 0x20 with 1 when the
## plus changed and 2 when the durability did, against the snapshot taken at
## the send (0x57a390); a stone's success 0x10, its lost roll 0x80. -1 for a
## reply that shows no outcome (a refusal or a cancel).
static func outcome(r: AlchemyNet.Result, old_plus: int, old_durability: int) -> int:
	if not r.ok:
		return OUT_STONE_FAIL if (not r.reinforce and r.code == AlchemyNet.CODE_ENCHANT_FAILED) else -1
	if r.cancelled:
		return -1
	if r.success:
		return OUT_SUCCESS
	if r.reinforce and r.destroyed:
		return OUT_BREAKDOWN
	var bits := OUT_FAIL
	if r.record != null:
		if r.record.opt_level != old_plus:
			bits |= OUT_PLUS
		if r.record.durability != old_durability:
			bits |= OUT_DURABILITY
	return bits

## The lines 0x59eb20 writes for an outcome (READ): [key, args] pairs, each
## shown through 0x7781b0 / 0x778210 with type 0. SUCCESS names the new plus
## and is written for an elixir only; OPTLV_ZERO / OPTLV_DOWN (new plus, the
## loss) and FAILDOWN_DURABILITY (new, the loss) follow the failure bits; a
## bare failure is FAIL; destroyed BREAKDOWN; a stone's lost roll FAIL.
static func outcome_lines(bits: int, elixir: bool, new_plus: int, old_plus: int, new_dur: int, old_dur: int) -> Array:
	if bits < 0:
		return []
	if bits & OUT_SUCCESS:
		return [["UIIT_MSG_REINFORCERR_SUCCESS", [new_plus]]] if elixir else []
	if bits & OUT_FAIL:
		var out: Array = []
		if bits & 0x0f == 0:
			return [["UIIT_MSG_REINFORCERR_FAIL", []]]
		if bits & OUT_PLUS:
			if new_plus == 0:
				out.append(["UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_ZERO", []])
			elif elixir:
				out.append(["UIIT_MSG_REINFORCERR_FAIL_RESULT_OPTLV_DOWN", [new_plus, old_plus - new_plus]])
		if bits & OUT_DURABILITY:
			out.append(["UIIT_MSG_REINFORCERR_FAILDOWN_DURABILITY", [new_dur, old_dur - new_dur]])
		return out
	if bits & OUT_BREAKDOWN:
		return [["UIIT_MSG_REINFORCERR_BREAKDOWN", []]]
	if bits & OUT_STONE_FAIL:
		return [["UIIT_MSG_REINFORCERR_FAIL", []]]
	return []

## A line's text: the archive's format with each "%d" replaced, in order,
## by the next of `args` (0 once they run out). Replaced by hand rather than
## with GDScript's %, so a format holding anything else after a % (the
## archive's own text) cannot raise an error.
static func fill(format: String, args: Array) -> String:
	var out := ""
	var i := 0
	var at := 0
	while true:
		var hit := format.find("%d", at)
		if hit < 0:
			break
		out += format.substr(at, hit - at) + str(int(args[i]) if i < args.size() else 0)
		i += 1
		at = hit + 2
	return out + format.substr(at)
