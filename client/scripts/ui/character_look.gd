extends RefCounted
class_name CharacterLook

## Round 847 (OURS): what a character looks like, as one value -- the single
## input every body this client draws is built from. CharacterAppearance is the
## builder (a look -> a Node3D, or a far recipe); this is what it is handed.
## docs/protocol/character_look.md has the model, its sources and the census of
## the sites that draw a character.
##
## The user (2026-10-30): "the character selection doesn't reflect model
## changers ... Shouldn't there be a class or something that is basically the
## visual rep of the character and things can call it so we're not changing it
## in 30 places?" Before this round each site assembled CharacterAppearance's
## inputs itself -- a slot -> id map, a plus map, a model switcher's own-id map
## -- and the select screen, which assembled them from the 0xB007 record, never
## learned of the model switcher (round 843's OPEN).
##
## **What it holds.** No scene, no archive: plain values.
## - The body: `ref_obj_id` (the characterdata row, 0 when the source names only
##   a gender), `gender` (World3D's code, "china_man" ...; "" unknown), `race`
##   (0 China, 1 Europe, -1 unknown), `body` (World3D's body key when a source
##   named one) and the `scale` byte (Height low nibble, Volume high nibble,
##   READ FUN_00a5b960).
## - The worn items, by key: `worn` key -> the RefItemID DRAWN (a model
##   switcher's `_SWITCHnn` row when it gave the item one), `pluses` key -> the
##   plus byte the glow is chosen by (OptLevel + advanced elixir; a key it lacks
##   is +0), `own` key -> the item's OWN RefItemID where `worn` names a model
##   switcher's row (its glow and seal stand in where that row has none,
##   CharacterAppearance.glow_sources, round 843).
##   Keys: the equip slot (0..12) for a source that names one -- the world's
##   spawn, 0x3038 and the own equipment -- or the item's place in its list for
##   one that does not (the 0xB007 record, the create kit); the avatars under
##   CharacterAppearance.AVATAR_KEY_BASE + n (the avatar inventory's wings,
##   dresses, hats, attachments, flags, the devil's spirit -- the round 838
##   mall's visual items are avatars too). The builder reads an item's visual
##   slot from its TypeIDs, never from its key (READ, ResolveVisualSlotForItem).
## - The job suit is `worn[8]` (suit()): the job state the plate and the colours
##   follow is derived from it (FUN_009dbcc0), not kept beside it.
## - Not here, MEASURED by the census: a mount and a weapon swap change no input
##   of the body's build -- a rider is seated on the COS without a rebuild
##   (World3D._cos_seat), and a swap is the worn slots 6 and 7 changing.
##
## **Where a look comes from** (one builder each): from_lobby (the 0xB007
## record and its own-id trailer), from_spawn (the 0x3015 / group spawn
## snapshot), from_equipment (the own character's worn list, its instances'
## models and pluses, and its avatar inventory), apply_broadcast (a 0x3038 /
## 0x3039 on a look already held), from_ids (a list of RefItemIDs: the create
## kit, an NPC thief's outfit) and bare (a body alone).
##
## **What is made of it**: items() -- CharacterAppearance's build list, the one
## place a worn entry ({"id", "plus", "fx"}) is assembled -- and kind(), the
## string the crowd's template readiness is keyed by.

const SLOT_WEAPON := 6
const SLOT_SHIELD := 7
const SLOT_SUIT := 8
## READ: the scale byte a body is drawn at when nothing names one (Height 2,
## Volume 2).
const DEFAULT_SCALE := 0x22
## OURS (round 789): the keys the avatars are held under: this + the avatar's
## storage slot (own character) or its order in the spawn block or record.
const AVATAR_KEY_BASE := 200
const AVATAR_KEYS := 5

## Round 847: these constants live here, not in CharacterAppearance, and
## nothing in this file names CharacterAppearance in code: the builder refers
## to the look, the look never to the builder. A reference both ways made
## every script that names both (World3D) cost 12.3 MB more to load (MEASURED:
## World3D.gd 70.8 MB of static memory with the base, 83.1 MB with the cycle,
## 70.8 MB without it).

## Whether a key is an avatar's (AVATAR_KEY_BASE).
static func is_avatar_key(key: int) -> bool:
	return key >= AVATAR_KEY_BASE and key < AVATAR_KEY_BASE + AVATAR_KEYS

