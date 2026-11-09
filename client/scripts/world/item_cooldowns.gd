extends RefCounted
class_name ItemCooldowns

## Round 826: this player's item re-use timers, as the original's
## CItemReuseDelayManager keeps them (game process +0x77c, 0x778bc0). READ
## from sro_client.exe unless a line says otherwise.
##
## THREE STORES, one key space here: a list keyed by a "re-use kind" ("k<n>"),
## a map keyed by a COOLTIME group ("g<n>") and a map keyed by the item's ref
## id ("r<n>"); each entry {total ms, left ms}. Every frame the left falls by
## the frame's ms (0x9b9f60), floored at 0, and an entry at 0 goes (the
## list's kind 0x10, held at 1, is never armed here).
##
## ARMED on an accepted use (Item_OnUseItemResult 0x87a7b0 -> 0x778960(kind,
## ms, item)):
## - an item with a COOLTIME pair (ItemTableReader.cooltime_of; ref +0x53c /
##   +0x540): kind 0x12 for its ms -- its group's entry, or its own id's
##   when the group is 0 (0x87a872..0x87a899);
## - 3/3/1 (potions): a base of 1000 ms for a China character, 15000 for a
##   Europe one (the character's country byte, 0x87a92b..0x87a96f), 4000
##   for a percentage potion (Param2 or Param4 not 0, 0x87a97e..); then by
##   TypeID4 (the table at 0x87b6b8): 1 kind 1 for the base, + 4000 while
##   the player is in panic (0x200000 in its state mask); 2 kind 2, + 4000
##   while in combustion (0x400000); 3 kind 3 for the base, only with no
##   COOLTIME; 4, 5, 7, 9 kinds 4, 5, 6, 7 for 1000; 6, 8, 10 nothing;
## - 3/3/2 (pills, a base of 1000 for both, 0x87abd3): TypeID4 1 kind 0xd for
##   20000 (0x87ac00), 6 kind 0xe and 7 kind 0xf for 1000.
## Not armed here (OPEN): the kinds 0x10, 0x11 and 0x13..0x1f of the item
## classes 0x666e60, 0x5dd680, 0x667000, 0x666eb0 and 0x666ce0 test (not read
## to TypeIDs), the restore opcode 0x3077 (no server sends it) and 0x320c.
##
## SHOWN (UI_SILKMALL::FUN_0067cbf0, `key_of`): a slot's item picks the
## entry it shows by the same kinds -- 3/3/1 TypeID4 1..5 kinds 1..5 (3 only
## with no COOLTIME), 7 kind 6, 9 kind 7, 3 with a COOLTIME and 10 the
## group's or the id's entry, 6 and 8 none; 3/3/2 TypeID4 1, 6, 7 kinds 0xd,
## 0xe, 0xf; anything else the group's entry when it has a group, else the
## id's (the other 3/3/2 rows INFERRED to take that path).

const KIND_DATA := 0x12
const PANIC := 0x200000
const COMBUSTION := 0x400000

## key -> [total ms, left ms]
var _entries := {}

## What the entry key of an item is: its COOLTIME group's when it has one,
## else its own id's.
static func data_key(item_id: int, cool_group: int) -> String:
	return "g%d" % cool_group if cool_group != 0 else "r%d" % item_id

## The entry a slot holding this item shows (0x67cbf0), or "" for none.
## `types` is TypeID1..4.
static func key_of(item_id: int, types: PackedInt32Array, cool_group: int, cool_ms: int) -> String:
	if types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 1:
		match types[3]:
			1, 2, 4, 5:
				return "k%d" % types[3]
			3:
				return "k3" if cool_ms == 0 else data_key(item_id, cool_group)
			7:
				return "k6"
			9:
				return "k7"
			10:
				return data_key(item_id, cool_group)
		return ""
	if types.size() >= 4 and types[0] == 3 and types[1] == 3 and types[2] == 2:
		match types[3]:
			1:
				return "k13"
			6:
				return "k14"
			7:
				return "k15"
	return data_key(item_id, cool_group)

## The entries an accepted use arms: [[key, ms], ...] (0x87a7b0).
static func arms_of(item_id: int, types: PackedInt32Array, cool_group: int, cool_ms: int, param2: int,
		param4: int, europe: bool, states: int) -> Array:
	var out: Array = []
	if cool_ms != 0:
		out.append([data_key(item_id, cool_group), cool_ms])
	if types.size() < 4 or types[0] != 3 or types[1] != 3:
		return out
	if types[2] == 1:
		var base := 15000 if europe else 1000
		if param2 != 0 or param4 != 0:
			base = 4000
		match types[3]:
			1:
				out.append(["k1", base + (4000 if states & PANIC else 0)])
			2:
				out.append(["k2", base + (4000 if states & COMBUSTION else 0)])
			3:
				if cool_ms == 0:
					out.append(["k3", base])
			4, 5:
				out.append(["k%d" % types[3], 1000])
			7:
				out.append(["k6", 1000])
			9:
				out.append(["k7", 1000])
	elif types[2] == 2:
		match types[3]:
			1:
				out.append(["k13", 20000])
			6:
				out.append(["k14", 1000])
			7:
				out.append(["k15", 1000])
	return out

func arm(key: String, ms: int) -> void:
	if key == "" or ms <= 0:
		return
	_entries[key] = [ms, ms]

## One frame of `ms` milliseconds (0x9b9f60).
func tick(ms: int) -> void:
	if ms <= 0 or _entries.is_empty():
		return
	for key in _entries.keys():
		var e: Array = _entries[key]
		e[1] = maxi(int(e[1]) - ms, 0)
		if int(e[1]) == 0:
			_entries.erase(key)

func left_ms(key: String) -> int:
	var e: Array = _entries.get(key, [])
	return int(e[1]) if not e.is_empty() else 0

## left / total, 0 for none.
func ratio(key: String) -> float:
	var e: Array = _entries.get(key, [])
	return float(e[1]) / float(e[0]) if not e.is_empty() and int(e[0]) > 0 else 0.0

func count() -> int:
	return _entries.size()

## Drops COOLTIME group `group`'s entry at once (round 872, OURS: the
## Forgotten World timer reset's OpTimersReset; the original has no message
## that clears a running entry -- GameWorldNet.OP_TIMERS_RESET has the
## READ). Answers whether one was there.
func clear_group(group: int) -> bool:
	return _entries.erase("g%d" % group)

func clear() -> void:
	_entries.clear()
