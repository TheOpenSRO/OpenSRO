extends RefCounted
class_name StateLook

## What an abnormal state looks like on a body (round 785): the state's
## system effect, its colour pulse and its effect on the body's clip speed.
## Labels: READ (sro_client.exe), MEASURED, INFERRED, OURS, OPEN.
##
## READ, FUN_009cd5e0 -- the object's mask setter, which 0x3057 (StatusNet)
## reaches -- walks the 32 bits low to high over (old mask XOR new mask):
## - a bit that came on starts the system decoration named "PARAM_" + the
##   state's label (UI_PARAM::AbnormalState_IconAndLabelForMask(bit, 1),
##   StatusNet.label; FUN_00a950a0 resolves the name, FUN_00a54020 starts
##   it) -- skilleffect.txt's `PARAM_<label>` rows (MEASURED: ACT_L AT_LOOP
##   battle\status_bad_<state>.efp for BU, ES, FB, PS, ZB, BLOOD, DISEASE,
##   STUN, DN, SLEEP, CHAOS, FEAR, MYOPIA, CURSE_HP, TIME_BOMB, FZ, ROOT,
##   STONE, SLOW; a DEACT row for FZ and STONE);
## - a bit that went off ends it (GlobalDataManager::FUN_009cd2b0), which
##   plays the DEACT rows; round 847 (READ): that end (FUN_00a53120 ->
##   FUN_00a4db00) fades the aura out over its row's Fade, 300 ms on every
##   PARAM_ row, and frees it (SkillEffects._end_kept) -- it no longer plays
##   its particles out (up to 4 s; confusion's never ended, 30 s);
## - and, for some bits, the body (only the colour is guarded -- round 856,
##   "THE COLOUR'S GUARDS" below):
##     0x1 FZ        the motion state 9 (FUN_009c8810(9)) and +0xbd = 1; off:
##                   +0xbd = 0
##     0x2 FB        a colour pulse (below) and the clip speed +0xc0 = 0.5
##                   (0xe1b7e0); off: the pulse ends, +0xc0 = 1.0
##     0x4 ES, 0x8 BU, 0x10 PS, 0x20 ZB, 0x2000 DN, 0x4000 STUN
##                   a colour pulse; off: it ends (vtable +0x4c)
##     0x100 SLOW    +0xc0 = 0.75 (0xdd8eec); off: 1.0
## - the pulse is the renderer's vtable +0x48 with two colours and 1000 ms:
##   CObjRendererVS::FUN_00c25800, BerserkLook's SCT_MAT pulse (its header:
##   a triangle wave from colour 1 to colour 2 and back, period 2 x ms). The
##   colours are floats in .rdata, READ per bit below (0xde2488..0xde24c4).
## HERE:
## - the effects are SkillEffects auras keyed by (owner, STATE_TOKEN - bit),
##   ended with their DEACT rows;
## - the pulse is the body's one colour slot, BodyPulse (round 855, READ: the
##   compound's +0x48 / +0x4c, shared with berserk's SCT_MAT): the walk's
##   events go to it in order -- a tinted bit on starts it, a tinted bit off
##   ends it, whoever set it -- and a change with no tinted bit leaves it;
## - +0xc0 is the body's clip speed (INFERRED from the values: 0.5 for
##   frostbite, 0.75 for slowness; round 852 READ it: the tick advances the
##   body's clip by ROUND(+0xc0 x the frame's ms), GlobalDataManager::
##   FUN_009c4180 c:0x9c41c1, +0xbd beside it; a pet's tick overwrites it
##   every frame, PetGait); FZ's motion state 9 is taken as a held
##   pose -- clip speed 0 (INFERRED; the state table that would say what
##   state 9 plays is filled at run time and was not read, OPEN).
##
## THE COLOUR'S GUARDS (round 856, READ: FUN_009cd5e0 and its disassembly,
## c:0x9cd640..0x9cdb68; esi is the object whose mask it is):
## - only the colour calls are guarded: +0x48 on for 0x2, 0x4, 0x8, 0x10,
##   0x20, 0x2000, 0x4000 (the tests at c:0x9cd74a, 0x9cd8b7, 0x9cd7df,
##   0x9cd84d, 0x9cd969, 0x9cd9d1, 0x9cda37) and +0x4c off (c:0x9cdb35..
##   0x9cdb56, and the FB case). The PARAM_ aura's start (FUN_00a54020,
##   c:0x9cd723) and end (FUN_009cd2b0, c:0x9cdac0), FB's and SLOW's clip
##   speed +0xc0 (c:0x9cd7bf, 0x9cd95e; off 0x9cdb01, 0x9cdb2d) and FZ's
##   motion state 9 and +0xbd (c:0x9cd7ce, 0x9cd7d3; off 0x9cdb0b) are not.
## - the guard is tested in each bit's case, on the object itself, from two
##   bytes: +0x2c2 == 1 or +0x448 == 2 skips the call -- except DN's (0x2000)
##   end, which tests +0x2c2 alone (c:0x9cdb35 `cmp [esi+0x2c2],1` jumps to
##   the je at 0x9cdb56 past the +0x448 test), so a kind-2 body's DN end does
##   call +0x4c.
## - +0x2c2 is the BODY MODE, not riding (round 785 wrote "the player
##   riding"; wrong). Its one writer is the setter FUN_009cf880 (`[this+0x2c2]
##   = mode`), reached from 0x30BF kind 4 (FUN_008a80a0 case 4, any object in
##   view), a spawn (FUN_009d17e0 / FUN_0052dc70, the state block's +0x470)
##   and a debug command (FUN_005470f0); mode 1 runs FUN_009dd620(1, ...),
##   the hwan decoration (0x80000000 / SYSTEM_CH_HWAN2MODE), and mode 4 draws
##   the body at alpha 0x50. Mode 1 is BERSERK (BerserkLook), on any body.
##   Mounting writes neither byte: a rider's colour is not guarded.
## - +0x448 is a skill decoration's mark on its object: 2 when a decoration
##   starts whose skill's Param block has 'mom' (code 0x6d6f6d, which the
##   client's parser FUN_009bbca0 files at ref +0x110; FUN_00a53850 and
##   FUN_00a54be0 write it), 1 when its 'pmhp' run reads 100 (FUN_00a54be0),
##   0 when a 'mom' decoration ends (FUN_00a53120) and in the constructor
##   (CICharactor::FUN_009d2ad0). MEASURED: one skill of the client's 61,330
##   decrypted skilldata rows has 'mom', MSKILL_RM_ROC_ATTACK10 (id 31102),
##   the Roc's frenzy (its skilleffect name "괴조 로크 광폭화"), whose ACT_L
##   row carries its own colour (SCT_MAT,170,30,0,235,155,0,1000). Kind 2 is
##   a body in the Roc's frenzy.
## - so a state's colour neither starts nor ends while the body's own
##   decoration colour (berserk's, the frenzy's) holds the slot; that
##   decoration's end (+0x4c, CIDecoSkill::FUN_00a53dd0) ends whichever colour
##   is on. A state that began before and ends inside leaves the slot as it
##   is; one that begins inside never draws its colour.
## HERE: World3D._state_guard reads body mode 1 from NetClient.body_modes
## and kind 2 from the owner's running buffs (a 'mom' skill among them,
## SkillBuffCatalog "mom"); walk() leaves the guarded colour calls out.