var ref_obj_id := 0
var gender := ""
var race := -1
var body := ""
var scale := DEFAULT_SCALE
var worn: Dictionary = {}
var pluses: Dictionary = {}
var own: Dictionary = {}

# --- the sources ------------------------------------------------------------

## A body wearing nothing.
static func bare(ref: int = 0, scale_byte: int = DEFAULT_SCALE) -> CharacterLook:
	var l := CharacterLook.new()
	l.ref_obj_id = ref
	l.scale = scale_byte
	return l

## A body wearing `ids` (RefItemIDs, each at `plus`; 0 skipped), keyed by their
## place in the list: the create screen's kit, an NPC thief's outfit.
static func from_ids(ref: int, scale_byte: int, ids: Array, plus: int = 0) -> CharacterLook:
	var l := bare(ref, scale_byte)
	var k := 0
	for id in ids:
		if int(id) == 0:
			continue
		l.worn[k] = int(id)
		if plus != 0:
			l.pluses[k] = plus & 0xFF
		k += 1
	return l

## The select screen's character (0xB007's list record, READ: RefObjID, the
## scale byte, up to 9 equipped items each u32 RefItemID + u8 plus, up to 5
## avatars each u32 RefItemID + a u8 the client discards). Round 847: the
## record names a model switcher's row and the list's own-id trailer (OURS)
## the item's own id, as the world's spawn and 0x3038 do. Items keyed by their
## place in the record, the avatars under AVATAR_KEY_BASE.
static func from_lobby(c: LobbyNet.Character) -> CharacterLook:
	var l := bare(c.ref_obj_id, c.scale)
	for i in c.items.size():
		var it: Dictionary = c.items[i]
		l._put(i, int(it.get("id", 0)), int(it.get("plus", 0)), int(it.get("own", 0)))
	for i in c.avatars.size():
		var a: Dictionary = c.avatars[i]
		l._put(AVATAR_KEY_BASE + i, int(a.get("id", 0)), int(a.get("plus", 0)), 0)
	return l

## Another player as its spawn names it (WorldNet.EntitySnapshot, from the
## 0x3015 / group spawn record or OpenSRO's snapshot): worn by equip slot, the
## avatars under AVATAR_KEY_BASE (UserSpawnNet.to_snapshot), the pluses, the
## body. The record has no own id: a switched item's comes in the 0x3038 the
## server sends after it (apply_broadcast).
static func from_spawn(snap: WorldNet.EntitySnapshot, body_key: String = "") -> CharacterLook:
	var l := bare(snap.ref_obj_id if snap.has_model else 0)
	l.gender = snap.gender
	l.spawned(snap.equipped, snap.pluses, snap.scale if snap.has_model else DEFAULT_SCALE, body_key, true)
	return l

## A spawn (or a repeat of one) on a look already held -- World3D
## ._spawn_or_update_other's rule, round 739's review F8: for a body new to
## view (`fresh`) the spawn's items, body key and scale byte; for one already
## drawn its items only when it names some (an update without them leaves
## what is worn). The pluses tail when given (round 735). A switched item's own
## ids are kept: they come in the 0x3038s after the record (round 843).
func spawned(equipped: Dictionary, spawn_pluses, scale_byte: int, body_key: String, fresh: bool) -> void:
	if fresh or not equipped.is_empty():
		worn = equipped
	if spawn_pluses is Dictionary:
		pluses = spawn_pluses
	if fresh:
		scale = scale_byte
		body = body_key

