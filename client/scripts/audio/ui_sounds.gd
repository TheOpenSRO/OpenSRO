extends RefCounted
class_name UiSounds

## The interface and item sounds (round 615): which effect-table key the
## retail client plays for a window opening or closing, a level-up, a potion,
## a moved or worn item, a drop, a repair, and the front-end error box -- and
## the one place this client plays them. Every key goes through the audio
## core (SoundTable.play_key, round 611) as a 2-D sound.
##
## Every address is sro_client.exe's; docs/protocol/SOUND_FORMAT.md
## ("Interface sounds") has the full record. Labels: **read** out of the
## binary, **measured** in the archives, **inferred**, or **ours**.
##
## THE CALL (read). A UI sound is `soundMgr->vslot(+0x28)(L"snd_...")` on the
## singleton DAT_0110aad8, which builds `UI:<name>:-:-:-:-` and plays it with
## no position (FUN_00a6f7f0(key, NULL, 0.0)). Item and level-up sounds go
## through the name dispatcher (+0x24 / +0x2c) to a handler that builds an
## `ITEM:` or `UI:` key and plays it the same way, with no position. So every
## key here is played 2-D.
##
## WINDOWS (read, 0x79a7e0 and its COMDAT twin 0x79ab80). The interface's
## toggle helper runs AFTER a toggle routine has shown or hidden a window:
## nothing when the interface itself is hidden (its first 0xb8f530 is on the
## interface, +0x61); otherwise snd_window_open if the window is shown now
## (window+0x61), else snd_window_close. 78 sites reach it: 72 calls and 3
## tail jumps to 0x79a7e0, and 3 calls to its twin 0x79ab80, all in window
## toggle routines. `window_toggled` is that
## rule. Which of this client's windows reach it is decided in HudPanels,
## window by window, each with its routine's address.
##
## BUTTONS (round 859, READ; corrects round 615). snd_button_click is
## referenced twice. 0x656160 is not the item mall's: its module tag misled
## round 615 -- the RTTI walk names it CIFButton's vtable slot 17, the message
## handler CIFCloseButton and CIFButtonTree share. On a left-button release
## (0x202) over the button it was pressed on, a button whose style (+0x38c)
## lacks 0x20 sends its click and plays snd_button_click (`button_clicked`;
## UiBuilder hooks every CIFButton it builds). The other site is the title
## screen's server list, GDR_LIST_SERVER (id 51 in resinfo\pstitle.txt),
## notification 0x806e -> 0x866f80.

const KEY_WINDOW_OPEN := "UI:snd_window_open:-:-:-:-"
const KEY_WINDOW_CLOSE := "UI:snd_window_close:-:-:-:-"
## 0xa72580 (read): "UI:" + name + ":-:CHINESS:-:-", whatever the race. Only
## that row is live in the table; the UROPIAN and ARABIAN rows are
## commented out (read, effectsound.txt).
const KEY_LEVEL_UP := "UI:snd_levup:-:CHINESS:-:-"
const KEY_POTION := "UI:snd_potion:-:-:-:-"
const KEY_ERROR := "UI:snd_error:-:-:-:-"
const KEY_REPAIR := "UI:snd_repair:-:-:-:-"
const KEY_REVIVE := "UI:snd_revive:-:-:-:-"
## Round 829: a worn item's wear (0x3052, 0x8adf50): to 0 snd_eqbreak, to
## exactly 6 snd_eqdanger (the table gives them each other's .wav names as
## authored -- SND_EQBREAK Itemdanger.wav, SND_EQDANGER itembreak.wav,
## MEASURED; the key is what the client plays).
const KEY_EQBREAK := "UI:snd_eqbreak:-:-:-:-"
const KEY_EQDANGER := "UI:snd_eqdanger:-:-:-:-"
## Round 819: a quest notice of SN_TALK_COMMON_END (0x30EC's handler
## 0x884a30 plays snd_quest_end, READ; effectsound.txt's UI SND_QUEST_END row).
const KEY_QUEST_END := "UI:snd_quest_end:-:-:-:-"
## Round 859: the quest reward button's reply 0xB0D8 with result 1 (its
## handler c:0x881450 reads the u8, then the u32, and plays snd_quest; READ).
## Its other three sites are the item mall's and the event guide's.
const KEY_QUEST := "UI:snd_quest:-:-:-:-"

