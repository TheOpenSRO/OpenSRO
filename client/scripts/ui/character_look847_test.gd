extends SceneTree

## Round 847: CharacterLook, the one value every site that draws a character
## builds from, and the select screen drawing a model switcher's row.
##   godot4 --headless --path client --script res://scripts/ui/character_look847_test.gd
## - a look from each source: the 0xB007 record (and its own-id trailer), the
##   world's spawn snapshot, the own equipment (instances, models, pluses,
##   avatars), a 0x3038 / 0x3039, an id list, a bare body;
## - the build list and the crowd kind a look makes are the bytes the sites
##   made before (World3D._wear_item's dicts, its kind string);
## - the select screen with a switched item: the list's trailer reaches the
##   builder as the item's own id, so the twin takes the item's glow and seal
##   (NEGATIVE: a pre-847 list, the record naming the item's own row and no
##   trailer, draws the item's original model -- the user's bug);
## - the guard: no site assembles a character's build input itself.
## Ids and code names are test values in the files' formats (no game data).

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

const LOCKED := "ITEM_TEST_BLADE_11_A_RARE"
const UNLOCKED := "ITEM_TEST_BLADE_11_A_RARE_ACTIVE"
const TWIN := "ITEM_TEST_BLADE_11_A_RARE_SWITCH13"
const PLAIN_TWIN := "ITEM_TEST_BLADE_11_A_SWITCH13"
const ID_UNLOCKED := 102
const ID_TWIN := 103
const ID_CHEST := 201
const ID_AVATAR := 301

func _bytes(lines: Array) -> PackedByteArray:
	return "\r\n".join(PackedStringArray(lines)).to_ascii_buffer()

## Round 843's tables (item_switch_glow843_test): the unlocked row has a glow
## type and a seal, its locked row's twin none, the plain twin a type.
func _appearance() -> CharacterAppearance:
	var t := ItemGlowTables.new()
	t.load_options(_bytes(["//_HONOR\ttype_number", UNLOCKED + "\t4", PLAIN_TWIN + "\t3"]))
	var rows: Array = []
	for type_number in [3, 4]:
		for p in [3, 8, 12]:
			rows.append("%d \t%d\t0.005000,-0.005000\tprim\\mtrl\\itemoption\\test%d.ddj\t5\t7\t0.1,0.2,0.3\t0.9,0.8,0.7\t1000\t0" % [
				type_number, p, p])
	t.load_types(_bytes(rows))
	t.load_particles(_bytes(["//Item Code Name\tParticle\tScale\tBone\tOffset",
		UNLOCKED + "\tsystem\\test_nova_01.efp\t230\tai_end\tnone"]), ItemGlowTables.RARE_PATH)
	var a := CharacterAppearance.new()
	a.glow_tables = t
	var blade := PackedInt32Array([3, 1, 6, 3])
	for pair in [[ID_UNLOCKED, UNLOCKED], [ID_TWIN, TWIN]]:
		a._items[int(pair[0])] = {"models": PackedStringArray(["item\\test_%d.bsr" % int(pair[0])]), "type_ids": blade, "code": String(pair[1])}
	a._items[ID_CHEST] = {"models": PackedStringArray(["item\\test_chest.bsr"]), "type_ids": PackedInt32Array([3, 1, 1, 3]), "code": "ITEM_TEST_CHEST"}
	return a

func _initialize() -> void:
	_test_lobby()
	_test_spawn()
	_test_equipment()
	_test_broadcast()
	_test_ids_and_derived()
	_test_items_and_kind_as_before()
	_test_select_screen_switched()
	_test_guard()
	print("FAILURES: %d" % _failures if _failures > 0 else "all passed")
	quit(1 if _failures > 0 else 0)

# --- the sources ---------------------------------------------------------------

func _test_lobby() -> void:
	var c := LobbyNet.Character.new()
	c.ref_obj_id = 1907
	c.scale = 0x41
	c.items = [{"id": ID_CHEST, "plus": 0}, {"id": ID_TWIN, "plus": 12, "own": ID_UNLOCKED}]
	c.avatars = [{"id": ID_AVATAR, "plus": 2}]
	var l := CharacterLook.from_lobby(c)
	_check(l.ref_obj_id == 1907 and l.scale == 0x41, "lobby: the record's body and scale byte")
	_check(l.worn == {0: ID_CHEST, 1: ID_TWIN, CharacterAppearance.AVATAR_KEY_BASE: ID_AVATAR},
		"lobby: items by their place in the record, the avatars under AVATAR_KEY_BASE (%s)" % str(l.worn))
	_check(l.own == {1: ID_UNLOCKED} and l.pluses == {1: 12, CharacterAppearance.AVATAR_KEY_BASE: 2}, "lobby: the trailer's own id and the pluses")
	_check(l.items() == [{"id": ID_CHEST, "plus": 0}, {"id": ID_TWIN, "plus": 12, "fx": ID_UNLOCKED}, {"id": ID_AVATAR, "plus": 2}],
		"lobby: the build list is the record's items then its avatars, as the select screen built it (%s)" % str(l.items()))

