extends SceneTree

## Round 855: the pet strip (CIFPetMiniInfo, control 100 of
## resinfo\ifplayerminiinfo.txt) draws in control 100's place among the
## player block's children, not over the whole block. A pure check of the
## Godot draw order against the original's (READ, hud_pet_mini_info.gd
## attach_to): a window draws its own art, then its children in list order,
## and a resinfo section's controls join that list in reverse file order, so
## the file's first control is on top.
##
## The fixture carries the 53 controls of ifplayerminiinfo.txt's "Create"
## section in the archive's file order with their names, classes, IDs and
## rects (layout metadata, as the other HUD tests' fixtures; no art):
##   godot4 --headless --path client --script res://scripts/ui/hud/hud_pet_strip_order_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

## ifplayerminiinfo.txt's controls in file order (MEASURED on the render box,
## round 855: Media.pk2 resinfo\ifplayerminiinfo.txt).
const PMI := [
	["GDR_PMI_RACE_MARK", "CIFStatic", 15, "53,41,24,24"],
	["GDR_PMI_PARTY_LEADER", "CIFStatic", 14, "53,12,0,0"],
	["GDR_PMI_BTN_STATUP", "CIFButton", 34, "150,3,16,16"],
	["GDR_PMI_BTN_CINFO", "CIFButton", 20, "41,56,20,20"],
	["GDR_PMI_HWAN_EFF_FACE", "CIFStatic", 45, "15,7,48,48"],
	["GDR_PMI_DECO_HWAN_SLOT4", "CIFDecoratedStatic", 44, "26,41,16,28"],
	["GDR_PMI_DECO_HWAN_SLOT3", "CIFDecoratedStatic", 43, "12,35,16,28"],
	["GDR_PMI_DECO_HWAN_SLOT2", "CIFDecoratedStatic", 42, "2,24,16,28"],
	["GDR_PMI_DECO_HWAN_SLOT1", "CIFDecoratedStatic", 41, "-1,9,16,28"],
	["GDR_PMI_DECO_HWAN_SLOT0", "CIFDecoratedStatic", 40, "2,-6,16,28"],
	["GDR_PMI_TXT_PARRYDAT", "CIFStatic", 33, "132,225,65,12"],
	["GDR_PMI_TXT_HITDAT", "CIFStatic", 32, "132,205,65,12"],
	["GDR_PMI_TXT_MAGBALDAT", "CIFStatic", 55, "132,185,65,12"],
	["GDR_PMI_TXT_PHYBALDAT", "CIFStatic", 54, "132,165,65,12"],
	["GDR_PMI_TXT_MAGDEFDAT", "CIFStatic", 31, "132,145,65,12"],
	["GDR_PMI_TXT_MAGATTDAT", "CIFStatic", 30, "132,125,65,12"],
	["GDR_PMI_TXT_PHYDEFDAT", "CIFStatic", 29, "132,105,65,12"],
	["GDR_PMI_TXT_PHYATTDAT", "CIFStatic", 28, "132,85,65,12"],
	["GDR_PMI_TXT_INTDAT", "CIFStatic", 38, "170,65,29,12"],
	["GDR_PMI_TXT_STRDAT", "CIFStatic", 37, "100,65,29,12"],
	["GDR_PMI_TXT_PARRY", "CIFStatic", 27, "82,225,47,12"],
	["GDR_PMI_TXT_HIT", "CIFStatic", 26, "82,205,47,12"],
	["GDR_PMI_TXT_MAGBAL", "CIFStatic", 53, "82,185,47,12"],
	["GDR_PMI_TXT_PHYBAL", "CIFStatic", 52, "82,165,47,12"],
	["GDR_PMI_TXT_MAGDEF", "CIFStatic", 25, "82,145,47,12"],
	["GDR_PMI_TXT_MAGATT", "CIFStatic", 24, "82,125,47,12"],
	["GDR_PMI_TXT_PHYDEF", "CIFStatic", 23, "82,105,47,12"],
	["GDR_PMI_TXT_PHYATT", "CIFStatic", 22, "82,85,47,12"],
	["GDR_PMI_TXT_INT", "CIFStatic", 36, "145,65,23,12"],
	["GDR_PMI_TXT_STR", "CIFStatic", 35, "82,65,15,12"],
	["GDR_PMI_STA_CINFOBG", "CIFStatic", 21, "72,57,135,189"],
	["GDR_PMI_FORFEIT", "CIFStatic", 51, "11,101,20,20"],
	["GDR_PMI_BATTLE_GRADE", "CIFStatic", 60, "57,103,20,20"],
	["GDR_PMI_FORTRESS_INFO", "CIFStatic", 70, "34,103,20,20"],
	["GDR_PMI_PK", "CIFStatic", 50, "11,103,20,20"],
	["GDR_PMI_BTN_JAHWAN", "CIFButton", 13, "16,-5,20,20"],
	["GDR_PMI_PICTURE", "CIFStaticWithPictureClip", 12, "15,7,48,48"],
	["GDR_PMI_CIRCLE4", "CIFStatic", 11, "31,60,8,8"],
	["GDR_PMI_CIRCLE3", "CIFStatic", 10, "17,54,8,8"],
	["GDR_PMI_CIRCLE2", "CIFStatic", 9, "7,43,8,8"],
	["GDR_PMI_CIRCLE1", "CIFStatic", 8, "4,28,8,8"],
	["GDR_PMI_CIRCLE0", "CIFStatic", 7, "7,13,8,8"],
	["GDR_PMI_TXT_MP", "CIFStatic", 6, "79,42,124,12"],
	["GDR_PMI_TXT_HP", "CIFStatic", 5, "79,26,124,12"],
	["GDR_PMI_TXT_LEVEL", "CIFStatic", 4, "168,7,37,15"],
	["GDR_PMI_TXT_ID", "CIFStatic", 3, "71,4,93,15"],
	["GDR_PMI_GAUGE_MP", "CIFGauge", 1, "79,41,124,12"],
	["GDR_PMI_GAUGE_HP", "CIFGauge", 0, "79,25,124,12"],
	["GDR_PMI_EFFECT_MP", "CIFStatic", 78, "75,41,128,32"],
	["GDR_PMI_EFFECT_HP", "CIFStatic", 77, "75,25,128,32"],
	["GDR_PMI_HWAN_EFF_GLOW", "CIFStatic", 46, "-4,-3,220,80"],
	["GDR_PMI_PET_MINI_INFO", "CIFPetMiniInfo", 100, "53,55,154,40"],
	["GDR_PMI_SELECT", "CIFStatic", 200, "-4,-3,220,80"],
]

