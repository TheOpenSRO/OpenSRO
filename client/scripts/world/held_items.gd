extends RefCounted
class_name HeldItems

## Round 850: when a character's weapon and shield are not drawn -- the
## emotes, the stall, a ride -- and the one switch that hides them.
##
## The user (2026-11-01): "when doing action emoticons the weapon is supposed
## to disappear for most if not all, check the original code to verify" and
## "stalls open with weapons too when they shouldn't".
##
## **The switch (READ).** CCompChar's vtable slot 22 (0x00c29bd0, reached as
## [[character +0x9c] +4] +0x58: the character's animation object CCObjCharacter
## at +0x9c, its render model at +4) takes (hide, which). For each part whose
## resource is an item (type 5) it reads the part's attachable `kind` -- the
## word at CResAttachable +0x318 (slot 3, 0x00be60e0, returns +0x314; +4 is the
## trailing block's second word, BsrReader.Attachable.kind) -- and for which 0
## (the only value any caller below passes) sets the part's draw flag +0x98 to
## !hide when that kind is 6, 7, 14 or 15. The effects hung on that part go
## with it (FUN_00c44f40 -> FUN_00c7b3a0 on each attached effect of the part).
## A hide also clears the afterimage (slot 35, 0x00c275a0). Nothing fades: the
## flag is set in the call.
##
## MEASURED (client/tools/census_attach_kind.gd, the box's Data.pk2, every item
## model incl. `_l` / `_r` / `_f`): kind 7 is the right hand's weapon (every
## sword, blade, spear, glaive, one- and two-handed sword, staff, rod, crossbow,
## a dual axe's or dagger's `_r`), kind 6 the left hand's (every bow, harp,
## shield, a dual axe's or dagger's `_l`), kind 15 two crossbow files; no item
## model carries 14; no armour, accessory, job suit or avatar carries 6, 7, 14
## or 15 (their kinds are 0-5, 8, 16 or -1). So the rule hides exactly the
## weapon and shield models, and nothing else -- not a dress, wings or a hat.
##
## **Who throws it (READ, every call of the dispatcher FUN_009c92a0):**
## - op 3, a body state's enter and leave (FUN_009c8900):
##   - state 13, the emote (enter 0xa59bc0 / leave 0xa59c40, mask 0x2000): on
##     enter hide, on leave show -- except Rush (0x3091 byte 2, action 4004),
##     which leaves the weapon as it is (0x9c897d: byte 2 is applied only with
##     the dev console's Camera toggle, [0x110f80c]+0x3ce, command "Camera"
##     at 0x5598f5 -> 0x542300; or when a visual change hid the weapon, below).
##     Every player's emote is state 13 (FUN_008a7950: IsKindOf CICUser,
##     0xef1bc0), this client's own and another's alike.
##   - state 15, the stall's vendor pose (enter 0xa5a330 / leave 0xa59c90,
##     mask 0x8000): hide on enter, show on leave, for a CICUser only (0x9c8957:
##     IsKindOf 0xef1bc0) -- every player, never a pet in the jinn pose.
##   The leave also runs through CICharactor slot 54 (0x9db180) for a state
##   ended from outside its own clip.
## - op 0, a charactervisualchange.txt skill condition with its +0x10 set
##   (Condition_SkillCodeName / Condition_Skill slots 4/5, 0x4e92f0 /
##   0x4e8e20) sets / clears bit 0 of +0x768, "the weapon stays hidden": the
##   states' leave then keeps it hidden, and Rush shows it for its length.
##   OpenSRO models no skill visual change (`weapon_hidden_by_change` false).
## - op 1, a skill decoration (0xa4d660, 0xa534d0, 0xa53610, 0xa53dd0,
##   0xa54f00, 0xa557f0) by a byte of its skill data: not modelled (OPEN).
## - op 2, every animation started through CCObjCharacter slot 3/4 (slot 7,
##   0xa5bcd0, from 0xa5a930 and 0xa5b550): shows the weapon, hides it for the
##   avatar_nasrun1..3 animation groups, and leaves it alone for ANI_DAMAGE1
##   (3), ANI_DAMAGE2 (9) and ANI_PICK (38) -- the clips that can play inside
##   an emote or a stall without ending it.
##
## Not covered (READ: no call of 0x9c92a0 from their states): sitting, the
## pick-up (state 10), the idle fidgets, death, the job states, the trade
## transport. The ride is a different rule (round 796:
## CharacterVisualChange::CObjItem::vslot_003, 0x4e8830, visual slots 6 and 7
## while mounted) that OpenSRO draws through this same switch.
##
## **How OpenSRO holds it (OURS).** A body's held items are drawn when no
## reason to hide them holds (`ride`, `emote`, `stall`); each reason comes and
## goes with its state. Held per character, not per node, so a re-dress -- a
## weapon swap, an equip -- builds the new weapon hidden while a reason holds
## (World3D._step_held). The original's op 2 would show a new weapon's clip at
## a swap during an emote (INFERRED; OPEN whether its fresh part starts drawn).