func _test_spawn() -> void:
	var s := WorldNet.EntitySnapshot.new()
	s.ref_obj_id = 14875
	s.scale = 0x13
	s.has_model = true
	s.gender = "europe_man"
	s.equipped = {1: ID_CHEST, 6: ID_TWIN, 200: ID_AVATAR}
	s.pluses = {6: 12}
	var l := CharacterLook.from_spawn(s, "EUROPE_MAN_BODY")
	_check(l.ref_obj_id == 14875 and l.scale == 0x13 and l.gender == "europe_man" and l.body == "EUROPE_MAN_BODY", "spawn: the record's body")
	_check(l.worn == s.equipped and l.pluses == s.pluses and l.own.is_empty(), "spawn: worn by slot with the pluses tail, no own id (it comes in the 0x3038 after)")
	var old := WorldNet.EntitySnapshot.new()
	old.gender = "china_woman"
	old.scale = 0x40
	var lo := CharacterLook.from_spawn(old)
	_check(lo.ref_obj_id == 0 and lo.scale == CharacterAppearance.DEFAULT_SCALE and lo.gender == "china_woman",
		"spawn without a model (an older server): the gender's body at the default scale")
	# A repeat spawn of a body already drawn: its items only when it names
	# some, its scale and body kept; the own ids from the 0x3038s kept.
	l.own = {6: ID_UNLOCKED}
	l.spawned({}, null, 0x44, "OTHER", false)
	_check(l.worn == s.equipped and l.scale == 0x13 and l.body == "EUROPE_MAN_BODY" and l.own == {6: ID_UNLOCKED},
		"a repeat spawn naming nothing leaves the look")
	l.spawned({1: ID_CHEST}, {}, 0x44, "OTHER", false)
	_check(l.worn == {1: ID_CHEST} and l.pluses.is_empty() and l.scale == 0x13 and l.own == {6: ID_UNLOCKED}, "a repeat spawn naming items: those items")
	l.spawned({}, null, 0x44, "OTHER", true)
	_check(l.worn.is_empty() and l.scale == 0x44 and l.body == "OTHER", "a body new to view: what its spawn names, even nothing")

func _test_equipment() -> void:
	var sword := ItemInstance.new()
	sword.slot = 6
	sword.ref_item_id = ID_UNLOCKED
	sword.opt_level = 10
	sword.adv_elixir = 2
	sword.model = ID_TWIN
	var chest := ItemInstance.new()
	chest.slot = 1
	chest.ref_item_id = ID_CHEST
	var instances := {1: chest, 6: sword}
	var l := CharacterLook.from_equipment({1: ID_CHEST, 6: ID_UNLOCKED}, instances, {200: ID_AVATAR}, {200: 3})
	_check(l.worn == {1: ID_CHEST, 6: ID_TWIN, 200: ID_AVATAR}, "own: the switched slot drawn as its model, the avatars after (%s)" % str(l.worn))
	_check(l.own == {6: ID_UNLOCKED}, "own: the item's own id kept for its glow and seal")
	_check(l.pluses == {6: 12, 200: 3}, "own: OptLevel + elixir, and the avatar's plus (%s)" % str(l.pluses))
	_check(CharacterLook.models_of(instances) == {6: ID_TWIN}, "own: models_of")
	# A slot that no longer holds the switched item is drawn as what it holds.
	var other := CharacterLook.from_equipment({1: ID_CHEST, 6: 999}, instances)
	_check(other.item_at(6) == 999, "own: the model applies only while the slot holds its item")
	# With no server, a QA loadout's pluses stand for all of them.
	var qa := CharacterLook.from_equipment({6: ID_UNLOCKED}, {}, {}, {}, {6: 7})
	_check(qa.pluses == {6: 7} and qa.own.is_empty() and qa.worn == {6: ID_UNLOCKED}, "own, no server: the QA loadout's pluses")
	var plain := CharacterLook.from_equipment({1: ID_CHEST}, {})
	_check(plain.worn == {1: ID_CHEST} and plain.items() == [{"id": ID_CHEST, "plus": 0}], "own: no instances, the ids as they are")