## A key the log reports at most once a second each (ours): a repair of
## eight slots fires eight sounds in one frame, and the log should say so
## once, with the count.
const LOG_INTERVAL_MS := 1000

## Keys fired, newest last (tests and QA read it); capped.
static var fired: Array = []
const FIRED_CAP := 64

static var _last_log_ms: Dictionary = {}
static var _suppressed: Dictionary = {}

## Plays `key` and logs it (rate-limited per key). `why` says what fired it.
static func play(key: String, why: String) -> void:
	fired.append(key)
	if fired.size() > FIRED_CAP:
		fired.pop_front()
	var now := Time.get_ticks_msec()
	var last: int = _last_log_ms.get(key, -LOG_INTERVAL_MS)
	if now - last >= LOG_INTERVAL_MS:
		var extra := ""
		var skipped: int = _suppressed.get(key, 0)
		if skipped > 0:
			extra = " (+%d more since the last line)" % skipped
		print("AUDIO ui %s -- %s%s" % [key, why, extra])
		_last_log_ms[key] = now
		_suppressed[key] = 0
	else:
		_suppressed[key] = int(_suppressed.get(key, 0)) + 1
	SoundTable.play_key(key)

## How many times `key` fired since the last clear (tests).
static func count(key: String) -> int:
	var n := 0
	for k in fired:
		if k == key:
			n += 1
	return n

static func clear_fired() -> void:
	fired.clear()

# --- windows -------------------------------------------------------------------

## 0x79a7e0: after a toggle routine showed or hid a window. Silent while the
## interface itself is hidden.
static func window_toggled(shown_now: bool, interface_shown: bool, what: String) -> void:
	if not interface_shown:
		return
	if shown_now:
		play(KEY_WINDOW_OPEN, what + " shown")
	else:
		play(KEY_WINDOW_CLOSE, what + " hidden")

## Round 859: a CIFButton clicked (the release inside it; see the header).
const KEY_BUTTON_CLICK := "UI:snd_button_click:-:-:-:-"
static func button_clicked(what: String) -> void:
	play(KEY_BUTTON_CLICK, what + " clicked")

## Round 860: makes `btn` an original CIFButton's for its click -- the one
## place every CIFButton gets snd_button_click, whether the layout built it
## (UiBuilder._build_button) or a window made it in code. READ: CIFButton's
## class link is 0xee9828 (CIFButton::vslot_000 c:0x656560; CIFCloseButton
## 0xee9868, CIFButtonTree 0xee9780, CIFDropDownButton 0xee9888); the code
## that creates one by that link (`push 0xee9828` then the GWnd create
## FUN_00ba20b0), besides the layout loader: CIFMainFrame::vslot_010 (its
## close button, c:0x817028), CIFWorldMap::vslot_017 -> FUN_00631d60 (the
## teleport choice popup's rows, c:0x631dfe), FUN_00648a80 (the page-number
## buttons of the stall network, the mall's hot store and wish list,
## c:0x648b85), IFRadioButton's FUN_00657c40 (every radio dot -- the party
## settings, the party match box, the input option -- c:0x657d71),
## CIFQuickPartyWnd::vslot_010 (its lock, c:0x6db2d6), CIFComboBox::vslot_010
## (its drop button, c:0x63283e), CIFVerticalSpinCtrl::vslot_010 (its arrows,
## c:0x65883c / 0x6588a8), CPSTitle::vslot_006, the item mall (c:0x647e38,
## 0x65243c) and CIFConfirmReputationGuide. None of those sites sets the
## style's 0x20 (no `push 0x20` near them; INFERRED their style is 0, so they
## click). The scroll bars' and the 2dt windows' (CNIFButton) buttons are no
## CIFButtons and stay silent. Hooked once, whatever calls this.
static func hook_cif_button(btn: BaseButton, what: String) -> void:
	if btn == null or btn.has_meta(&"cif_click"):
		return
	btn.set_meta(&"cif_click", true)
	btn.pressed.connect(func() -> void: button_clicked(what))