## Aura tokens for the states: STATE_TOKEN - bit, never a server token.
const STATE_TOKEN := -1000
const PULSE_MS := 1000.0

## The pulse colours per bit value (READ, FUN_009cd5e0's literals).
const TINTS := {
	0x2: [Color(0.47058824, 0.54901963, 1.0), Color(0.3137255, 0.38431373, 1.0)],
	0x4: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
	0x8: [Color(1.0, 0.3137255, 0.3137255), Color(1.0, 0.5647059, 0.1254902)],
	0x10: [Color(0.10980392, 0.19607843, 0.0627451), Color(0.2509804, 0.35686275, 0.1764706)],
	0x20: [Color(0.40784314, 0.3137255, 1.0), Color(0.3137255, 0.1882353, 0.6039216)],
	0x2000: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
	0x4000: [Color(1.0, 1.0, 0.2509804), Color(0.627451, 1.0, 0.0)],
}
const BIT_FZ := 0x1
const BIT_FB := 0x2
const BIT_SLOW := 0x100
const SPEED_FB := 0.5
const SPEED_SLOW := 0.75

## The two bytes the colour's guards read (round 856, READ; the header): the
## body mode (+0x2c2; 1 is berserk) and the decoration kind (+0x448; 2 while
## a 'mom' decoration runs, the Roc's frenzy).
const BODY_MODE_BERSERK := 1
const KIND_MOM := 2

static func guard_of(body_mode: int, kind: int) -> Dictionary:
	return {"body_mode": body_mode, "kind": kind}