func _test_broadcast() -> void:
	var l := CharacterLook.new()
	l.worn = {6: ID_TWIN}
	l.pluses = {6: 11}
	var shared := l.worn
	var r := l.apply_broadcast(6, ID_TWIN, 12, 0, false)
	_check(bool(r["same_item"]) and l.pluses == {6: 12} and shared == {6: ID_TWIN}, "0x3038 plus only: same item, the plus changed, a shared map untouched")
	r = l.apply_broadcast(6, ID_TWIN, 12, ID_UNLOCKED, false)
	_check(not bool(r["same_item"]) and bool(r["own_changed"]) and l.own == {6: ID_UNLOCKED}, "0x3038 with the own id (round 843's trailer): a redraw")
	r = l.apply_broadcast(6, ID_UNLOCKED, 12, 0, false)
	_check(l.own.is_empty() and l.item_at(6) == ID_UNLOCKED and not bool(r["same_item"]), "a plain 0x3038: the own id goes")
	l.apply_broadcast(6, ID_UNLOCKED, 0, 0, false)
	_check(not l.pluses.has(6), "+0: the plus goes")
	l.apply_broadcast(7, 0, -1, 0, false)
	l.apply_broadcast(6, ID_UNLOCKED, -1, 0, false)
	_check(l.worn.is_empty() and l.pluses.is_empty(), "0x3039: the slot is empty")
	r = l.apply_broadcast(4, ID_AVATAR, 5, 0, true)
	_check(l.worn == {CharacterAppearance.AVATAR_KEY_BASE: ID_AVATAR} and l.pluses == {CharacterAppearance.AVATAR_KEY_BASE: 5}
		and not bool(r["same_item"]), "an avatar's 0x3038: under the first free avatar key, the slot byte not used")
	l.apply_broadcast(4, ID_AVATAR + 1, 0, 0, true)
	_check(l.item_at(CharacterAppearance.AVATAR_KEY_BASE + 1) == ID_AVATAR + 1, "a second avatar: the next key")
	l.apply_broadcast(9, ID_AVATAR, -1, 0, true)
	_check(not l.worn.has(CharacterAppearance.AVATAR_KEY_BASE) and l.worn.size() == 1, "an avatar's 0x3039: by RefItemID")

func _test_ids_and_derived() -> void:
	var l := CharacterLook.from_ids(1907, 0x22, [ID_CHEST, 0, ID_TWIN])
	_check(l.items() == [{"id": ID_CHEST, "plus": 0}, {"id": ID_TWIN, "plus": 0}], "from_ids: the kit at +0, 0 skipped (the create preview's list)")
	_check(CharacterLook.bare(1907).items().is_empty() and CharacterLook.bare(1907).scale == CharacterAppearance.DEFAULT_SCALE, "bare: nothing worn")
	var own := CharacterLook.new()
	own.worn = {1: ID_CHEST, 6: ID_TWIN, 7: 55, 200: ID_AVATAR}
	own.pluses = {6: 12, 200: 3}
	own.own = {6: ID_UNLOCKED}
	own.scale = 0x22
	var skin := own.on_body(14875, 0x44)
	_check(skin.ref_obj_id == 14875 and skin.scale == 0x44 and skin.worn == own.worn and own.scale == 0x22, "on_body: another model, the look kept, the source unchanged")
	_check(own.arms_only().worn == {6: ID_TWIN, 7: 55} and own.arms_only().own == {6: ID_UNLOCKED}, "arms_only: the weapon and the shield (the skin preview off its sex)")
	var mall := own.with_avatars([0, 777, 778])
	_check(mall.worn == {1: ID_CHEST, 6: ID_TWIN, 7: 55, 200: 777, 201: 778} and mall.pluses == {6: 12},
		"with_avatars: the try-on's avatars without a plus in place of the own (%s %s)" % [str(mall.worn), str(mall.pluses)])
	_check(mall.equipment() == {1: ID_CHEST, 6: ID_TWIN, 7: 55} and own.suit() == 0, "equipment() and suit()")

