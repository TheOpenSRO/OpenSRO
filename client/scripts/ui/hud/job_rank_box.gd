extends PartyMatchBox
class_name JobRankBox

## Round 799: the weekly job rankings -- CIFJobRank (GDR_JOB_RANK, registry id
## 64, resinfo\ifjobrank.txt, 388 x 369) and CIFJobContributionRank
## (GDR_JOB_CONTRIBUTION_RANK, id 65, ifjobcontributionrank.txt, 388 x 500),
## one class here by `contribution`. READ in sro_client.exe
## (docs/protocol/jobs.md "The client's job UI"):
## - activity: caption by kind UIIT_STT_JOBGUILD_{TRADER,THIEF,HUNTER}_MENU_JOBRANK
##   (0x74d2e0); ten CIFJobRankSlot rows (ifjobrankslot.txt), a row's
##   rank `%d`, alias, level `%d`, the exp as `%d%%` of the level's need (100
##   when the need is -1) and the class title by the row's race byte
##   (0x74cf90 -> 0x74d590); pages of ten on the spin (0x74d36x);
## - contribution: kind 1 captions UIIT_STT_JOBGUILD_TRADER_MENU_DONATIONRANK,
##   title UIIT_STT_JOBGUILD_CONTRIBUTERANK, header and label
##   UIIT_STT_DONATION, the PML UIIT_STT_JOBGUILD_MYCONTRIBUTE; kinds 2 and 3
##   UIIT_STT_JOBGUILD_HUNTER_MENU_CONTRIBUTERANK, _CONTRIBUTERANK2,
##   UIIT_STT_CONTRIBUTE, _MYCONTRIBUTE2 (0x74c58b..); the "my" block (ids
##   10..16: the PML with the alias, the alias, the level `%d`, the
##   contribution grouped) only for a player of the window's kind with an
##   alias and job exp, else ids 10..16 hidden and NOEXIST (60) shown
##   (0x74c100); a row's rank, alias, level and amount grouped (0x74c8d0).
## Data come from 0xB0E4 and are cached per kind and type by the caller.

const ROWS := 10

var contribution := false
var kind := 0
var _rows: Array = []
var _slots: Array[Control] = []
## {level: [trader, thief, hunter]} (LevelDataReader.parse_job_exp).
var job_table: Dictionary = {}

func _prefix() -> String:
	return "GDR_JOB_CONTRIBUTION_RANK_" if contribution else "GDR_JOB_RANK_"

func build_rank(builder: UiBuilder, is_contribution: bool, job_kind: int, rows: Array, table: Dictionary,
		me: Dictionary) -> bool:
	contribution = is_contribution
	kind = job_kind
	_rows = rows
	job_table = table
	name = "JobContributionRank" if contribution else "JobRank"
	var cap := ""
	var cap_fb := ""
	if contribution:
		cap = "UIIT_STT_JOBGUILD_TRADER_MENU_DONATIONRANK" if kind == JobNet.KIND_TRADER else "UIIT_STT_JOBGUILD_HUNTER_MENU_CONTRIBUTERANK"
		cap_fb = "Ranking - weekly donation" if kind == JobNet.KIND_TRADER else "Ranking - weekly contribution"
	else:
		var word := {1: "TRADER", 2: "THIEF", 3: "HUNTER"}.get(kind, "TRADER") as String
		cap = "UIIT_STT_JOBGUILD_%s_MENU_JOBRANK" % word
		cap_fb = "Last week's job activity ranking"
	var size_v := Vector2(388, 500) if contribution else Vector2(388, 369)
	var layout_path := "resinfo\\ifjobcontributionrank.txt" if contribution else "resinfo\\ifjobrank.txt"
	if not build_shell(builder, size_v, cap, cap_fb, layout_path):
		return false
	if contribution:
		var trader := kind == JobNet.KIND_TRADER
		set_static("GDR_JOB_CONTRIBUTION_RANK_STA_TITLE", text("UIIT_STT_JOBGUILD_CONTRIBUTERANK" if trader else "UIIT_STT_JOBGUILD_CONTRIBUTERANK2", ""))
		var amount_key := "UIIT_STT_DONATION" if trader else "UIIT_STT_CONTRIBUTE"
		set_static("GDR_JOB_CONTRIBUTION_RANK_SUBJ_STA_CONTRIBUTION", text(amount_key, ""))
		set_static("GDR_JOB_CONTRIBUTION_RANK_INFO_AMOUNT_STA", text(amount_key, ""))
		_fill_me(trader, me)
	_build_slots(builder, "resinfo\\ifjobcontributionrankslot.txt" if contribution else "resinfo\\ifjobrankslot.txt")
	var spin := node(_prefix() + "SPIN_CTRL")
	if spin != null:
		var pages := maxi(1, int(ceil(float(_rows.size()) / float(ROWS))))
		UiBuilder.set_spin_range(spin, 0, pages - 1)
		spin.connect("spin_changed", func(v: int) -> void: show_page(v))
	show_page(0)
	return true

