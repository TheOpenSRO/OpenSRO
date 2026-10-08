extends SceneTree

## Round 748's review, F1/F5: no `const` Array is read element by element in
## the scripts WorkerThreadPool tasks run. Run headless on the render box:
## `client/tools/remote_godot.sh tests`.
##
## Why (READ, Godot 4.2.2): a GDScript `const` Array or Dictionary literal is
## made read-only (`modules/gdscript/gdscript_analyzer.cpp`,
## make_array_reduced_value -> `array.make_read_only()`, nested literals too),
## and a read-only Array hands out each element through ONE Variant slot it
## shares with every reader (`core/variant/array.cpp:84-98`: `*_p->read_only
## = _p->array[p_idx]`). The VM's `for` over an Array (`array->get(i)`,
## gdscript_vm.cpp) and `CONST[i]` both go through it. Two threads reading
## the same constant swap Variants through that slot unlocked: with Strings
## or Arrays the reference counts break and the heap is corrupted (the
## review: 18 of 19 stress runs crashed on `_fallback_of`'s
## `_FALLBACK_SUFFIXES`); with ints a thread may read the other's element.
## A `static var` Array is not read-only (only `const` initialisers are
## folded, gdscript_analyzer.cpp ~1899), so it returns the element itself.
## A Dictionary's keyed read and its `for` go through const paths that do not
## touch the slot (dictionary.cpp getptr const, `next`; variant_setget.cpp
## VariantKeyedSetGetDictionary / get_named), but its nested Array values are
## read-only Arrays: a const Dictionary holding Arrays is flagged too.
##
## The rule this holds: in WORKER_FILES (every script round 748's audit found
## reachable from a WorkerThreadPool task, less the UI and world scripts whose
## task code reads no constant -- r748.md "The const audit"), a `const` whose
## value is an Array literal is never iterated, indexed, read by an element
## method or handed on as a value, anywhere in the client; and no `const`
## Dictionary there holds an Array. Membership (`x in CONST`, `.has`) and
## `.size()` read the array directly and are allowed.
##
## NEGATIVE: the detector is run on a snippet with each banned form and must
## flag every one; with `_fallback_of` as it was before the review (a `for`
## over `_FALLBACK_SUFFIXES`), this suite fails on character_appearance.gd.

const WORKER_FILES := [
	"res://scripts/assets/asset_source.gd", "res://scripts/assets/body_animations.gd",
	"res://scripts/assets/character_assembler.gd", "res://scripts/assets/mapm_terrain_builder.gd",
	"res://scripts/assets/object_loader.gd", "res://scripts/assets/pk2_config.gd",
	"res://scripts/assets/skeleton3d_builder.gd", "res://scripts/assets/skeleton_pose.gd",
	"res://scripts/assets/skinned_bsr_assembler.gd", "res://scripts/assets/terrain_collision.gd",
	"res://scripts/audio/audio_bank.gd", "res://scripts/audio/skill_audio.gd", "res://scripts/audio/sound_table.gd",
	"res://scripts/ban/ban_reader.gd", "res://scripts/bms/bms_collision.gd", "res://scripts/bms/bms_reader.gd",
	"res://scripts/bmt/bmt_reader.gd", "res://scripts/bmt/inflate.gd", "res://scripts/bsk/bsk_reader.gd",
	"res://scripts/bsr/bsr_reader.gd", "res://scripts/cpd/cpd_reader.gd", "res://scripts/ddj/ddj_reader.gd",
	"res://scripts/effects/skill_effect_reader.gd", "res://scripts/effects/skill_effects.gd",
	"res://scripts/efp/efp_effect.gd", "res://scripts/efp/efp_reader.gd", "res://scripts/efp/efp_sim.gd",
	"res://scripts/efp/efp_sim_batch.gd",  # round 759 review F3: Job.help runs on the pool
	"res://scripts/frontend/char_catalog.gd", "res://scripts/frontend/intro_camera_path.gd",
	"res://scripts/frontend/title_cell_plan.gd", "res://scripts/items/item_glow_tables.gd",
	"res://scripts/mapm/mapm_reader.gd", "res://scripts/mapo/mapo2_reader.gd", "res://scripts/mapt/mapt_reader.gd",
	"res://scripts/nav/nav_graph.gd", "res://scripts/nav/nav_object_source.gd",
	"res://scripts/npc/char_tables.gd", "res://scripts/npc/item_table_reader.gd", "res://scripts/npc/mastery_reader.gd",
	"res://scripts/npc/npc_table_reader.gd", "res://scripts/npc/skill_data_reader.gd",
	"res://scripts/nvm/nvm_collision.gd", "res://scripts/nvm/nvm_reader.gd", "res://scripts/objidx/objidx_reader.gd",
	"res://scripts/pk2/blowfish.gd", "res://scripts/pk2/native_assets.gd", "res://scripts/pk2/parse_profile.gd",
	"res://scripts/pk2/pk2_reader.gd", "res://scripts/regioninfo/regioninfo_reader.gd", "res://scripts/text_decode.gd",
	"res://scripts/tile2d/tile_index_reader.gd", "res://scripts/ui/character_appearance.gd",
	"res://scripts/ui/default_wear.gd", "res://scripts/ui/hud/skill_buff_catalog.gd", "res://scripts/ui/ui_text_table.gd",
	"res://scripts/world/ambient_particles.gd", "res://scripts/world/map_animation.gd",
	"res://scripts/world/map_animation_fixture.gd", "res://scripts/world/monster_draw.gd",
	"res://scripts/world/region_grid_state.gd", "res://scripts/world/seasonal_objects.gd", "res://scripts/world/tex_ani.gd",
]

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _initialize() -> void:
	_test_detector()
	_test_worker_files()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)