## The bytes the sites made before round 847: World3D._wear_item's dicts and
## the crowd kind string of _other_template_ready (copied here as they were).
func _test_items_and_kind_as_before() -> void:
	var equipped := {1: ID_CHEST, 6: ID_TWIN, 200: ID_AVATAR}
	var pluses := {6: 12}
	var fx := {6: ID_UNLOCKED}
	var before: Array = []
	for slot in equipped:
		var item := {"id": int(equipped[slot]), "plus": int(pluses.get(slot, 0)) & 0xFF}
		var o := int(fx.get(slot, 0))
		if o > 0 and o != int(equipped[slot]):
			item["fx"] = o
		before.append(item)
	var l := CharacterLook.new()
	l.worn = equipped
	l.pluses = pluses
	l.own = fx
	_check(str(l.items()) == str(before), "items(): the dicts World3D._wear_item made, in the same order (%s)" % str(l.items()))
	var kind := "%s|%s|%s" % ["BODY", str(equipped), str(pluses)] + "|fx" + str(fx)
	_check(l.kind("BODY") == kind, "kind(): the string _other_template_ready made")
	l.own = {}
	_check(l.kind("BODY") == "%s|%s|%s" % ["BODY", str(equipped), str(pluses)], "kind() without own ids: no fx part")
	var known := func(id: int) -> bool: return id != ID_AVATAR
	_check(l.items(known).size() == 2, "items(drawable): an id the item table has no model for is left out")

# --- the select screen ---------------------------------------------------------

## A 0xB007 list as the round-847 server sends it: the record names the twin,
## the trailer the item's own id. Decoded, made a look and resolved as the
## select screen's build resolves it, the twin keeps the unlocked item's seal
## and the plain twin's glow type.
func _test_select_screen_switched() -> void:
	var r := LobbyNet.Result.new()
	r.action = LobbyNet.ACTION_LIST
	r.ok = true
	var c := LobbyNet.Character.new()
	c.ref_obj_id = 1907
	c.char_name = "Seal"
	c.scale = 0x22
	c.items = [{"id": ID_CHEST, "plus": 0}, {"id": ID_TWIN, "plus": 12, "own": ID_UNLOCKED}]
	r.characters = [c]
	var bytes := LobbyNet.encode_result(r)
	var got := LobbyNet.decode_result(bytes)
	_check(got.error == "" and got.characters.size() == 1, "the list decodes (%s)" % got.error)
	var look := CharacterLook.from_lobby(got.characters[0])
	var a := _appearance()
	var wears: Array = a._resolve_wears(look.items(), false, false)[0]
	var blade: Dictionary = {}
	for w in wears:
		if int(w["slot"]) == CharacterAppearance.SLOT_WEAPON:
			blade = w
	_check(not blade.is_empty() and String(blade["code"]) == TWIN and (blade["models"] as PackedStringArray)[0] == "item\\test_%d.bsr" % ID_TWIN,
		"select: the weapon is drawn as the model switcher's row (%s)" % str(blade.get("models")))
	_check(CharacterAppearance.fx_code_of(blade) == UNLOCKED and CharacterAppearance.glow_code_of(blade) == PLAIN_TWIN and int(blade["plus"]) == 12,
		"select: +12 with the item's own seal and the model's glow type (%s / %s)" % [CharacterAppearance.fx_code_of(blade), CharacterAppearance.glow_code_of(blade)])
	_check(a.glow_tables.glow_row(CharacterAppearance.glow_code_of(blade), 12) != null
		and not a.glow_tables.particle_rows(CharacterAppearance.fx_code_of(blade), 12).is_empty(), "select: a glow row and the seal's effects to draw")
	# NEGATIVE, the pre-847 list: the record names the item's own row and no
	# trailer follows -- the select screen draws the unlocked item's own model.
	var old := LobbyNet.Character.new()
	old.ref_obj_id = 1907
	old.items = [{"id": ID_UNLOCKED, "plus": 12}]
	var ow: Array = a._resolve_wears(CharacterLook.from_lobby(old).items(), false, false)[0]
	_check(ow.size() == 1 and (ow[0]["models"] as PackedStringArray)[0] == "item\\test_%d.bsr" % ID_UNLOCKED,
		"NEGATIVE pre-847: the item's own model, not the switched one")
	# The trailer alone, without the record naming the twin, is not the fix:
	# a list whose record names the twin but lost its trailer draws it plain.
	var cut := bytes.slice(0, bytes.size() - 8)
	var plain := LobbyNet.decode_result(cut)
	var pw: Array = a._resolve_wears(CharacterLook.from_lobby(plain.characters[0]).items(), false, false)[0]
	var pb: Dictionary = pw[pw.size() - 1]
	_check(plain.error == "" and CharacterAppearance.fx_code_of(pb) == TWIN, "without the trailer the twin is drawn with its own (empty) rows")