## Whether FUN_009cd5e0 leaves out the colour call (+0x48 when `on`, +0x4c
## when off) of bit value `v` on a body whose bytes are `guard` (guard_of;
## {} is neither): body mode 1 or kind 2 -- DN's end tests the body mode
## alone (c:0x9cdb35).
static func colour_guarded(v: int, on: bool, guard: Dictionary) -> bool:
	var berserk := int(guard.get("body_mode", 0)) == BODY_MODE_BERSERK
	if not on and v == 0x2000:
		return berserk
	return berserk or int(guard.get("kind", 0)) == KIND_MOM

## What one mask change does, walked as FUN_009cd5e0 walks it. `state` is the
## body's look so far ({"tint": [] or [c1, c2], "speed": float,
## "frozen": bool}); returns {"on": [bits came on], "off": [bits went off],
## "tint", "speed", "frozen"} -- the look after the change -- and "pulse",
## the body's colour slot after the walk's events (round 855): null when no
## tinted bit changed (the slot is left as it is, whoever set it), [c1, c2]
## when the last event was a tinted bit coming on (+0x48), [] when it was one
## going off (+0x4c). `guard` (guard_of, round 856) is the body's two bytes:
## a guarded bit's colour call is left out (colour_guarded); its effect, its
## clip speed and the look's "tint" (the state's own colour) are not.
static func walk(old_mask: int, new_mask: int, state: Dictionary, guard: Dictionary = {}) -> Dictionary:
	var tint: Array = state.get("tint", [])
	var speed := float(state.get("speed", 1.0))
	var frozen := bool(state.get("frozen", false))
	var on: Array = []
	var off: Array = []
	var pulse = null
	var changed := (old_mask ^ new_mask) & 0xffffffff
	for bit in 32:
		var v := 1 << bit
		if changed & v == 0:
			continue
		var set := (new_mask & v) != 0
		if set:
			on.append(bit)
			if TINTS.has(v):
				tint = TINTS[v]
				if not colour_guarded(v, true, guard):
					pulse = tint
			if v == BIT_FB:
				speed = SPEED_FB
			elif v == BIT_SLOW:
				speed = SPEED_SLOW
			elif v == BIT_FZ:
				frozen = true
		else:
			off.append(bit)
			if TINTS.has(v):
				tint = []
				if not colour_guarded(v, false, guard):
					pulse = []
			if v == BIT_FB or v == BIT_SLOW:
				speed = 1.0
			elif v == BIT_FZ:
				frozen = false
	return {"on": on, "off": off, "tint": tint, "speed": speed, "frozen": frozen, "pulse": pulse}

## The clip speed a look gives the body: 0 while frozen, else its speed.
static func clip_speed(look: Dictionary) -> float:
	if bool(look.get("frozen", false)):
		return 0.0
	return float(look.get("speed", 1.0))

## The system decoration a state bit starts: "PARAM_" + its label, "" for a
## bit with no label (StatusNet.STATES: bits 12 and 23).
static func effect_id(bit: int) -> String:
	var label := StatusNet.label(bit)
	return "PARAM_" + label if label != "" else ""

# --- the colour pulse ---------------------------------------------------------
# Round 855: the colour is the body's one pulse slot (BodyPulse: the
# compound's +0x48 / +0x4c, READ), which berserk's SCT_MAT shares.

## BodyPulse's name for a state's colour.
const WHO := "state"

## A walk's pulse event on `host` (walk()["pulse"]): null changes nothing, two
## colours start the slot (+0x48), [] ends it (+0x4c) -- whoever set it.
static func apply_pulse(host: Node3D, event) -> void:
	if event == null or host == null or not is_instance_valid(host):
		return
	var tint: Array = event
	if tint.size() == 2:
		BodyPulse.start(host, tint[0], tint[1], PULSE_MS, WHO)
	else:
		BodyPulse.stop(host)

## Ends `host`'s colour when a state set it (OURS: a body's states dropped
## without a mask walk -- a death, a zone change, a world entry -- leave a
## colour berserk set to berserk, whose own end or drop ends it).
static func end_pulse(host: Node3D) -> void:
	if tinted(host):
		BodyPulse.stop(host)

## Whether `host` draws a state's colour now.
static func tinted(host: Node3D) -> bool:
	return BodyPulse.who(host) == WHO

## Every body's colour off (a world unload).
static func clear() -> void:
	BodyPulse.clear()