## The const Arrays (and Arrays-holding Dictionaries) a script declares:
## [[name, kind ("array" | "dict-of-arrays"), line]].
static func declared(text: String) -> Array:
	var out: Array = []
	var re := RegEx.new()
	re.compile("^\\t*const\\s+(\\w+)\\s*(?::\\s*([\\w\\[\\]]+)\\s*)?:?=\\s*(.*)$")
	var lines := text.split("\n")
	for i in lines.size():
		var m := re.search(lines[i])
		if m == null:
			continue
		var typ := m.get_string(2)
		var val := m.get_string(3).strip_edges()
		if typ.begins_with("Packed") or val.begins_with("Packed"):
			continue
		if val.begins_with("[") or val.begins_with("Array"):
			out.append([m.get_string(1), "array", i + 1])
		elif val.begins_with("{"):
			# The literal to its closing brace: an Array inside is read-only too.
			var depth := 0
			var body := ""
			for j in range(i, lines.size()):
				var l: String = lines[j] if j > i else val
				body += l.split("#")[0] + "\n"
				depth += l.count("{") - l.count("}")
				if depth <= 0:
					break
			if body.contains("["):
				out.append([m.get_string(1), "dict-of-arrays", i + 1])
	return out

## The lines of `text` that read `ref` (a constant's name, bare or
## `Class.NAME`) element by element or hand it on: [[line, text]].
static func element_reads(text: String, ref: String) -> Array:
	var r := ref.replace(".", "\\.")
	var pats := [
		"\\bfor\\s+\\w+(\\s*:\\s*\\w+)?\\s+in\\s+\\(?\\s*" + r + "\\b",
		"(?<![\\w.])" + r + "\\s*\\[",
		"(?<![\\w.])" + r + "\\s*\\.\\s*(front|back|get|pick_random|max|min|pop_front|pop_back|map|filter|reduce|any|all|slice)\\s*\\(",
		"(Packed\\w+Array|Array)\\(\\s*" + r + "\\s*\\)",
		"(=|\\breturn|\\belse|\\bif|,|\\()\\s*" + r + "\\b(?!\\s*[.\\[(])",
	]
	var res: Array[RegEx] = []
	for p in pats:
		var e := RegEx.new()
		e.compile(p)
		res.append(e)
	var out: Array = []
	var lines := text.split("\n")
	for i in lines.size():
		var code: String = lines[i].split("#")[0]
		if code.strip_edges().begins_with("const ") or code.strip_edges().begins_with("static var "):
			continue
		for e in res:
			if e.search(code) != null:
				out.append([i + 1, lines[i].strip_edges()])
				break
	return out

func _test_detector() -> void:
	var snippet := "\n".join(PackedStringArray([
		"const NAMES := [\"a\", \"b\"]",
		"const TABLE := {1: [2, 3]}",
		"const PLAIN := {1: 2}",
		"const OK := PackedStringArray([\"x\"])",
		"func f(x):",
		"\tfor n in NAMES:",
		"\t\tpass",
		"\tvar a = NAMES[0]",
		"\tvar b = NAMES.front()",
		"\tvar c := PackedStringArray(NAMES)",
		"\treturn NAMES if x else []",
		"\tvar d = x in NAMES",
		"\tvar e = NAMES.size()",
	]))
	var decl := declared(snippet)
	var names := []
	for d in decl:
		names.append(d[0])
	_check(names == ["NAMES", "TABLE"], "the detector finds the const Array and the Array-holding Dictionary, not a plain one or a Packed array (%s)" % str(names))
	var reads := element_reads(snippet, "NAMES")
	var at := []
	for r in reads:
		at.append(r[0])
	_check(at == [6, 8, 9, 10, 11], "it flags the for, the index, the element method, the Packed copy and the hand-on, not `in` or `.size()` (lines %s)" % str(at))

func _test_worker_files() -> void:
	var all_scripts: Array = []
	_collect("res://scripts", all_scripts)
	var texts := {}
	for p in all_scripts:
		texts[p] = FileAccess.get_file_as_string(p)
	var problems: Array = []
	for wf in WORKER_FILES:
		if not texts.has(wf):
			problems.append("%s: not found" % wf)
			continue
		var text: String = texts[wf]
		var cls := ""
		var cm := RegEx.new()
		cm.compile("(?m)^class_name\\s+(\\w+)")
		var mm := cm.search(text)
		if mm != null:
			cls = mm.get_string(1)
		for d in declared(text):
			if d[1] == "dict-of-arrays":
				problems.append("%s:%d const %s holds Arrays (read-only, shared)" % [wf, d[2], d[0]])
				continue
			for r in element_reads(text, d[0]):
				problems.append("%s:%d reads const %s: %s" % [wf, r[0], d[0], r[1]])
			if cls == "":
				continue
			for p in texts:
				if p == wf:
					continue
				for r in element_reads(texts[p], "%s.%s" % [cls, d[0]]):
					problems.append("%s:%d reads const %s.%s: %s" % [p, r[0], cls, d[0], r[1]])
	for p in problems:
		print("  " + p)
	_check(problems.is_empty(), "no const Array of the %d worker-run scripts is read element by element anywhere (%d found)" % [WORKER_FILES.size(), problems.size()])

static func _collect(dir: String, out: Array) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	for f in d.get_files():
		if f.ends_with(".gd") and not f.ends_with("_test.gd"):
			out.append(dir.path_join(f))
	for sub in d.get_directories():
		_collect(dir.path_join(sub), out)