## A routine that plays snd_window_close itself (the storage and store close
## handlers, 0x798e20's alchemy close, the message box's hide).
static func window_closed(what: String) -> void:
	play(KEY_WINDOW_CLOSE, what)

## A routine that plays snd_window_open itself (the message box's show).
static func window_opened(what: String) -> void:
	play(KEY_WINDOW_OPEN, what)

## A message box's close, checked a frame after the box left the tree: it
## sounds only if the window it sat in is still alive and shown. A box freed
## with its whole scene (a change_scene) is gone with its window by then, so
## it is silent (ours: the retail box's hide sounds, its scene teardown does
## not reach ShowWindow).
static func message_box_left(window_ref: WeakRef, what: String) -> void:
	var w = window_ref.get_ref()
	if w == null or not (w is CanvasItem) or not (w as CanvasItem).is_inside_tree():
		return
	if (w as Node).is_queued_for_deletion() or not (w as CanvasItem).is_visible_in_tree():
		return
	play(KEY_WINDOW_CLOSE, what)

# --- items ---------------------------------------------------------------------

## FUN_00a64560 (read): the `<TYPE>` token of an ITEM:snd_equip key, from the
## item's TypeID1..4 (its packed type word: TypeID1 bits 2-4, TypeID2 5-6,
## TypeID3 7-10, TypeID4 11-15; a set bit 1 marks a character, never an
## item). Checked in the function's own order; "" when nothing matches, and
## the key then names no table row, so nothing sounds.
##   TypeID 3/1/4, TypeID4 1-2                     SHIELD
##   3/1/{1,9}  (garments, 0x56fa30 + table 0xa64864), TypeID4 1..6:
##              CAP, GLOVES, ROBE, GLOVES, GLOVES, SHOES
##   3/1/{2,3,10,11} (armour, table 0xa6487c), TypeID4 1..6:
##              HELM, PAULDRONS, BREASTPLATE, CUISSE, GAUNTLET, GREAVE
##   3/1/6 (weapons, table 0xa64894), TypeID4 2..16:
##              SWORD BLADE SPEAR TBLADE BOW SWORD TSWORD DUELAXE WAND STAFF
##              CROSSBOW DAGGER HARP WAND HAMMER
##   3/1/{5,12} (0x56fb40), TypeID4 1 EARRING, 2 NECKLACE, 3 RING
##   3/3/1, TypeID4 1-3 (0x871e20/60/a0)            POTION
##   3/3/4, TypeID4 1-2 (0x60ae20)                  QUIVER
##   3/3/3 (0x666d70)                               SCROLL
##   3/3/5, TypeID4 not 1 (0x871de0)                GOLD (no row: silent)
##   3/1/7, TypeID4 1 TRADER, 2 THIEF, 3 HUNTER (0x666e60, 0x9c8440/80/c0)
const GARMENT_TOKENS := ["CAP", "GLOVES", "ROBE", "GLOVES", "GLOVES", "SHOES"]
const ARMOUR_TOKENS := ["HELM", "PAULDRONS", "BREASTPLATE", "CUISSE", "GAUNTLET", "GREAVE"]
const WEAPON_TOKENS := ["SWORD", "BLADE", "SPEAR", "TBLADE", "BOW", "SWORD", "TSWORD", "DUELAXE",
	"WAND", "STAFF", "CROSSBOW", "DAGGER", "HARP", "WAND", "HAMMER"]
const ACCESSORY_TOKENS := ["EARRING", "NECKLACE", "RING"]
const JOB_TOKENS := ["TRADER", "THIEF", "HUNTER"]