# --- the guard ---------------------------------------------------------------------

## Files that may assemble a build list or an item entry, and why.
const ASSEMBLY_ALLOWED := {
	"res://scripts/ui/character_look.gd": "the one place a look's build list is made",
	"res://scripts/ui/character_appearance.gd": "the builder: its own wear entries",
	"res://scripts/net/lobby.gd": "the 0xB007 wire record",
	"res://scripts/net/user_spawn.gd": "the 0x3015 wire record",
	"res://scripts/net/avatar_net.gd": "the avatar block's wire record",
	"res://scripts/CharacterSelect.gd": "its QA sample builds a fake 0xB007 record",
}
## Every site of the census (docs/protocol/character_look.md section 4) names
## CharacterLook.
const SITES := [
	"res://scripts/World3D.gd", "res://scripts/frontend/charselect_stage.gd", "res://scripts/frontend/charcreate_preview.gd",
	"res://scripts/frontend/charcreate_model.gd", "res://scripts/CharacterSelect.gd", "res://scripts/world/mall_models.gd",
	"res://scripts/frontend/char_catalog.gd", "res://scripts/world/qa_crowd_probe.gd",
]
## What World3D assembled appearance with before round 847; none may return.
const GONE_FROM_WORLD := ["func _wear_item(", "func _display_equipped(", "func _player_fx(", "func _player_pluses(",
	"func _with_player_avatars(", "func _other_build_spec(", "func _equipment_models(", "static func avatar_broadcast_into(",
	"var _other_equipped ", "var _other_pluses ", "var _other_fx ", "var _player_pluses_last"]

static func _violations(path: String, text: String) -> PackedStringArray:
	var out := PackedStringArray()
	if path == "res://scripts/ui/character_look.gd" or path == "res://scripts/ui/character_appearance.gd":
		return out
	var raw := RegEx.create_from_string("(?i)appearance\\s*\\.\\s*(build|far_recipe|kind_ready|templates_ready|prepare|template_paths)\\s*\\(")
	var entry := RegEx.create_from_string("\\{\\s*\"id\"\\s*:[^}]*\"plus\"\\s*:")
	var lines := text.split("\n")
	for i in lines.size():
		var line := lines[i]
		if line.strip_edges().begins_with("#"):
			continue
		if raw.search(line) != null:
			out.append("%s:%d calls the builder with its own list (use build_look / far_recipe_look / kind_ready_look): %s" % [path, i + 1, line.strip_edges()])
		if entry.search(line) != null and not ASSEMBLY_ALLOWED.has(path):
			out.append("%s:%d makes an item entry itself (CharacterLook.items is the one place): %s" % [path, i + 1, line.strip_edges()])
	return out

static func _scripts(dir: String, out: PackedStringArray) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd") and not f.ends_with("_test.gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_scripts(dir.path_join(sub), out)

func _test_guard() -> void:
	# The guard catches what it is for (NEGATIVE: the pre-847 sites).
	var before := "\t\td.body = appearance.build(r.ref_obj_id, r.scale, items)\n\tvar recipe := _appearance.far_recipe(int(spec[0]), scale, spec[1])\n\t\titems.append({\"id\": int(id), \"plus\": 0})\n"
	_check(_violations("res://scripts/frontend/charselect_stage.gd", before).size() == 3, "the guard finds a pre-847 site's own assembly (3 lines)")
	_check(_violations("res://scripts/frontend/charselect_stage.gd", "\td.body = appearance.build_look(CharacterLook.from_lobby(r))\n").is_empty(),
		"... and passes build_look")
	var files := PackedStringArray()
	_scripts("res://scripts", files)
	_check(files.size() > 300, "the guard reads the client's scripts (%d)" % files.size())
	var found := PackedStringArray()
	for path in files:
		var text := FileAccess.get_file_as_string(path)
		found.append_array(_violations(path, text))
	for v in found:
		print("  " + v)
	_check(found.is_empty(), "no script outside CharacterLook / CharacterAppearance assembles a character's build input (%d found)" % found.size())
	for path in SITES:
		_check(FileAccess.get_file_as_string(path).contains("CharacterLook"), "%s builds from CharacterLook" % path)
	var world := FileAccess.get_file_as_string("res://scripts/World3D.gd")
	for gone in GONE_FROM_WORLD:
		_check(not world.contains(gone), "World3D no longer has %s" % gone.strip_edges())
	_check(world.contains("func _build_assembled_character(look: CharacterLook"), "World3D's funnel takes a look")
