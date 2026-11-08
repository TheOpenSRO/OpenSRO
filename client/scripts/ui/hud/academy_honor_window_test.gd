extends SceneTree

## Round 865 stage 3: the honor ranking window (AcademyHonorWindow). The Guild
## column's head is a CIFBarWnd on com_bar02_ with Text UIIT_CTL_WK_GUILD; the
## builder draws such a bar as a 3-slice with no text, and the head stood empty
## where the original shows "Guild" (MEASURED). The layouts are synthetic but
## carry the authored names, types, IDs and rects of resinfo\
## ifapprenticeshiphonorranking.txt / ifapprenticeshiphonorslot.txt (MEASURED
## from the archive; no textures, no archive text: never real game data).
##
##   godot4 --headless --path client --script res://scripts/ui/hud/academy_honor_window_test.gd

var _failures := 0

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("ok  " + msg)
	else:
		print("FAIL " + msg)
		_failures += 1

func _c(control_name: String, type: String, rect: String, id: int, text: String = "", ddj: String = "", halign: int = 0) -> String:
	return "\t%s:%s\n\t{\n\t\tDDJ=STRING,\"%s\"\n\t\tFontIndex=INTEGER,\"0\"\n\t\tHAlign=INTEGER,\"%d\"\n\t\tID=INTEGER,\"%d\"\n\t\tRect=RECT,\"%s\"\n\t\tStyle=INTEGER,\"0\"\n\t\tText=STRING,\"%s\"\n\t}\n" % [
		control_name, type, ddj, halign, id, rect, text]

func _sec(section: String, body: String) -> String:
	return "Section = %s,\"0,0,0,0\",\"0\"\n{\n%s}\n" % [section, body]

func _ranking() -> String:
	var create := _c("GDR_APPRENTICESHIP_SPIN_CTRL", "CIFSpinButtonCtrl", "231,312,50,16", 4)
	create += _c("GDR_APPRENTICESHIP_CONFIRM_BTN", "CIFButton", "212,336,0,0", 3, "UIIS_CTL_CONFIRM")
	var heads := ""
	heads += _c("GDR_APPRENTICESHIP_HONOR_RANKING_GUILD", "CIFBarWnd", "373,52,120,24", 25, "UIIT_CTL_WK_GUILD",
		"interface\\ifcommon\\com_bar02_", 1)
	heads += _c("GDR_APPRENTICESHIP_HONOR_RANKING_GRADUATION", "CIFButton", "312,52,61,24", 24, "UIIT_CTL_TC_HONOR_GRADUATION")
	var slots := ""
	for i in 10:
		slots += _c("GDR_APPRENTICESHIP_SLOTLIST_SLOT_%02d" % (i + 1), "CIFApprenticeShipHonorSlot", "18,%d,475,24" % (74 + 23 * i), 30 + i)
	return "Interface Text\n\n" + _sec("Create", create) + _sec("RankingListBtn", heads) + _sec("RankingSlotList", slots)

func _slot() -> String:
	var b := _c("GDR_APPRENTICESHIPHONOR_SLOT_RANK", "CIFStatic", "0,0,40,24", 1)
	b += _c("GDR_APPRENTICESHIPHONOR_SLOT_GUILD", "CIFStatic", "355,0,120,24", 6)
	return "Interface Text\n\n" + _sec("Create", b)

func _initialize() -> void:
	var rows := PackedStringArray()
	for k in ["UIIT_CTL_WK_GUILD", "UIIT_CTL_TC_HONOR_GRADUATION", "UIIS_CTL_CONFIRM", "UIIT_STT_NO_GUILD"]:
		rows.append("1\t%s\t\t\t\t\t\t\t<%s>" % [k, k])
	var builder := UiBuilder.new(null, UiTextTable.parse(("\n".join(rows)).to_utf16_buffer()))
	var cache: Dictionary = builder.get("_layout_cache")
	cache[AcademyHonorWindow.LAYOUT] = UiLayoutParser.parse(_ranking())
	cache[AcademyHonorWindow.SLOT_LAYOUT] = UiLayoutParser.parse(_slot())
	var w := HudWindow.new()
	root.add_child(w)
	var built := w.build(builder, AcademyHonorWindow.LAYOUT, "Honor Rank", PackedStringArray(AcademyHonorWindow.SECTIONS))
	_check(built, "the ranking window builds from its layout")
	var h := AcademyHonorWindow.compose(w, builder)
	var head := w.node(AcademyHonorWindow.GUILD_HEAD) as Control
	var lbl := head.get_node_or_null("HeaderText") as Label if head != null else null
	_check(lbl != null and lbl.text == "<UIIT_CTL_WK_GUILD>", "the Guild head carries its authored text (got %s)" % (lbl.text if lbl != null else "none"))
	AcademyHonorWindow.compose(w, builder)
	_check(head != null and head.get_children().filter(func(n: Node) -> bool: return n.name == "HeaderText").size() == 1,
		"composing twice adds one caption")
	_check(h != null, "compose gives the controller")
	w.queue_free()
	if _failures == 0:
		print("ALL PASS")
		quit(0)
	else:
		print("%d FAILURES" % _failures)
		quit(1)