static func equip_token(type_ids: PackedInt32Array) -> String:
	if type_ids.size() < 4:
		return ""
	var t1 := type_ids[0]
	var t2 := type_ids[1]
	var t3 := type_ids[2]
	var t4 := type_ids[3]
	if t1 != 3:
		return ""
	if t2 == 1:
		if t3 == 4 and (t4 == 1 or t4 == 2):
			return "SHIELD"
		if t3 in [1, 2, 3, 9, 10, 11]:
			var table: Array = GARMENT_TOKENS if t3 == 1 or t3 == 9 else ARMOUR_TOKENS
			return table[t4 - 1] if t4 >= 1 and t4 <= 6 else ""
		if t3 == 6:
			return WEAPON_TOKENS[t4 - 2] if t4 >= 2 and t4 <= 16 else ""
		if t3 == 5 or t3 == 12:
			return ACCESSORY_TOKENS[t4 - 1] if t4 >= 1 and t4 <= 3 else ""
		if t3 == 7:
			return JOB_TOKENS[t4 - 1] if t4 >= 1 and t4 <= 3 else ""
		return ""
	if t2 == 3:
		if t3 == 1 and t4 >= 1 and t4 <= 3:
			return "POTION"
		if t3 == 4 and (t4 == 1 or t4 == 2):
			return "QUIVER"
		if t3 == 3:
			return "SCROLL"
		if t3 == 5 and t4 != 1:
			return "GOLD"
	return ""

## The key FUN_00a6fb60 builds: "ITEM:" + name + ":-:" + token + ":-:-".
static func equip_key(type_ids: PackedInt32Array) -> String:
	return "ITEM:snd_equip:-:%s:-:-" % equip_token(type_ids)

## An item moved in the bag, to the equipment or back (read, the item-move
## reply 0x87ba20: bag -> bag at 0x87c4f4, bag -> equipment at 0x87c774,
## equipment -> bag at 0x87cf98, each with the moved item's type).
static func item_moved(type_ids: PackedInt32Array, what: String) -> void:
	play(equip_key(type_ids), what)

## FUN_00a72880's `<KIND>` (read) for a drop. Items first (a character's type
## word takes none of these):
##   3/3/5 with TypeID4 not 1                         GOLD
##   3/3/10 with TypeID4 1 or 4, 3/3/11 with 1 or 2   ELIXIR
##   else the dropped object's byte +0x260 is 2 or 6  RARE
##   else "-" -> "ITEM:snd_dropitem:-:-:-:-", which names no row: silent.
## The BOX and BAG rows are commented out of the table (read), and no code
## builds those tokens, so an ordinary drop is silent. What +0x260 holds is
## not read and this client's drop carries no such byte, so RARE is never
## chosen here (open).
static func drop_token(type_ids: PackedInt32Array, is_gold: bool) -> String:
	if is_gold:
		return "GOLD"
	if type_ids.size() < 4 or type_ids[0] != 3 or type_ids[1] != 3:
		return "-"
	var t3 := type_ids[2]
	var t4 := type_ids[3]
	if t3 == 5 and t4 != 1:
		return "GOLD"
	if t3 == 10 and (t4 == 1 or t4 == 4):
		return "ELIXIR"
	if t3 == 11 and (t4 == 1 or t4 == 2):
		return "ELIXIR"
	return "-"

static func drop_key(type_ids: PackedInt32Array, is_gold: bool) -> String:
	return "ITEM:snd_dropitem:-:%s:-:-" % drop_token(type_ids, is_gold)

## CIItem::vslot_024 (0x9e1460): a ground item's appearance plays
## snd_dropitem with its type, with no position (read).
static func item_dropped(type_ids: PackedInt32Array, is_gold: bool, what: String) -> void:
	play(drop_key(type_ids, is_gold), what)

## Item_OnUseItemResult (0x87a7b0, the 0xb04c reply): on success, an item of
## TypeID 3/3/1 (potions) or 3/3/2 plays snd_potion (0x87ac14; every path
## from 0x87a8f0 reaches it). Nothing else in the exe names it (read).
static func is_potion_class(type_ids: PackedInt32Array) -> bool:
	return type_ids.size() >= 3 and type_ids[0] == 3 and type_ids[1] == 3 \
		and (type_ids[2] == 1 or type_ids[2] == 2)

static func item_used(type_ids: PackedInt32Array, what: String) -> void:
	if is_potion_class(type_ids):
		play(KEY_POTION, what)

