extends RefCounted
class_name SetItemFx

## A set of gear completed or broken (round 860): the set's decoration and
## sound on the wearer, for everyone who sees the 0x3038 / 0x3039. Labels:
## READ (sro_client.exe c:), MEASURED, INFERRED, OURS, OPEN.
##
## THE HANDLERS (READ, 0x3038 c:0x8a9260 put on, 0x3039 c:0x8a9560 taken off,
## the mover's own uid too): the body is re-dressed, then FUN_0095d950(state,
## the item's code name, ...) with state 0 (put on) / 1 (taken off) -- the
## itemeffect.txt `itemcodename` rows of that state (the Nasrun avatars',
## MEASURED); when one played, the set's look is skipped. Otherwise: the
## model's +0x1a1 set -> the decoration ITEM_SETITEM_ACTIVE and the sound key
## snd_setitem_active, the flag cleared; +0x1a2 set -> ITEM_SETITEM_DEACTIVE
## and snd_setitem_deactive (0x3039 tests only the latter).
##
## THE FLAGS (READ, CObjCharacter::InstallEquipVisual c:0xa61010, both
## cleared first): FUN_00a60220 says the item's set is complete -- one piece
## worn in each slot of the set's mask (count == popcount(setdef + 0xa4),
## server/internal/equipment/itemset.go has the per-set record) -- tested for
## the old piece before it comes off and for the new one after it goes on;
## FUN_00a60c60 then: put on and complete -> ACTIVE (+0x1a1; and every armour
## slot with two models switches to model [1], the `_fullset.bsr`); taken off
## from a complete set -> DEACTIVE (+0x1a2). So ACTIVE when the piece that
## completes a set goes on, DEACTIVE when a piece of a complete set comes off.
##
## THE MASK: which refsetitemgroup.txt column fills setdef+0xa4 was not read
## (OPEN; its loader is the generic one, type 0x51, c:0x845016). INFERRED from
## the sets' MEASURED shapes (42 sets: 36 the six armour slots, 2 the three
## accessories, 2 a weapon, 2 a shield -- itemset.go): a set's size by its
## code name, _ACCESSORY 3, _WEAPON 1, _SHIELD 1, else 6.
##
## THE LOOK (MEASURED, skilleffect.txt): ITEM_SETITEM_ACTIVE
## `system\avatar_nasrun01_equip01.efp` at Bip01 Spine1 with its row sound
## `Avatar\Avatar_Nasrun1_Equip1.wav`; _DEACTIVE `avatar_nasrun01_unequip01.efp`
## with `Avatar_Nasrun1_Unequip1.wav`; both effectsound keys `ui\HyanGet.wav`
## at 80. NOT BUILT: the full-set model switch (OPEN, as since round 626).

const ACTIVE := "ITEM_SETITEM_ACTIVE"
const DEACTIVE := "ITEM_SETITEM_DEACTIVE"
const SND_ACTIVE := "UI:snd_setitem_active:-:-:-:-"
const SND_DEACTIVE := "UI:snd_setitem_deactive:-:-:-:-"
const SET_GROUP_PATH := "server_dep\\silkroad\\textdata\\refsetitemgroup.txt"
## itemeffect.txt's states for the handlers (READ: FUN_0095d950's first argument).
const STATE_PUT_ON := 0
const STATE_TAKEN_OFF := 1

## refsetitemgroup.txt bytes -> set id -> its size (see the header).
static func parse_set_sizes(bytes: PackedByteArray) -> Dictionary:
	var out := {}
	for raw in SkillAudio._utf16_lines(bytes):
		var cols := (raw as String).split("\t")
		if cols.size() < 3 or not cols[1].strip_edges().is_valid_int():
			continue
		out[int(cols[1])] = size_of(cols[2].strip_edges())
	return out

## A set's slot count by its code name (INFERRED, the header).
static func size_of(code: String) -> int:
	var c := code.to_upper()
	if c.ends_with("_ACCESSORY"):
		return 3
	if c.ends_with("_WEAPON") or c.ends_with("_SHIELD"):
		return 1
	return 6

## The sets complete in `worn` (slot -> item id): set id -> true. `set_of`
## is Callable(item id) -> set id (0 none).
static func complete_sets(worn: Dictionary, set_of: Callable, sizes: Dictionary) -> Dictionary:
	var slots := {}
	for slot in worn:
		var item := int(worn[slot])
		if item <= 0:
			continue
		var sid := int(set_of.call(item))
		if sid == 0:
			continue
		if not slots.has(sid):
			slots[sid] = {}
		(slots[sid] as Dictionary)[int(slot)] = true
	var out := {}
	for sid in slots:
		var need := int(sizes.get(sid, 0))
		if need > 0 and (slots[sid] as Dictionary).size() == need:
			out[sid] = true
	return out

## What a change from `before` to `after` (complete_sets' answers) plays:
## ACTIVE when a set became complete, DEACTIVE when one was broken, "" for
## neither. `put_on` false (0x3039) tests only the latter (READ).
static func change(before: Dictionary, after: Dictionary, put_on: bool) -> String:
	if put_on:
		for sid in after:
			if not before.has(sid):
				return ACTIVE
	for sid in before:
		if not after.has(sid):
			return DEACTIVE
	return ""

static var _sizes: Dictionary = {}
static var _sizes_loaded := false
static var _item_rows: Array = [{}, {}]
static var _item_rows_loaded := false

## The archive's set sizes (Media.pk2), loaded once.
static func sizes() -> Dictionary:
	if not _sizes_loaded:
		_sizes_loaded = true
		_sizes = parse_set_sizes(AudioBank.read_table("media", SET_GROUP_PATH))
	return _sizes

## itemeffect.txt's put-on / taken-off rows (code name -> effect id).
static func item_rows(state: int) -> Dictionary:
	if not _item_rows_loaded:
		_item_rows_loaded = true
		var bytes := AudioBank.read_table("media", ItemUseEffect.ITEMEFFECT_PATH)
		_item_rows = [ItemUseEffect.parse_use_rows(bytes, STATE_PUT_ON), ItemUseEffect.parse_use_rows(bytes, STATE_TAKEN_OFF)]
	return _item_rows[state] if state >= 0 and state < 2 else {}

## Test seam.
static func set_tables(set_sizes: Dictionary, put_on_rows: Dictionary, taken_off_rows: Dictionary) -> void:
	_sizes = set_sizes
	_sizes_loaded = true
	_item_rows = [put_on_rows, taken_off_rows]
	_item_rows_loaded = true

## The handler's look on `body` for `code`'s put-on / take-off with the sets
## `before` and `after`: the itemeffect row when there is one, else the set's
## decoration and sound. Returns what played ("" none).
static func play(body: Node3D, code: String, put_on: bool, before: Dictionary, after: Dictionary) -> String:
	if body == null or not is_instance_valid(body):
		return ""
	var rows := item_rows(STATE_PUT_ON if put_on else STATE_TAKEN_OFF)
	if rows.has(code):
		var id := String(rows[code])
		if ItemUseEffect.knows(id):
			ItemUseEffect.play(id, body, "itemeffect %s" % code)
			return id
	var which := change(before, after, put_on)
	if which == "":
		return ""
	ItemUseEffect.play(which, body, "set %s" % ("complete" if which == ACTIVE else "broken"))
	UiSounds.play(SND_ACTIVE if which == ACTIVE else SND_DEACTIVE, "%s by %s" % [which, code])
	return which
