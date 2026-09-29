extends RefCounted
class_name HotbarStore

## The quick-slot bar, kept between sessions on the client (round 639) --
## OURS, at the user's request.
##
## READ: retail keeps it on the SERVER. CNIFUnderMenuBar's save (0x60bea0,
## and IFUnderBar's dead copy 0x68cec0) sends packet 0x7158 on every change
## with the slot (0..50, the 0x33 MAX_QUICKSLOT assert at 0x68ceed), the slot's
## kind (0x666720) and a u32: the skill id for a skill (0x666730), the
## inventory slot for a bag item (0x666800, bounded by the bag's size,
## 0x6af600). The character-data handler 0x8ab0e0 reads them back at game
## entry through 0x8a7c50 -- a u8 flag, a u8 count, count x {u8 slot, u8 kind,
## u32 data} into 0xef1b68 / 0xef1b6c -- and 0x60b260 fills the bar from
## them. So an item is bound by its bag slot, and the bar's rebind
## (0x60c430) follows a moved item.
##
## Here the same bindings go to `user://quickslots.cfg`, one entry per server
## and character: every skill and item slot on every page, the skill by its
## id and Basic_Code, an item by its item id and bag slot. World3D writes the
## file on every change and reads it once the bar exists; an item is
## re-resolved against the bag when the inventory arrives
## (HudUnderbar.resolve_item_binding: its slot first, as retail binds it,
## then the same item anywhere, else the binding is dropped).

const PATH := "user://quickslots.cfg"
const SECTION := "quickslots"
## Bumped if the entry layout ever changes; an unknown version is ignored.
const VERSION := 1

## The entry key for one character on one server: both parts percent-encoded,
## so any character name is a safe ConfigFile key.
static func key_for(server: String, character: String) -> String:
	return "%s/%s" % [server.uri_encode(), character.uri_encode()]

## The bar as a list of plain dictionaries, sorted by slot.
static func encode(skills: Dictionary, items: Dictionary) -> Array:
	var out: Array = []
	var slots: Array = []
	for s in skills:
		slots.append(int(s))
	for s in items:
		if not skills.has(s):
			slots.append(int(s))
	slots.sort()
	for s in slots:
		if skills.has(s):
			var e: Dictionary = skills[s]
			out.append({"slot": s, "kind": "skill", "id": int(e.get("id", 0)), "code": String(e.get("code", ""))})
		else:
			var e: Dictionary = items[s]
			out.append({"slot": s, "kind": "item", "item": int(e.get("item", -1)), "bag": int(e.get("slot", -1))})
	return out

## The bar back from encode's list: {"skills": {slot: {id, code}}, "items":
## {slot: {item, slot}}}. An entry out of range or malformed is skipped.
static func decode(entries: Array) -> Dictionary:
	var skills := {}
	var items := {}
	for raw in entries:
		if not (raw is Dictionary):
			continue
		var e: Dictionary = raw
		var slot := int(e.get("slot", -1))
		if slot < 0 or slot >= HudUnderbar.MAX_QUICKSLOT:
			continue
		match String(e.get("kind", "")):
			"skill":
				var id := int(e.get("id", 0))
				if id > 0:
					skills[slot] = {"id": id, "code": String(e.get("code", ""))}
			"item":
				var item := int(e.get("item", -1))
				var bag := int(e.get("bag", -1))
				if item >= 0 and bag >= 0:
					items[slot] = {"item": item, "slot": bag}
	return {"skills": skills, "items": items}

## Writes one character's bar, keeping every other entry in the file.
static func save(key: String, skills: Dictionary, items: Dictionary, path: String = PATH) -> bool:
	var file := ConfigFile.new()
	file.load(path) # a missing file is fine; it is about to exist
	file.set_value(SECTION, key, {"version": VERSION, "slots": encode(skills, items)})
	return file.save(path) == OK

## Reads one character's bar; empty when there is none.
static func load_bar(key: String, path: String = PATH) -> Dictionary:
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return {"skills": {}, "items": {}}
	if not file.has_section_key(SECTION, key):
		return {"skills": {}, "items": {}}
	var v: Variant = file.get_value(SECTION, key, {})
	if not (v is Dictionary) or int((v as Dictionary).get("version", 0)) != VERSION:
		return {"skills": {}, "items": {}}
	var slots: Variant = (v as Dictionary).get("slots", [])
	return decode(slots if slots is Array else [])
