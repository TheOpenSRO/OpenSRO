extends RefCounted
class_name CosModelFallback

## Round 861: a COS whose model is not in the archive is drawn from its trade
## twin (OURS), never as a white capsule.
##
## The user: "the camel mounts are still white blobs". The ride camels and the
## ride donkey (COS_C_CAMEL1..3, COS_C_DONKEY; characterdata column 52
## `cos\c_camel1.bsr`..`c_camel3.bsr`, `cos\c_donkey.bsr`) name models this
## version's Data.pk2 does not hold (MEASURED: only `res\cos\t_camel1..3.bsr`
## and `t_donkey.bsr`, the trade transports', and their `_2011` variants; the
## rows' icons `icon\cos\cos_c_camel1..3.ddj` / `cos_c_donkey.ddj` are missing
## from Media.pk2 too). They are the only in-service COS rows whose model is
## missing (MEASURED census, round 861).
##
## The original (READ, c: sro_client.exe): a COS takes its row's model
## (+0x124, or its Org row's when empty; CICCos::vslot_025 c:0x9c60b0) and
## loads it through GlobalDataManager::FUN_009c4ec0, which draws
## `res\mob\china\mangnyang.bsr` only when no model came back. A named `.bsr`
## goes to the resource manager (Map::FUN_009fe760's `r` case ->
## CResourceMgr::vslot_004 c:0xbedc40 -> ResourceMgr::FUN_00bedba0), whose
## miss -- the file does not open in FUN_00bed8d0 -- asserts "%s Loading
## Failed." (ResourceMgr.h line 0x7d) for every type but 5. This build's
## assert (Assert_FileLineExpression c:0x49e490; flags 0x501 without a
## debugger, set at c:0x8328c0) calls its logger c:0x830da0, which writes to
## address 0 (the crash handler); were it to return, bits 2 and 4 clear take
## ExitProcess(0). No step tries another name (no `_2011` variant, no other
## directory, no trade model). OPEN: the very first load of a name runs
## through a callback FUN_009ef120 reads at run time ([0x1103d87+0x1c]),
## whose setter was not found; Map::FUN_009fe760 is the builder for every
## later instance. The original never meets these rows in play: no shop,
## package or drop of this version gives the ride camel or donkey scrolls
## (MEASURED: refshopgoods, refpackageitem, refscrapofpackageitem and the
## server's drop tables name only the three ride horses' packages).
##
## OURS, then: a missing `c_` model is drawn from the same name's `t_` twin
## (`cos\c_camel1.bsr` -> `cos\t_camel1.bsr`, `cos\c_donkey.bsr` ->
## `cos\t_donkey.bsr`), the trade camel and donkey, which carry a `saddle`
## bone (a rider sits on them as on a trade transport, round 809); failing that the
## original's own stand-in for a body without a model, the Mangyang; failing
## that nothing is drawn, and the world says so once. A model that is in the
## archive is always its own. The icon takes the same twin
## (`icon\cos\cos_c_camel1.ddj` -> `icon\cos\cos_t_camel1.ddj`).

## The original's stand-in for a body with no model (READ, FUN_009c4ec0's
## string at c:0xde1f90, "res\mob\china\mangnyang.bsr"), in the form the
## body loaders take (they prefix `res\`).
const MANGNYANG := "mob\\china\\mangnyang.bsr"

const RULE_OWN := "own"
const RULE_TWIN := "twin"
const RULE_MANGNYANG := "mangnyang"
const RULE_NONE := "none"

## The trade twin of a ride's file: the same path with the file name's
## leading `c_` (a model) or `cos_c_` (an icon) made `t_` / `cos_t_`; "" when
## the name has no such prefix. Case is kept as written; the archives' lookups
## ignore it.
static func trade_twin(path: String) -> String:
	var cut := maxi(path.rfind("\\"), path.rfind("/")) + 1
	var dir := path.substr(0, cut)
	var file := path.substr(cut)
	var low := file.to_lower()
	if low.begins_with("cos_c_"):
		return dir + file.substr(0, 4) + ("T" if file[4] == "C" else "t") + file.substr(5)
	if low.begins_with("c_"):
		return dir + ("T" if file[0] == "C" else "t") + file.substr(1)
	return ""

## The model to draw for a row naming `model`: {"path", "rule"}. `has` answers
## whether the archive holds a path (the body loaders' form, `res\` implied).
## An empty `model` is left to the caller (the Org rule has run already;
## CosTable.parse).
static func resolve(model: String, has: Callable) -> Dictionary:
	if model == "" or has.call(model):
		return {"path": model, "rule": RULE_OWN}
	var twin := trade_twin(model)
	if twin != "" and has.call(twin):
		return {"path": twin, "rule": RULE_TWIN}
	if has.call(MANGNYANG):
		return {"path": MANGNYANG, "rule": RULE_MANGNYANG}
	return {"path": "", "rule": RULE_NONE}

## The icon to show for a row naming `icon`: its own when `has` finds it, else
## its trade twin when that is found, else `icon` unchanged.
static func icon_path(icon: String, has: Callable) -> String:
	if icon == "" or has.call(icon):
		return icon
	var twin := trade_twin(icon)
	if twin != "" and has.call(twin):
		return twin
	return icon

## One line for the world's log: what a row is drawn from, and why.
static func describe(code: String, model: String, picked: Dictionary) -> String:
	match String(picked.get("rule", RULE_OWN)):
		RULE_TWIN:
			return "COS %s: %s is not in the archive -- drawn from its trade twin %s (OURS, round 861)" % [code, model, picked.path]
		RULE_MANGNYANG:
			return "COS %s: %s is not in the archive and has no trade twin -- drawn as the original's stand-in %s (OURS, round 861)" % [code, model, picked.path]
		RULE_NONE:
			return "COS %s: %s is not in the archive, nor a trade twin, nor %s -- nothing is drawn (round 861)" % [code, model, MANGNYANG]
	return ""
