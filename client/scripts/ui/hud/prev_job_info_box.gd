extends PartyMatchBox
class_name PrevJobInfoBox

## Round 799: CIFPrevJobInfo, "Previous job information" (GDR_PREV_JOB_INFO,
## registry id 66, resinfo\ifprevjobinfo.txt, 364 x 164). READ in
## sro_client.exe:
## - opened by 0xB0E6's success (FUN_00881740 -> FUN_0079caf0(1, ...)), the
##   reply's pairs re-ordered from the wire's trader, robber, hunter to the
##   window's trader, hunter, thief;
## - per row (CIFPrevJobInfo::FUN_0074d8e0): the level as `%d %s` with
##   UIIT_STT_GRADE, the class title by the player's own race, and below level
##   7 `%d%% (%d)` (percent, exp) over a gauge of exp / need; at 7 or above the
##   literal L"100%%" (0x74db48, passed to SetText as it is) and a full gauge;
## - OK (60) closes.
## The thief row is drawn only while the byte [0xeed578+0x12d] is set
## (0x74dd06..0x74dd18); what sets it is OPEN, so it is drawn here (OURS).

const SIZE := Vector2(364, 164)
const LAYOUT := "resinfo\\ifprevjobinfo.txt"
## The window's rows: control word, kind.
const ROWS := [["MERCHANT", JobNet.KIND_TRADER], ["HUNTER", JobNet.KIND_HUNTER], ["THIEF", JobNet.KIND_THIEF]]

## levels / exps in the wire's order (trader, robber, hunter); europe the own
## race; table LevelDataReader.parse_job_exp.
func build_prev(builder: UiBuilder, levels: Array, exps: Array, europe: bool, table: Dictionary) -> bool:
	name = "PrevJobInfo"
	if not build_shell(builder, SIZE, "UIIT_STT_NPC_CHATTING_JOBINFO_OLD", "Previous job information", LAYOUT):
		return false
	for r in ROWS:
		var word: String = r[0]
		var kind: int = r[1]
		var lv := int(levels[kind - 1]) if levels.size() >= 3 else 0
		var ex := int(exps[kind - 1]) if exps.size() >= 3 else 0
		var cells := cells_for(kind, lv, ex, europe, table, func(k: String) -> String: return text(k, k))
		set_static("GDR_PREV_JOB_INFO_%s_GRADE" % word, String(cells["grade"]))
		set_static("GDR_PREV_JOB_INFO_%s_GRADENAME" % word, String(cells["gradename"]))
		set_static("GDR_PREV_JOB_INFO_%s_EXP" % word, String(cells["exp"]))
		var gauge := node("GDR_PREV_JOB_INFO_%s_EXP_GAUGE" % word) as Range
		if gauge != null:
			gauge.value = float(cells["ratio"]) * gauge.max_value
	var ok := button("GDR_PREV_JOB_INFO_OK_BTN")
	if ok != null:
		ok.pressed.connect(close)
	return true

## One row's texts (FUN_0074d8e0).
static func cells_for(kind: int, level: int, exp: int, europe: bool, table: Dictionary, resolve: Callable) -> Dictionary:
	var grade_word := String(resolve.call("UIIT_STT_GRADE")) if resolve.is_valid() else "Level"
	var key := JobText.class_key(kind, level, europe)
	var out := {"grade": "%d %s" % [level, grade_word], "gradename": String(resolve.call(key)) if resolve.is_valid() else key}
	if level < JobNet.MAX_LEVEL:
		var need := JobText.need_of(table, kind, level)
		out["exp"] = "%d%% (%d)" % [JobText.percent(exp, need), exp]
		out["ratio"] = JobText.ratio(exp, need)
	else:
		out["exp"] = "100%%"
		out["ratio"] = 1.0
	return out
