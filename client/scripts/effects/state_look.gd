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
## - and, for some bits, the body (unless it is the player riding, +0x2c2 1,
##   or an object of kind 2, +0x448):
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

## What one mask change does, walked as FUN_009cd5e0 walks it. `state` is the
## body's look so far ({"tint": [] or [c1, c2], "speed": float,
## "frozen": bool}); returns {"on": [bits came on], "off": [bits went off],
## "tint", "speed", "frozen"} -- the look after the change -- and "pulse",
## the body's colour slot after the walk's events (round 855): null when no
## tinted bit changed (the slot is left as it is, whoever set it), [c1, c2]
## when the last event was a tinted bit coming on (+0x48), [] when it was one
## going off (+0x4c).
static func walk(old_mask: int, new_mask: int, state: Dictionary) -> Dictionary:
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