## ifpetminiinfo.txt's controls in file order (round 795's fixture).
const PET := [
	["GDR_PET_MINI_BUFF", "CIFBuffViewer", 30, "32,39,0,0"],
	["GDR_PET_MINI_PICTURE", "CIFStaticWithPictureClip", 20, "4,4,32,32"],
	["GDR_PET_MINI_TXT_LEVEL", "CIFStatic", 16, "118,7,34,13"],
	["GDR_PET_MINI_TXT_NAME", "CIFStatic", 15, "44,7,73,13"],
	["GDR_PET_MINI_GAUGE_HGP", "CIFGauge", 11, "41,29,112,8"],
	["GDR_PET_MINI_GAUGE_HP", "CIFGauge", 10, "41,23,112,8"],
	["GDR_PET_MINI_EFFECT_HP", "CIFStatic", 100, "42,24,107,32"],
]

func _c(n: String, type: String, id: int, rect: String, extra: String = "") -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tText=STRING,\"\"\n%s\t}\n" % [
		n, type, id, rect, extra]

func _file(rows: Array) -> String:
	var body := ""
	for r in rows:
		body += _c(r[0], r[1], r[2], r[3])
	return "Interface Text\n\nSection = Create,\"0,0,0,0\",\"0\"\n{\n" + body + "}\n"

func _builder() -> UiBuilder:
	var builder := UiBuilder.new(null, null)
	var cache: Dictionary = builder.get("_layout_cache")
	cache["resinfo\\ifplayerminiinfo.txt"] = UiLayoutParser.parse(_file(PMI))
	cache["resinfo\\ifpetminiinfo.txt"] = UiLayoutParser.parse(_file(PET))
	return builder

## Every CanvasItem under `node` in Godot's draw order (a pre-order walk in
## child order -- what a canvas draws when no z_index or top_level reorders
## it, which _no_reordering checks).
func _draw_order(node: Node, out: Array) -> Array:
	for child in node.get_children():
		if child is CanvasItem:
			out.append(child)
			_draw_order(child, out)
	return out

func _no_reordering(items: Array) -> bool:
	for it in items:
		var ci := it as CanvasItem
		if ci.z_index != 0 or ci.top_level or not ci.z_as_relative:
			print("  reordered: %s z %d top %s" % [ci.get_path(), ci.z_index, str(ci.top_level)])
			return false
	return true

