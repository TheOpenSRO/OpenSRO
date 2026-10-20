extends RefCounted
class_name JobText

## Round 799: the job system's words and numbers as the client builds them
## (READ in sro_client.exe; docs/protocol/jobs.md "The client's job UI"):
##   - a kind's word in the UIIT keys: MERCHANT, THIEF, HUNTER (c:0xddbd68..);
##   - a class title: UIIT_STT_CLASS_%s_%d, or UIIT_STT_CLASS_EU_%s_%d for a
##     European body (the race byte refobj +0x9c: CIFPlayerInfo::vslot_012
##     0x6b92c8.., the 0x30E6 handler 0x884f67);
##   - the job icon ifcommon\com_job_{merchant,thief,hunter}.ddj (0x6b92d9..);
##   - the exp percent: trunc(float(exp) / need x 100), a need of -1 showing
##     100 (0x6b9542..0x6b95ce); the need is leveldata's job column for the
##     level -- cols 6, 7, 8 (the server's FUN_0060dd90 reads them; the
##     client's record offsets +0x1c/+0x20/+0x24 are one field before the
##     server's +0x20/+0x24/+0x28, and its 0x30E6 handler takes +0x1c as the
##     old level's need on a level-up, so INFERRED: the same columns).

const ICONS := {
	JobNet.KIND_TRADER: "interface\\ifcommon\\com_job_merchant.ddj",
	JobNet.KIND_THIEF: "interface\\ifcommon\\com_job_thief.ddj",
	JobNet.KIND_HUNTER: "interface\\ifcommon\\com_job_hunter.ddj",
}

## The class title's key for a kind at a job level (europe: the EU table).
static func class_key(kind: int, level: int, europe: bool) -> String:
	var word := String(JobNet.KEY_WORD.get(kind, ""))
	if word == "":
		return ""
	return "UIIT_STT_CLASS_%s%s_%d" % ["EU_" if europe else "", word, level]

## The exp's percent of the level's need (need < 0 or 0xFFFFFFFF: 100).
static func percent(exp: int, need: int) -> int:
	if need == -1 or need == 0xFFFFFFFF:
		return 100
	if need == 0:
		return 0
	var ratio := float(exp) / float(need)
	return int(ratio * 100.0)

## The gauge's fill, 0..1 (1 when the need is -1).
static func ratio(exp: int, need: int) -> float:
	if need == -1 or need == 0xFFFFFFFF:
		return 1.0
	if need == 0:
		return 0.0
	return clampf(float(exp) / float(need), 0.0, 1.0)

## The need from a parse_job_exp table: {level: [trader, thief, hunter]}.
static func need_of(table: Dictionary, kind: int, level: int) -> int:
	var row: Array = table.get(level, [])
	if kind < 1 or kind > 3 or row.size() < 3:
		return -1
	return int(row[kind - 1])

## Thousands separators (FUN_008c1b40(v, 3, 0), the gold readouts).
static func grouped(value: int) -> String:
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-" + out) if value < 0 else out

## The 0x30E6 handler's line (NetProcessInInterface::FUN_00884dd0, READ):
## {"banner": the level-up line or "", "key": the system line's key, "amount"}.
## A level-up shows UIIT_STT_JOB_LVUP_%s_CLASS with the new class title as a
## banner and UIIT_STT_JOB_EXP_%s_GET with need(old level) - old exp + new
## exp; a lower level UIIT_STT_JOB_EXP_%s_LOST with need(new level) - new exp
## + old exp; the same level GET or LOST by the difference, nothing when equal.
## The handler reads the need from the record's +0x1c on a level-up and +0x20
## on a level-down whatever the kind (INFERRED the trader and thief columns;
## leveldata's three are equal on every row MEASURED, so need_of(kind) here).
static func exp_line(kind: int, old_level: int, old_exp: int, new_level: int, new_exp: int, table: Dictionary) -> Dictionary:
	var word := String(JobNet.KEY_WORD.get(kind, ""))
	var out := {"banner_key": "", "key": "", "amount": 0}
	if word == "":
		return out
	if new_level > old_level:
		out["banner_key"] = "UIIT_STT_JOB_LVUP_%s_CLASS" % word
		out["key"] = "UIIT_STT_JOB_EXP_%s_GET" % word
		out["amount"] = need_of(table, kind, old_level) - old_exp + new_exp
	elif new_level < old_level:
		out["key"] = "UIIT_STT_JOB_EXP_%s_LOST" % word
		out["amount"] = need_of(table, kind, new_level) - new_exp + old_exp
	elif new_exp > old_exp:
		out["key"] = "UIIT_STT_JOB_EXP_%s_GET" % word
		out["amount"] = new_exp - old_exp
	elif new_exp < old_exp:
		out["key"] = "UIIT_STT_JOB_EXP_%s_LOST" % word
		out["amount"] = old_exp - new_exp
	return out