## The "my" block (0x74c100): me = {kind, alias, level, exp, contribution}.
func _fill_me(trader: bool, me: Dictionary) -> void:
	var mine := int(me.get("kind", 0)) == kind and String(me.get("alias", "")) != "" and int(me.get("exp", 0)) != 0
	for id in ["INFO_PML", "INFO_ALIAS_STA", "INFO_GRADE_STA", "INFO_AMOUNT_STA", "INFO_ALIAS", "INFO_GRADE", "INFO_AMOUNT"]:
		var n := node("GDR_JOB_CONTRIBUTION_RANK_" + id)
		if n != null:
			n.visible = mine
	var none := node("GDR_JOB_CONTRIBUTION_RANK_INFO_NOEXIST")
	if none != null:
		none.visible = not mine
	if not mine:
		return
	var alias := String(me["alias"])
	var pml := text("UIIT_STT_JOBGUILD_MYCONTRIBUTE" if trader else "UIIT_STT_JOBGUILD_MYCONTRIBUTE2", "[%s]")
	set_static("GDR_JOB_CONTRIBUTION_RANK_INFO_PML", strip_sml(pml).replace("%s", alias))
	set_static("GDR_JOB_CONTRIBUTION_RANK_INFO_ALIAS", alias)
	set_static("GDR_JOB_CONTRIBUTION_RANK_INFO_GRADE", "%d" % int(me.get("level", 0)))
	set_static("GDR_JOB_CONTRIBUTION_RANK_INFO_AMOUNT", "%d" % int(me.get("contribution", 0)))

func _build_slots(builder: UiBuilder, slot_layout: String) -> void:
	_slots.clear()
	var layout: UiLayoutParser.LayoutDef = builder.load_layout(slot_layout)
	for i in ROWS:
		var slot := node(_prefix() + "STA_SLOT_%02d" % (i + 1))
		_slots.append(slot)
		if slot == null or layout == null:
			continue
		var built := builder.build_section(layout, "Create")
		if built != null:
			built.name = "RankSlot"
			slot.add_child(built)
			UiBuilder.settle_authored_rects(built)

func show_page(page: int) -> void:
	for i in ROWS:
		var slot := _slots[i] if i < _slots.size() else null
		if slot == null:
			continue
		var holder := slot.get_node_or_null("RankSlot")
		if holder == null:
			continue
		var idx := page * ROWS + i
		var row: Dictionary = _rows[idx] if idx < _rows.size() else {}
		var cells := row_cells(row, contribution, kind, job_table, func(k: String) -> String: return text(k, k))
		for cell in cells:
			var n := holder.get_node_or_null(String(cell))
			if n != null and _builder != null:
				_builder.set_static_text(n, String(cells[cell]))

## A row's cells by control name ("" everywhere for an empty row, 0x74d440).
## `class_key_text` resolves the class title (the caller's text table).
static func row_cells(row: Dictionary, is_contribution: bool, job_kind: int, table: Dictionary,
		resolve: Callable = Callable()) -> Dictionary:
	var p := "GDR_JOB_CONTRIBUTION_RANK_" if is_contribution else "GDR_JOB_RANK_"
	var out := {p + "RANK": "", p + "ALIAS": "", p + "GRADE": ""}
	if is_contribution:
		out[p + "AMOUNT"] = ""
	else:
		out[p + "EXP"] = ""
		out[p + "GRADENAME"] = ""
	if row.is_empty():
		return out
	var level := int(row.get("level", 0))
	out[p + "RANK"] = "%d" % int(row.get("rank", 0))
	out[p + "ALIAS"] = String(row.get("alias", ""))
	out[p + "GRADE"] = "%d" % level
	if is_contribution:
		out[p + "AMOUNT"] = JobText.grouped(int(row.get("amount", 0)))
	else:
		out[p + "EXP"] = "%d%%" % JobText.percent(int(row.get("exp", 0)), JobText.need_of(table, job_kind, level))
		var key := JobText.class_key(job_kind, level, int(row.get("country", 0)) == 1)
		out[p + "GRADENAME"] = String(resolve.call(key)) if resolve.is_valid() else key
	return out

## A PML string's text without its tags (the PML static draws the markup; a
## plain static shows the words).
static func strip_sml(s: String) -> String:
	var re := RegEx.new()
	re.compile("<[^>]*>")
	return re.sub(s, "", true)