func _initialize() -> void:
	var builder := _builder()
	var pmi := HudPlayerInfo.new(builder)
	pmi.name = "HudPlayerInfo"
	root.add_child(pmi)
	pmi.position = Vector2(4, 7)
	pmi.setup()
	var strip := HudPetMiniInfo.new(builder)
	_check(strip.build(), "the strip builds from its fixture")
	# Where HudCos keeps it before a block is given (PLAYER_BLOCK_ORIGIN + RECT).
	var holder := Control.new()
	root.add_child(holder)
	holder.add_child(strip)
	strip.position = Vector2(57, 62)
	strip.attach_to(pmi)
	strip.visible = true

	var items := _draw_order(pmi, [])
	_check(_no_reordering(items), "nothing in the block sets a z_index or top_level: tree order is draw order")

	# The block's own controls, as drawn: the file reversed (back to front).
	var drawn_pmi: Array = []
	for it in items:
		var nm := String((it as Node).name)
		if nm.begins_with("GDR_PMI_") and (it as Node).get_parent().get_parent() == pmi:
			drawn_pmi.append(nm)
	var file_order: Array = []
	for r in PMI:
		file_order.append(r[0])
	var reversed := file_order.duplicate()
	reversed.reverse()
	_check(drawn_pmi == reversed, "the block's 53 controls draw in reverse file order (the file's first, the race mark, on top)")

	var idx := {}
	for i in items.size():
		idx[String((items[i] as Node).name)] = i
	_check(strip.get_parent() == pmi.find_child("GDR_PMI_PET_MINI_INFO", true, false).get_parent(),
		"the strip is a sibling of the layout's control 100")
	var slot := pmi.find_child("GDR_PMI_PET_MINI_INFO", true, false) as Control
	_check(strip.get_index() == slot.get_index() + 1, "the strip sits right above control 100's placeholder")
	_check(not slot.visible, "the placeholder stays hidden")
	var si: int = idx["PetMiniInfo"]
	_check(si > idx["GDR_PMI_SELECT"], "the selection glow (id 200, the file's last) draws under the strip")
	var over: Array = []
	var under: Array = []
	for nm in file_order:
		if nm == "GDR_PMI_PET_MINI_INFO" or nm == "GDR_PMI_SELECT":
			continue
		if idx[nm] > si:
			over.append(nm)
		else:
			under.append(nm)
	_check(under.is_empty() and over.size() == 51, "every other control of the block (51) draws over the strip; under: %s" % str(under))
	for nm in ["GDR_PMI_PICTURE", "GDR_PMI_RACE_MARK", "GDR_PMI_BTN_CINFO", "GDR_PMI_BTN_JAHWAN",
			"GDR_PMI_CIRCLE3", "GDR_PMI_CIRCLE4", "GDR_PMI_GAUGE_HP", "GDR_PMI_GAUGE_MP",
			"GDR_PMI_TXT_HP", "GDR_PMI_TXT_MP", "GDR_PMI_HWAN_EFF_GLOW", "GDR_PMI_STA_CINFOBG"]:
		_check(idx[nm] > si, "%s draws over the strip" % nm)
	# The portrait's picture is drawn inside its control (its own child).
	var view := pmi.portrait_view()
	_check(view != null and idx.has(String(view.name)) and idx[String(view.name)] > si,
		"the portrait picture (inside GDR_PMI_PICTURE) draws over the strip")
	var frame := pmi.get_node_or_null("Frame")
	_check(frame == null or idx["Frame"] < si, "the block's own art (the window's own draw, before its children) is under the strip")
	# Every node of the strip draws between the glow and the next control up.
	var last_strip := si
	for i in range(si, items.size()):
		if strip.is_ancestor_of(items[i] as Node):
			last_strip = i
	_check(last_strip < idx["GDR_PMI_HWAN_EFF_GLOW"], "the strip's own children all draw before the next control of the block")

	# Its own children: its art, then ifpetminiinfo.txt reversed (the buff row on top).
	var pet_drawn: Array = []
	for it in _draw_order(strip, []):
		var nm := String((it as Node).name)
		if nm.begins_with("GDR_PET_MINI_"):
			pet_drawn.append(nm)
	var pet_rev: Array = []
	for r in PET:
		pet_rev.push_front(r[0])
	_check(pet_drawn == pet_rev, "the strip's children draw in reverse file order: %s" % str(pet_drawn))
	_check(strip.get_child(0).name == "Frame", "the strip's own art is under its children")

	# The place: 53,55 of the block (control 100's Rect).
	_check(strip.position == Vector2(53, 55), "the strip is at control 100's rect, 53,55")
	_check(strip.global_position - pmi.global_position == Vector2(53, 55), "53,55 from the block's origin on screen")

	# Attached again (HudCos re-attach): one strip, same place.
	var before := strip.get_index()
	strip.attach_to(pmi)
	var n := 0
	for it in _draw_order(pmi, []):
		if it == strip:
			n += 1
	_check(n == 1 and strip.get_index() == before and strip.position == Vector2(53, 55), "a second attach keeps one strip in the same place")

	# No layout: the strip hangs on the block at its rect (nothing to cover).
	var bare := Control.new()
	root.add_child(bare)
	var lone := HudPetMiniInfo.new(null)
	lone.attach_to(bare)
	_check(lone.get_parent() == bare and lone.position == Vector2(53, 55), "without a layout it hangs on the block at 53,55")

	print("ALL PASS" if _failures == 0 else "%d FAILED" % _failures)
	quit(1 if _failures > 0 else 0)