## The attachable kinds slot 22 hides for which = 0 (READ, 0xc29bd0).
const HIDE_KINDS := [6, 7, 14, 15]
## Rush: the emote byte 0x3091 carries for action 4004 (READ, 0x793b00).
const EMOTE_RUSH := 2
## The body-state masks (READ: 1 << state).
const STATE_EMOTE_MASK := 0x2000
const STATE_VENDOR_MASK := 0x8000

## What a state's enter or leave does to the weapon.
const NO_CHANGE := -1
const SHOW := 0
const HIDE := 1

const REASON_RIDE := &"ride"
const REASON_EMOTE := &"emote"
const REASON_STALL := &"stall"

## The metas this reads on a worn item's node: the item's visual slot and its
## model's attachable kind (CharacterAppearance.VISUAL_SLOT_META /
## ATTACH_KIND_META; spelled out so this file names no builder).
const VISUAL_SLOT_META := &"opensro_visual_slot"
const ATTACH_KIND_META := &"opensro_attach_kind"
const SLOT_WEAPON := 6
const SLOT_SHIELD := 7
## WornItemFx.MARKER_META: an item's own ambient particles on the body
## skeleton, naming the item node they belong to.
const FX_MARKER_META := &"opensro_item_ambient_marker"

## Whether slot 22 hides a part of this attachable kind.
static func kind_hidden(kind: int) -> bool:
	return kind in HIDE_KINDS

## FUN_009c8900 for op 3: what entering (`enter`) or leaving a state of
## `mask` does, with the state's byte `sub` (the emote's), whether the body is
## a player (CICUser), bit 0 of +0x768 (`kept_hidden`, a skill visual change)
## and the Camera console toggle. HIDE, SHOW or NO_CHANGE.
static func state_effect(enter: bool, mask: int, sub: int, is_user: bool = true,
		kept_hidden: bool = false, camera: bool = false) -> int:
	# The "out" byte: 0 hides, 1 shows (0x9c892c / 0x9c8916).
	var show: bool
	if enter:
		show = sub == EMOTE_RUSH and kept_hidden
	else:
		show = not kept_hidden
	var apply := false
	if mask == STATE_EMOTE_MASK:
		apply = camera or sub != EMOTE_RUSH or kept_hidden
	elif mask == STATE_VENDOR_MASK:
		apply = is_user
	if not apply:
		return NO_CHANGE
	return SHOW if show else HIDE

## Whether an emote (its 0x3091 byte) takes the weapon away in normal play.
static func emote_hides(emote_byte: int) -> bool:
	return state_effect(true, STATE_EMOTE_MASK, emote_byte) == HIDE

## Whether a node under a body skeleton is a held item slot 22 hides: by its
## model's attachable kind, or -- a node built before the kind was known --
## by its visual slot (weapon or shield; the census: the same models).
static func is_held_node(n: Node) -> bool:
	if n.has_meta(ATTACH_KIND_META):
		return kind_hidden(int(n.get_meta(ATTACH_KIND_META)))
	var slot := int(n.get_meta(VISUAL_SLOT_META, -1))
	return slot == SLOT_WEAPON or slot == SLOT_SHIELD

## Shows or hides `skel`'s held items (each a direct child carrying the
## metas) and the ambient particles marked as theirs. Their glows and EquipFx
## holders hang under the node and go with it. Returns how many items.
static func set_shown(skel: Node, shown: bool) -> int:
	if skel == null or not is_instance_valid(skel):
		return 0
	var ids := {}
	for c in skel.get_children():
		if c is Node3D and is_held_node(c):
			(c as Node3D).visible = shown
			ids[c.get_instance_id()] = true
	if not ids.is_empty():
		for c in skel.get_children():
			if c is Node3D and c.has_meta(FX_MARKER_META) and ids.has(int(c.get_meta(FX_MARKER_META))):
				(c as Node3D).visible = shown
	return ids.size()

## Whether the held items of `skel` are all drawn, all hidden, or there are
## none: "shown", "hidden", "mixed" or "none" (QA).
static func state_of(skel: Node) -> String:
	if skel == null or not is_instance_valid(skel):
		return "none"
	var on := 0
	var off := 0
	for c in skel.get_children():
		if c is Node3D and is_held_node(c):
			if (c as Node3D).visible:
				on += 1
			else:
				off += 1
	if on + off == 0:
		return "none"
	if off == 0:
		return "shown"
	return "hidden" if on == 0 else "mixed"