## The own character (World3D's own body, its equipment window's doll, its
## portrait and every preview of it): `equipped` slot -> the worn item's OWN
## RefItemID (the equipment list); `instances` slot -> ItemInstance (its models
## block and its OptLevel / elixir, NetClient.last_equipment_instances);
## `avatars` / `avatar_pluses` AVATAR_KEY_BASE + n -> RefItemID / plus (the
## avatar inventory). `qa_pluses`, when a Dictionary, stands for every plus (a
## QA loadout with no server, OPENSRO_QA_EQUIP's "+p").
## - A slot whose instance carries a model is drawn as the model's row when it
##   still holds that item (round 838: the server tells other players the same,
##   displayRef), and its own id kept (round 843, the glow and seal).
## - The plus is the item's +0x8c byte (OptLevel + advanced elixir, READ
##   c:0x8bb070, round 734); the avatars' their record's OptLevel (round 789).
static func from_equipment(equipped: Dictionary, instances: Dictionary, avatars: Dictionary = {}, avatar_pluses: Dictionary = {}, qa_pluses = null) -> CharacterLook:
	var l := CharacterLook.new()
	var models := models_of(instances)
	var w := equipped
	if not models.is_empty():
		w = equipped.duplicate()
		for slot in models:
			var it: ItemInstance = instances[slot]
			if w.has(slot) and int(w[slot]) == it.ref_item_id:
				w[slot] = int(models[slot])
	if not avatars.is_empty():
		w = w.duplicate()
		for key in avatars:
			w[int(key)] = int(avatars[key])
	l.worn = w
	if qa_pluses is Dictionary:
		l.pluses = qa_pluses
	else:
		for slot in instances:
			var it: ItemInstance = instances[slot]
			if it != null:
				var p := it.effective_plus() & 0xFF
				if p != 0:
					l.pluses[int(slot)] = p
		for key in avatar_pluses:
			l.pluses[int(key)] = int(avatar_pluses[key])
	for slot in instances:
		var it: ItemInstance = instances[slot]
		if it != null and it.model > 0 and it.model != it.ref_item_id:
			l.own[int(slot)] = it.ref_item_id
	return l

## Slot -> the row a model switcher has the worn item drawn as (ItemInstance
## .model, the worn list's models block; round 838).
static func models_of(instances: Dictionary) -> Dictionary:
	var out := {}
	for slot in instances:
		var it: ItemInstance = instances[slot]
		if it != null and it.model > 0:
			out[int(slot)] = it.model
	return out

# --- updates ----------------------------------------------------------------

## A 0x3038 (plus >= 0) or 0x3039 (plus -1) for this look's character (READ
## FUN_008a9260 / FUN_008a9560): the slot's item put on, its plus changed or
## taken off; an avatar (`avatar`, TypeID 3/1/13 or 3/1/14) attached or
## detached by RefItemID under the first free avatar key, the slot byte not
## used (READ c:0x8a9260 / c:0x8a9560). `own_ref` is round 843's OURS trailer:
## the item's own id after the plus when `ref_id` is a model switcher's row.
## The maps are replaced, not changed in place (a caller may share them).
## Returns {"same_item": the slot still draws the item it drew -- only its
## plus may have changed --, "own_changed": the own id of the slot changed}.
func apply_broadcast(slot: int, ref_id: int, plus: int, own_ref: int, avatar: bool) -> Dictionary:
	var w := worn.duplicate()
	var p := pluses.duplicate()
	var same_item := plus >= 0 and w.has(slot) and int(w[slot]) == ref_id
	var own_changed := false
	if not avatar:
		var o := own.duplicate()
		var was := int(o.get(slot, 0))
		if plus >= 0 and own_ref > 0 and own_ref != ref_id:
			o[slot] = own_ref
		else:
			o.erase(slot)
		if int(o.get(slot, 0)) != was:
			same_item = false
			own_changed = true
		own = o
	if avatar:
		same_item = false
		avatar_into(w, p, ref_id, plus)
	elif plus >= 0:
		w[slot] = ref_id
		if plus > 0:
			p[slot] = plus
		else:
			p.erase(slot)
	else:
		w.erase(slot)
		p.erase(slot)
	worn = w
	pluses = p
	return {"same_item": same_item, "own_changed": own_changed}

## An avatar's 0x3038 (plus >= 0) or 0x3039 on a worn map: attached by
## RefItemID under the first free avatar key, or detached by RefItemID (READ
## c:0x8a9260 / c:0x8a9560). Changes the maps in place.
static func avatar_into(w: Dictionary, p: Dictionary, ref_id: int, plus: int) -> void:
	var held := -1
	for key in w:
		if is_avatar_key(int(key)) and int(w[key]) == ref_id:
			held = int(key)
	if plus < 0:
		if held >= 0:
			w.erase(held)
			p.erase(held)
		return
	if held < 0:
		for k in AVATAR_KEYS:
			if not w.has(AVATAR_KEY_BASE + k):
				held = AVATAR_KEY_BASE + k
				break
	if held < 0:
		return
	w[held] = ref_id
	if plus > 0:
		p[held] = plus
	else:
		p.erase(held)

# --- derived looks ----------------------------------------------------------

