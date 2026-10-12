extends RefCounted
class_name AutoPotion

## The auto potion (round 786): retail's CAutoPotion, the object at
## CGInterface+0x6fc (built by 0x82d010), and the checks that drink for the
## player. Everything here is READ from sro_client.exe unless a line says
## otherwise; docs/protocol/auto_potion.md has the full account.
##
## **The settings.** Three rows -- HP (0), MP (1), abnormal status (2) -- of
## {enabled, percent, quick slot}, and the potion use delay {enabled, ms}.
## A row's record is 16 bytes at this+4+16*row (0x82cd50): +0 enabled, +1 the
## row's timer-armed flag, +2 the percent, +4 the threshold, +8 the slot kind
## (2: a quick slot) and +0xc the quick slot (1..40). The delay is +0x34
## (enabled) and +0x38 (ms), 500 ms at construction (0x82d034).
##
## **The quick slot** is belt x 10 + key + 1 (0x741420 / 0x741d80: belt 0..3
## is F1..F4, key 0..9 is the combo's "1".."9","0"; capped at 40), the same
## index the underbar's slots are kept by (HudUnderbar.slot_index), so slot 1
## is F1's "1" and slot 40 F4's "0".
##
## **The wire** (0x7158 type 2, CAutoPotion::Send 0x82d2e0; the character
## data's three words and byte, 0x82cf60): a row is a u16 -- bit 15 enabled,
## bits 8..14 the percent, bits 4..7 the belt + 1 and bits 0..3 the key + 1
## with key "0" as 10 (encode_row / decode_row) -- and the delay a u8, bit 7
## enabled and bits 0..6 the delay in units of 100 ms.
##
## **The checks** (0x82d0e0 HP, 0x82d160 MP, 0x82d1d0 abnormal), each run on
## two paths: the 0x3057 update handler (0x8aa0f0) calls a row's check when
## that pool's update (flag 1 HP, 2 MP, 4 the state mask) arrives for this
## player, the row is enabled and its timer is not armed; and the interface's
## timer (CGInterface::vslot_005, 0x78a796..0x78a7bc: timers 0xe, 0xf, 0x10)
## calls it again every period. A check:
##
##   - returns at once when its row is disabled;
##   - when the player can act (player+0x65c bit 0, see can_act) and
##     HP <= threshold (MP <= threshold; for the abnormal row: a non-zero
##     state mask) -- `cmp; ja` skips only a pool ABOVE its threshold --
##     uses the row's quick slot, except HP while zombie (mask 0x20) and the
##     abnormal row while stunned (mask 0x4000);
##     then arms the row's timer, if not armed, for the delay when the delay
##     box is checked, else 500 ms (0x82d126 `mov eax,0x1f4`);
##   - otherwise disarms the flag and kills the timer.
##
## The threshold is trunc(max x float32(percent / 100.0)) (0x82cdb0), set
## when the percent is confirmed (0x82d0b0) and whenever the player's maximum
## HP or MP is set (CICPlayer's setters 0x9d4b60 / 0x9d4b90 tail-call it).
##
## **The use** (0x82ce90): the quick slot is fired (0x60b850, the same
## function a key press reaches) only when it holds a bag item whose TID is a
## recovery potion (3/3/1) or a cure (3/3/2) (0x60b1d0 -> 0x60ae50); an empty
## slot, a skill or any other item does nothing, and the check runs on. Which
## potion it is does not matter: an MP potion in the HP row is drunk for HP.
## The item's own reuse delay is the server's to refuse (the slot function
## sends without a cooldown test of its own).

const ROW_HP := 0
const ROW_MP := 1
const ROW_ABNORMAL := 2
const ROW_COUNT := 3