## The durability reply 0x3052 (FUN_0x8adf50), per slot (read): a durability
## that rose plays snd_revive if it was 0 (a broken item made whole) and
## snd_repair otherwise. So snd_revive is an item's, not the player's:
## 0xddefc0 has no other reference in the exe. A fall to 0 or to exactly 6 on
## a worn item plays snd_eqbreak / snd_eqdanger (durability_key; round 829:
## the server sends 0x3052 on every wear step). `before` and `after` map slot
## -> current durability (a bag slot as 13 + n).
##
## The repair reply sounds every item it raised, worn and bag alike, against
## the durability HudPanels noted when it sent the request (round 829).
static func durability_keys(before: Dictionary, after: Dictionary) -> Array:
	var keys: Array = []
	var slots := after.keys()
	slots.sort()
	for slot in slots:
		if not before.has(slot):
			continue
		var was := int(before[slot])
		var now := int(after[slot])
		if now > was:
			keys.append(KEY_REVIVE if was == 0 else KEY_REPAIR)
	return keys

## Round 829: one 0x3052 (0x8adf50, READ): a rise sounds the repair (from 0
## the revive); a worn item's fall to 0 snd_eqbreak, to exactly 6
## snd_eqdanger. `worn` false for a bag slot (rises only).
static func durability_key(was: int, now: int, worn: bool) -> String:
	if was < 0:
		return ""
	if now > was:
		return KEY_REVIVE if was == 0 else KEY_REPAIR
	if worn and now < was:
		if now == 0:
			return KEY_EQBREAK
		if now == 6:
			return KEY_EQDANGER
	return ""

static func durability_changed(before: Dictionary, after: Dictionary, what: String) -> void:
	for key in durability_keys(before, after):
		play(key, what)

## Worn slot -> the latest current durability this client has heard of.
static var worn_durability: Dictionary = {}

## An equipment list's durability block (slot -> current): the whole worn
## set as it stands, so it replaces what was known.
static func note_worn_list(by_slot: Dictionary) -> void:
	worn_durability = by_slot.duplicate()

## A repair reply: sounds each rise against the latest known state, then
## keeps the reply's values.
static func worn_repaired(after: Dictionary, what: String) -> void:
	durability_changed(worn_durability, after, what)
	for slot in after:
		worn_durability[slot] = after[slot]

## 0x3054 (FUN_008a7020): the player's level-up plays snd_levup through the
## name dispatcher, whose handler 0xa72580 plays KEY_LEVEL_UP with no
## position (read).
static func level_up(what: String) -> void:
	play(KEY_LEVEL_UP, what)

## The front-end message box (0x8613b0): shown with snd_error (read). The
## login screen's refusals stand for it (inferred: CPSTitle::vslot_006 calls
## it at three sites, not identified one by one).
static func error_box(what: String) -> void:
	play(KEY_ERROR, what)

# --- a request remembered until its reply -------------------------------------

## The item a use or move request named, kept until the reply (ours: the
## replies carry no item, and retail reads it from its own slot tables).
static var _pending_use_types := PackedInt32Array()
static var _pending_move_types := PackedInt32Array()
static var _pending_move_what := ""

static func expect_use(type_ids: PackedInt32Array) -> void:
	_pending_use_types = type_ids

static func use_replied(ok: bool) -> void:
	var t := _pending_use_types
	_pending_use_types = PackedInt32Array()
	if ok and not t.is_empty():
		item_used(t, "item used")

static func expect_move(type_ids: PackedInt32Array, what: String) -> void:
	_pending_move_types = type_ids
	_pending_move_what = what

static func move_replied(ok: bool) -> void:
	var t := _pending_move_types
	var what := _pending_move_what
	_pending_move_types = PackedInt32Array()
	_pending_move_what = ""
	if ok and not t.is_empty():
		item_moved(t, what)

static func has_pending_move() -> bool:
	return not _pending_move_types.is_empty()

## 0x30EC with SN_TALK_COMMON_END (FUN_00884a30, READ).
static func quest_end(what: String) -> void:
	play(KEY_QUEST_END, what)