## A copy (the maps duplicated).
func copy() -> CharacterLook:
	var l := CharacterLook.new()
	l.ref_obj_id = ref_obj_id
	l.gender = gender
	l.race = race
	l.body = body
	l.scale = scale
	l.worn = worn.duplicate()
	l.pluses = pluses.duplicate()
	l.own = own.duplicate()
	return l

## This look on another body (the skin-change preview's model and scale).
func on_body(ref: int, scale_byte: int) -> CharacterLook:
	var l := copy()
	l.ref_obj_id = ref
	l.scale = scale_byte
	l.body = ""
	l.gender = ""
	l.race = -1
	return l

## Only the weapon and the shield (slots 6 and 7): the skin-change preview of
## the other sex (FUN_007ee450 keeps them; the rest of the gear and the
## avatars only on the player's own sex).
func arms_only() -> CharacterLook:
	var l := copy()
	for key in worn.keys():
		if int(key) != SLOT_WEAPON and int(key) != SLOT_SHIELD:
			l.worn.erase(key)
	return l

## The equipment without its avatars, then `refs` (RefItemIDs, 0 skipped) as
## avatars with no plus: the item mall's preview, which dresses a copy of the
## Equipment window's character with the try-on's avatars (READ 0xa617d0 mode
## 0; 0xa60ef0(ref) takes no plus).
func with_avatars(refs: Array) -> CharacterLook:
	var l := copy()
	for key in worn.keys():
		if is_avatar_key(int(key)):
			l.worn.erase(key)
	for key in pluses.keys():
		if is_avatar_key(int(key)):
			l.pluses.erase(key)
	var k := 0
	for ref in refs:
		if int(ref) != 0:
			l.worn[AVATAR_KEY_BASE + k] = int(ref)
			k += 1
	return l

## The worn map without the avatar keys (the item mall's weapon group).
func equipment() -> Dictionary:
	var out := worn.duplicate()
	for key in worn:
		if is_avatar_key(int(key)):
			out.erase(key)
	return out

# --- reading it ---------------------------------------------------------------

## The RefItemID drawn at `key` (0 none).
func item_at(key: int) -> int:
	return int(worn.get(key, 0))

## The worn job suit's RefItemID (slot 8; 0 none).
func suit() -> int:
	return item_at(SLOT_SUIT)

func is_empty() -> bool:
	return worn.is_empty()

## CharacterAppearance's build list: one {"id": the drawn RefItemID, "plus":
## u8} per worn key, in the worn map's order, and "fx" the item's own
## RefItemID for a model switcher's row (round 843; left out otherwise, so the
## lists and the kinds and far recipes keyed by them are what they were). Id 0
## is skipped; `drawable`, when valid, is asked of every other id (World3D: an
## id its item table has a worn model for -- `log_misses` names the miss).
func items(drawable: Callable = Callable(), log_misses: bool = false) -> Array:
	var out: Array = []
	for key in worn:
		var id := int(worn[key])
		if id == 0:
			continue
		if drawable.is_valid() and not bool(drawable.call(id)):
			if log_misses:
				print("World3D: item %d in slot %d has no worn model in the item table -- not drawn" % [id, key])
			continue
		var item := {"id": id, "plus": int(pluses.get(key, 0)) & 0xFF}
		var o := int(own.get(key, 0))
		if o > 0 and o != id:
			item["fx"] = o
		out.append(item)
	return out

## The key a body's templates are asked for under (World3D's crowd kinds,
## CharacterAppearance.kind_ready): the body key, the worn and plus maps, and a
## model switcher's own ids when there are any (round 843).
func kind(body_key: String) -> String:
	var k := "%s|%s|%s" % [body_key, str(worn), str(pluses)]
	if not own.is_empty():
		k += "|fx" + str(own)
	return k

## One line for the logs.
func describe() -> String:
	return "body %d%s scale 0x%02x worn %s pluses %s%s" % [ref_obj_id, (" (%s)" % body) if body != "" else "",
		scale, str(worn), str(pluses), (" own %s" % str(own)) if not own.is_empty() else ""]

# --- internal -----------------------------------------------------------------

func _put(key: int, id: int, plus: int, own_id: int) -> void:
	worn[key] = id
	if plus & 0xFF != 0:
		pluses[key] = plus & 0xFF
	if own_id > 0 and own_id != id:
		own[key] = own_id