## The interface timer ids the three rows arm (0x82d13b / 0x82d1b0 / 0x82d226).
const TIMER_IDS := [0xe, 0xf, 0x10]
## The period when the delay box is not checked (0x82d126, 0x82d19b, 0x82d211).
const UNCHECKED_DELAY_MS := 500
## The delay at construction (0x82d034 `mov DWORD PTR [ebx+0x38],0x1f4`).
const CONSTRUCTED_DELAY_MS := 500
## The client's mask bits the checks test: zombie (0x82d106 `test [eax+0x2c4],
## 0x20`) and stun (0x82d1f5 `test eax,0x4000`).
const ZOMBIE_BIT := 0x20
const STUN_BIT := 0x4000
## The slot kind a row's record carries for a quick slot (+8; 0x82ccf0 stores
## it, 0x82ce90 uses the slot only for it).
const KIND_QUICKSLOT := 2
## 0x82ccf0 caps a quick slot at 0x33 (51, the underbar's MAX_QUICKSLOT).
const SLOT_CAP := 0x33
## The highest slot the window's combos name (0x741420 `cmp eax,0x28`).
const MAX_SLOT := 40

## The defaults 0x8a7bd0 applies to character data whose delay byte is 0 (a
## character that never confirmed the window): HP 0x3211 (off, 50 %, F1 "1"),
## MP 0x3212 (off, 50 %, F1 "2"), abnormal 0x0013 (off, F1 "3"), delay 0x8a
## (on, 1.0 s); and an HP word whose slot byte is 0 is replaced by 0x3211.
const DEFAULT_WORDS := [0x3211, 0x3212, 0x0013]
const DEFAULT_DELAY_BYTE := 0x8a

class Row extends RefCounted:
	var enabled := false
	## The timer-armed flag (+1 in the record; 0 means the update path may run
	## the check).
	var armed := false
	var percent := 0
	var threshold := 0
	var kind := 0
	var slot := 0

var rows: Array = []
var delay_enabled := false
var delay_ms := CONSTRUCTED_DELAY_MS

## The player as the checks read it.
var hp := 0
var max_hp := 0
var mp := 0
var max_mp := 0
var status_mask := 0

## Callables the world supplies: can_act() -> bool, INFERRED for
## player+0x65c bit 0 (an action-state bit 0x9c9920 sets, which the item use
## itself also requires, 0x796d37); slot_usable(slot) -> bool, 0x60b1d0;
## use_slot(slot), 0x60b850 -- the quick slot fired as a key press fires it.
var can_act: Callable
var slot_usable: Callable
var use_slot: Callable

## The interface's timers, id -> {"interval": ms, "last": ms} (0xb93320 adds,
## 0xb93170 removes, 0xb933d0 fires every one whose interval has passed and
## restamps it).
var _timers: Dictionary = {}
## The clock the timers run on (ms); step() advances it.
var now_ms := 0

func _init() -> void:
	for i in ROW_COUNT:
		rows.append(Row.new())

# --- The wire --------------------------------------------------------------

## A row's u16 as Send writes it (0x82d368..0x82d3b9).
static func encode_row(enabled: bool, percent: int, slot: int) -> int:
	var w := (percent & 0x7f) << 8
	var hi := 0
	var lo := 0
	if slot != 0:
		hi = slot / 10
		lo = slot % 10
		if lo == 0:
			lo = 10
		else:
			hi += 1
	w |= ((hi & 0xf) << 4) | (lo & 0xf)
	if enabled:
		w |= 0x8000
	return w

## A u16 back into {enabled, percent, slot} as 0x82cf60 reads it: the slot is
## (belt - 1) x 10 + key in byte arithmetic, capped at 40, and 0 when both
## nibbles are.
static func decode_row(w: int) -> Dictionary:
	var hi := (w >> 4) & 0xf
	var lo := w & 0xf
	var slot := 0
	if hi != 0 or lo != 0:
		slot = mini(((hi + 0xff) & 0xff) * 10 + lo, MAX_SLOT)
	return {"enabled": (w >> 15) & 1 == 1, "percent": (w >> 8) & 0x7f, "slot": slot}

