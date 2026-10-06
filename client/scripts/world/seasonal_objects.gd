extends RefCounted
class_name SeasonalObjects

## The seasonal event decorations this client leaves out of the world
## (round 583): Christmas, Halloween, the China open-beta (OBT) event set
## and the summer festival set, each hidden by default and each
## re-enableable on its own.
##
## THE CHOICE IS OURS, NOT THE RETAIL CLIENT'S. No switch for them was
## found in the client's `.o2` loader (FUN_00a361b0, MapCallBack.cpp). It
## builds every second- and third-list record whose byte 27 bit 0 is clear,
## and no seasonal record has that bit set: bytes 26-27 are zero in all 878
## seasonal entries of the 4,559 region `.o2` files (Map.pk2's 15 root
## `.o2` files, 50.o2 to 64.o2, were not scanned). sro_client.exe has no
## x_mas / halloween / obt_event / summer_event string (ASCII or UTF-16).
## Its only seasonal strings are five UTF-16 UI message ids,
## UIIT_MSG_XMAS_EVENT_* (CHANGE, COMPENSATION, ERROR_INVENTORY,
## ERROR_SOCKS, SO-OK). The user asked on 2026-09-26 for none of the four
## sets during early testing.
##
## WHAT MAKES A PIECE SEASONAL is the folder its model lives in, read from
## the lowercased path of Map.pk2's own `object.ifo` -- never an id range:
## id 3297, between two Halloween ids, is `res\npc\npc\arabia_fouad.bsr`.
## Which folder is which event is grounded by Map.pk2's `layerobjdef.txt`
## (layer 1 the festival, 4-5 Halloween, 6-7 Christmas, 8-9 China OBT) and
## its `layerobjectlist.ifo`. Each list row was joined by position (same
## region, every axis within 0.05) to the region's `.o` and `.o2` records.
## Every unambiguous match is a piece of its layer's own folder: layer 7
## only `\x_mas\` (233 rows), 4-5 only `\halloween\` (12 + 202), 8-9 only
## `obt_event` (15 + 304) and 1 only `summer_event` (91). `alex_burner`
## (`res\bldg\north africa\alexandria\`) matches no row by position, is in
## none of these folders, and stays. Neither layer file is named in
## sro_client.exe's strings or in its decompilation. What
## layerobjdef.txt's first column means (1 for BASIC and the guard-post
## layers, 0 for every event layer) is not established.
##
## Map.pk2's object.ifo: christmas 3254-3266 (13, including the
## `compound\struct\etc\x_mas\` compound), halloween 3287-3296 and 3298
## (11), obt 3268-3283, 3285, 3286 (18), summer 2095-2109 (15).

static var SETS := ["christmas", "halloween", "obt", "summer"]

## Each set's rule: a substring of the lowercased object.ifo path.
const RULES := {
	"christmas": "\\etc\\x_mas\\",
	"halloween": "res\\etc\\halloween\\",
	"obt": "res\\etc\\obt\\obt_event",
	"summer": "res\\etc\\summer_event\\",
}

## The environment variable that shows sets again: a comma list of set
## names, e.g. `OPENSRO_SEASONAL=christmas,halloween`. Empty (the default)
## hides all four.
const ENV := "OPENSRO_SEASONAL"

## The set a model path belongs to, or "" for an ordinary object.
static func classify(path: String) -> String:
	var p := path.to_lower()
	for s in SETS:
		if p.contains(RULES[s]):
			return s
	return ""

## The sets named in a comma list (case and spaces ignored; an unknown name
## is ignored), as a set-name -> true Dictionary.
static func parse_enabled(list: String) -> Dictionary:
	var out := {}
	for part in list.split(",", false):
		var wanted: String = str(part).strip_edges().to_lower()
		if RULES.has(wanted):
			out[wanted] = true
	return out

## The sets shown again: OPENSRO_SEASONAL and the settings file's
## `[world]` `seasonal="christmas,halloween"` together
## (ClientSettings.seasonal_shown; the value must be quoted).
static func enabled_from_environment() -> Dictionary:
	var out := parse_enabled(OS.get_environment(ENV))
	out.merge(parse_enabled(ClientSettings.seasonal_shown()))
	return out

## type id -> set name, for every object.ifo entry in a set not enabled.
static func hidden_ids(table: ObjidxReader.Table, enabled: Dictionary) -> Dictionary:
	var out := {}
	if table == null:
		return out
	for e in table.entries:
		if e == null:
			continue
		var s := classify(e.path)
		if s != "" and not enabled.has(s):
			out[e.type_id] = s
	return out

## Splits placements into those kept and a per-set count of those hidden.
## Returns {"kept": Array, "hid": {set: count}, "total": int}.
static func filter(placements: Array, hidden: Dictionary) -> Dictionary:
	if hidden.is_empty():
		return {"kept": placements, "hid": {}, "total": 0}
	var kept: Array = []
	var hid := {}
	for p in placements:
		var s: String = hidden.get(p["type_id"], "")
		if s == "":
			kept.append(p)
		else:
			hid[s] = int(hid.get(s, 0)) + 1
	return {"kept": kept, "hid": hid, "total": placements.size() - kept.size()}

## The job log line: `World3D: <r>.o -- hid N seasonal placement(s)
## (christmas a, halloween b, obt c, summer d)`.
static func log_line(mapo_path: String, result: Dictionary) -> String:
	var hid: Dictionary = result["hid"]
	var parts := PackedStringArray()
	for s in SETS:
		parts.append("%s %d" % [s, int(hid.get(s, 0))])
	return "World3D: %s -- hid %d seasonal placement(s) (%s)" % [
		mapo_path, int(result["total"]), ", ".join(parts)]
