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
## {slot: {item, slot}}}. Every field is type-checked; an entry with a field
## of the wrong type, out of range or of an unknown kind is skipped, and the
## rest still load (round 639's review).
static func decode(entries: Array) -> Dictionary:
	var skills := {}
	var items := {}
	for raw in entries:
		if not (raw is Dictionary):
			continue
		var e: Dictionary = raw
		if not (_is_int(e.get("slot")) and e.get("kind") is String):
			continue
		var slot := int(e["slot"])
		if slot < 0 or slot >= HudUnderbar.MAX_QUICKSLOT:
			continue
		match String(e["kind"]):
			"skill":
				if _is_int(e.get("id")) and int(e["id"]) > 0 and e.get("code", "") is String:
					skills[slot] = {"id": int(e["id"]), "code": String(e.get("code", ""))}
			"item":
				if _is_int(e.get("item")) and _is_int(e.get("bag")) and int(e["item"]) >= 0 and int(e["bag"]) >= 0:
					items[slot] = {"item": int(e["item"]), "slot": int(e["bag"])}
	return {"skills": skills, "items": items}

static func _is_int(v: Variant) -> bool:
	return typeof(v) == TYPE_INT

## Writes one character's bar, keeping every other entry in the file.
##
## A file that exists but does not load (a parse error, a half-written copy)
## is left alone and nothing is written: saving over it would drop every
## other character's entry (round 639's review). The write goes to a
## temporary file that is then renamed over the old one, so a crash mid-write
## leaves the previous file whole.
static func save(key: String, skills: Dictionary, items: Dictionary, path: String = PATH) -> bool:
	var file := ConfigFile.new()
	if FileAccess.file_exists(path):
		var err := file.load(path)
		if err != OK:
			push_warning("HotbarStore: %s does not load (error %d) -- not overwriting it" % [path, err])
			print("HotbarStore: %s does not load (error %d) -- the bar is not saved" % [path, err])
			return false
	file.set_value(SECTION, key, {"version": VERSION, "slots": encode(skills, items)})
	var tmp := path + ".tmp"
	if file.save(tmp) != OK:
		return false
	var from := ProjectSettings.globalize_path(tmp)
	var to := ProjectSettings.globalize_path(path)
	if DirAccess.rename_absolute(from, to) == OK:
		return true
	# A platform whose rename will not replace an existing file: remove, then
	# rename (the old copy is lost only for that moment).
	DirAccess.remove_absolute(to)
	return DirAccess.rename_absolute(from, to) == OK

## Reads one character's bar; empty when there is none or it does not load.
static func load_bar(key: String, path: String = PATH) -> Dictionary:
	var file := ConfigFile.new()
	if file.load(path) != OK:
		return {"skills": {}, "items": {}}
	if not file.has_section_key(SECTION, key):
		return {"skills": {}, "items": {}}
	var v: Variant = file.get_value(SECTION, key, {})
	if not (v is Dictionary) or not _is_int((v as Dictionary).get("version")) \
			or int((v as Dictionary)["version"]) != VERSION:
		return {"skills": {}, "items": {}}
	var slots: Variant = (v as Dictionary).get("slots", [])
	return decode(slots if slots is Array else [])

## Retail's rebind after a skill is learned or withdrawn (READ, CNIFUnderMenuBar
## 0x60c230, reached through 0x778840 from AddLearnedSkill 0x880be0 with
## learned = true and from the withdrawal 0x880db0 with false). `skills` is
## the bar's {slot: {id, code}}, changed in place; `level_ids` is the skill's
## group, index i = level i + 1's id. Returns the slots it changed.
##
## - Learned: the new id's level less one is found (the record's level byte
##   +0x60, then 0x93f770(group, level)); a level-1 skill changes nothing.
##   Every skill slot (kind 0x49) holding that previous level's id takes the
##   new id.
## - Withdrawn (the id the server names, the group's level after the
##   withdrawal): every skill slot (kinds 0x49 and 0x19) holding exactly that
##   id is cleared; every other slot of the same group (record +4) takes it.
## Retail saves each changed slot (0x60bea0); World3D saves the file after.
static func rebind_for_skill(skills: Dictionary, new_id: int, learned: bool, level_ids: PackedInt64Array) -> Array:
	var changed: Array = []
	var at := level_ids.find(new_id)
	if at < 0:
		return changed
	if learned:
		if at == 0:
			return changed
		var prev := int(level_ids[at - 1])
		if prev <= 0:
			return changed
		for slot in skills.keys():
			if int((skills[slot] as Dictionary)["id"]) == prev:
				skills[slot] = {"id": new_id, "code": String((skills[slot] as Dictionary).get("code", ""))}
				changed.append(slot)
	else:
		for slot in skills.keys():
			var id := int((skills[slot] as Dictionary)["id"])
			if id == new_id:
				skills.erase(slot)
				changed.append(slot)
			elif level_ids.has(id):
				skills[slot] = {"id": new_id, "code": String((skills[slot] as Dictionary).get("code", ""))}
				changed.append(slot)
	return changed