## The seven bytes this object sends (0x7158 type 2, after the type byte).
func encode() -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(7)
	for i in ROW_COUNT:
		var r: Row = rows[i]
		out.encode_u16(i * 2, encode_row(r.enabled, r.percent, r.slot))
	var d := (delay_ms / 100) & 0x7f
	if delay_enabled:
		d |= 0x80
	out[6] = d
	return out

## The character data's seven bytes taken in, with 0x8a7bd0's defaults for a
## zero delay byte (and an HP word with no slot); a short array is treated as
## all zero. Each row's threshold is computed against the maximum known now.
func load_bytes(data: PackedByteArray) -> void:
	var words := [0, 0, 0]
	var d := 0
	if data.size() >= 7:
		for i in ROW_COUNT:
			words[i] = data.decode_u16(i * 2)
		d = data[6]
	if d == 0:
		words = DEFAULT_WORDS.duplicate()
		d = DEFAULT_DELAY_BYTE
	if words[0] & 0xff == 0:
		words[0] = DEFAULT_WORDS[0]
	for i in ROW_COUNT:
		var v := decode_row(int(words[i]))
		var r: Row = rows[i]
		r.enabled = v["enabled"]
		r.percent = v["percent"]
		r.kind = KIND_QUICKSLOT
		r.slot = v["slot"]
	delay_enabled = d & 0x80 != 0
	delay_ms = (d & 0x7f) * 100
	_recompute(ROW_HP)
	_recompute(ROW_MP)

# --- The window's Confirm ----------------------------------------------------

## What CIFAutoPotion's Confirm (0x741590) does with the window's values --
## `values` is {"rows": [{enabled, percent, slot} x3], "delay_enabled",
## "delay_ms"}: a row whose enabled, percent (HP/MP) or slot differs takes all
## three (0x82ccd0, 0x82d0b0, 0x82ccf0 -- each clears the row's armed flag;
## the timer itself is left running), the delay likewise. Returns whether
## anything changed: only then does Confirm send (0x82d2e0).
func apply(values: Dictionary) -> bool:
	var changed := false
	var vr: Array = values.get("rows", [])
	for i in mini(vr.size(), ROW_COUNT):
		var v: Dictionary = vr[i]
		var r: Row = rows[i]
		var en := bool(v.get("enabled", r.enabled))
		var pct := int(v.get("percent", r.percent))
		var slot := int(v.get("slot", r.slot))
		var same := r.enabled == en and r.slot == slot
		if i != ROW_ABNORMAL:
			same = same and r.percent == pct
		if same:
			continue
		r.enabled = en
		r.armed = false
		if i != ROW_ABNORMAL:
			r.percent = pct & 0xff
			_recompute(i)
		r.kind = KIND_QUICKSLOT
		r.slot = mini(slot, SLOT_CAP)
		changed = true
	var de := bool(values.get("delay_enabled", delay_enabled))
	var dm := int(values.get("delay_ms", delay_ms))
	if de != delay_enabled or dm != delay_ms:
		delay_enabled = de
		delay_ms = dm
		changed = true
	return changed

# --- The player --------------------------------------------------------------

## 0x82cdb0: trunc(max x float32(percent / 100.0)); the abnormal row's max is
## 1 (0x82cde8 `mov eax,0x1`).
func _recompute(row: int) -> void:
	var r: Row = rows[row]
	var m := 1
	if row == ROW_HP:
		m = max_hp
	elif row == ROW_MP:
		m = max_mp
	var frac := PackedFloat32Array([float(r.percent) / 100.0])[0]
	r.threshold = int(float(m) * frac)

## An HP update for this player (0x3057 flag 1 in retail; here every message
## that sets the bar): a new maximum recomputes the threshold (0x9d4b60), and
## the HP row's check runs when it is enabled and not armed (0x8aa13a..
## 0x8aa152).
func on_hp(current: int, maximum: int) -> void:
	if maximum > 0 and maximum != max_hp:
		max_hp = maximum
		_recompute(ROW_HP)
	hp = current
	var r: Row = rows[ROW_HP]
	if r.enabled and not r.armed:
		check(ROW_HP)

## The MP update's twin (0x8aa196..0x8aa1b8, 0x9d4b90).
func on_mp(current: int, maximum: int) -> void:
	if maximum > 0 and maximum != max_mp:
		max_mp = maximum
		_recompute(ROW_MP)
	mp = current
	var r: Row = rows[ROW_MP]
	if r.enabled and not r.armed:
		check(ROW_MP)

## The state mask's update (flag 4, 0x8aa2a7..0x8aa2c9).
func on_status(mask: int) -> void:
	status_mask = mask
	var r: Row = rows[ROW_ABNORMAL]
	if r.enabled and not r.armed:
		check(ROW_ABNORMAL)

## One row's check (0x82d0e0 / 0x82d160 / 0x82d1d0).
func check(row: int) -> void:
	var r: Row = rows[row]
	if not r.enabled:
		return
	var act := can_act.is_valid() and bool(can_act.call())
	var low := false
	var skip_use := false
	match row:
		ROW_HP:
			low = hp <= r.threshold
			skip_use = status_mask & ZOMBIE_BIT != 0
		ROW_MP:
			low = mp <= r.threshold
		ROW_ABNORMAL:
			low = status_mask != 0
			skip_use = status_mask & STUN_BIT != 0
	if act and low:
		if not skip_use:
			_use(row)
		if not r.armed:
			r.armed = true
			_set_timer(TIMER_IDS[row], delay_ms if delay_enabled else UNCHECKED_DELAY_MS)
	else:
		r.armed = false
		_kill_timer(TIMER_IDS[row])

## 0x82ce90: a quick-slot row fires its slot when the slot holds a potion or a
## cure (0x60b1d0), through the key press's own function (0x60b850).
func _use(row: int) -> void:
	var r: Row = rows[row]
	if r.kind != KIND_QUICKSLOT:
		return
	if slot_usable.is_valid() and bool(slot_usable.call(r.slot)) and use_slot.is_valid():
		use_slot.call(r.slot)

# --- The interface timers ------------------------------------------------------

## 0xb93320: a timer already registered keeps its interval (the add returns 0).
func _set_timer(id: int, interval_ms: int) -> void:
	if _timers.has(id) or interval_ms <= 0:
		return
	_timers[id] = {"interval": interval_ms, "last": now_ms}

func _kill_timer(id: int) -> void:
	_timers.erase(id)

func timer_running(id: int) -> bool:
	return _timers.has(id)

func timer_interval(id: int) -> int:
	return int((_timers.get(id, {}) as Dictionary).get("interval", 0))

## The timer pass (0xb933d0): every timer whose interval has passed since its
## stamp fires (CGInterface::vslot_005 -> the row's check) and is restamped.
func step(now: int) -> void:
	now_ms = now
	for id in _timers.keys():
		if not _timers.has(id):
			continue
		var t: Dictionary = _timers[id]
		if now_ms - int(t["last"]) < int(t["interval"]):
			continue
		var row := TIMER_IDS.find(id)
		if row >= 0:
			check(row)
		if _timers.has(id):
			_timers[id]["last"] = now_ms

## Everything stopped (a world exit or death's reset of the interface is not
## read; OURS: the timers end with the world they ran in).
func reset_timers() -> void:
	_timers.clear()
	for r in rows:
		(r as Row).armed = false

## The window's view of the settings: {"rows": [{enabled, percent, slot}],
## "delay_enabled", "delay_ms"}.
func values() -> Dictionary:
	var out_rows: Array = []
	for r in rows:
		var row := r as Row
		out_rows.append({"enabled": row.enabled, "percent": row.percent, "slot": row.slot})
	return {"rows": out_rows, "delay_enabled": delay_enabled, "delay_ms": delay_ms}
