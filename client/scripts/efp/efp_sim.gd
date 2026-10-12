extends RefCounted
class_name EfpSim

## The particle simulation of one playing .efp effect (round 620): the
## client's own per-frame rules, run over the typed tree EfpReader.decode
## returns. Pure data -- no nodes, no textures -- so the headless tests drive
## it on synthetic trees. EfpEffect draws what it holds.
##
## Round 763: native/src/core/efp_sim.rs is this file in Rust, rule for rule
## and bit for bit (EfpSimNative, EquipFx's masters). A change here is a change
## there: efp_native_test and client/tools/efp_native_parity.gd hold the two
## together.
##
## Every rule below is labelled. READ = read from sro_client.exe at the
## address given (docs/protocol/EFP_FORMAT.md, "Playback"); INFERRED = drawn
## from something READ or MEASURED with the reasoning given; OURS = a choice
## of this client where the binary was not read.
##
## == Time ==
## A frame is 50 ms (READ): the effect clock UI_ALCHEMYBOX::FUN_00bc1490
## adds the game's millisecond delta to an accumulator and, once it reaches
## 50, hands floor(acc / 50.0) frames (the double 50.0 at 0x00d8f0b0) to every
## effect's update (CRTModParticle::FUN_00c80ff0 -> CEFEffect::vslot_000 ->
## +0x28c). The delta is milliseconds: the game loop (funcs_017, FUN near
## 0x00ba4106) caps it at 3000 beside a float twin capped at 3.0 (INFERRED
## seconds). At >= 20 fps retail steps one frame per update; this client
## steps one frame per 50 ms of scene time.
##
## == Structure (READ, FUN_00c86cd0) ==
## A node is a particle system. Its StaticEmit spawns particles; spawning a
## particle also creates one emitter for each child node, owned by that
## particle, so a child node emits relative to each of its parent's particles.
## The root node's emitter is owned by the effect itself, whose age counts
## frames since the effect started.
##
## == Emission (READ, FUN_00c84e70 / FUN_00c87a20; EfpReader.emit_tick) ==
## The emitter frame is EfpReader.emit_tick, the reader's one copy of it: with
## t = owner age - delay, t >= duration stops the emitter; every `interval`
## frames a trigger adds `per_trigger` to a live-particle accumulator clamped
## to `max_live`, and int(new) - int(old) particles spawn; a particle of the
## emitter that dies takes 1.0 back off it. So (0,1,1,1,0.0) emits nothing and
## (0,20,1,20,1.0) adds one a frame up to 20 alive. The two quality globals
## (DAT_01114d54 interval multiplier, DAT_01114d58 threshold) are
## `interval_mul` / `threshold` below, 0 / 0 = full quality, their .bss start
## value (which option sets them in retail, and its default, is OPEN).
##
## == A particle's life (READ, the extinct executors) ==
## Its age counts frames from 0. NormalTimeExtinct (FUN_00c84e20): after the
## age passes N-1 the particle dies. NormalTimeLoop (FUN_00c84dd0): the age
## wraps modulo N. NeverExtinct (FUN_00c84d80): the age advances until it is
## 1 and then stays (`if age != 1: age += frames`), and a node whose N is 0
## kills the particle (the executor's `[def+0x7c] == 0` branch).
##
## == Dying, and the kept effect (READ, round 623) ==
## A death is QUEUED, not immediate: the executor clamps the age to N-1 and
## calls the particle's slot 3 (FUN_00c87ae0), which sets its dying flag
## (+0x30) and appends it to its node updater's death queue (updater +0x78,
## head +0xa0, FUN_00c87360). The particle stays in its node's list, so the
## draw after that update still draws it; the queue is flushed at the START
## of the node's next update (CEFUpdater::vslot_002, 0x00c85f28-0x00c85f5a:
## each queued particle's slot 1, CEFElement::vslot_001, refunds its
## emitter's 1.0, unlinks it and kills its child emitters). So a particle of
## N frames is drawn N times, and its emitter can replace it in the same
## update that removes it.
## The extinct executor is the node's +0x12c object, run LAST in the node's
## update, after its child updaters (the call at 0x00c8638b; the children
## at 0x00c86367, the program list at 0x00c86311); the emission (+0xb4 list,
## 0x00c84e70) and the program (+0x130 list, 0x00c84f90) run before them.
## A KEPT effect (the keep flag +0x49, set by IEasyFxEffect slot 4 with 1:
## AT_LOOP; round 785: not AT_STOP) never lets its ROOT node's particles die: after each
## update, CEFEffect::vslot_000 (0x00caf5ec-0x00caf622) walks the ROOT
## updater's death queue only, clears each particle's dying flag, sets its
## age to 0 and empties the queue. The particle lives on; its child
## emitters, which read its age, start their cycle again (below). A kept
## effect whose update finds no emitter able to spawn and no particle alive
## (FUN_00ca9ee0 returns 0) is released like any other (CRTModParticle::
## FUN_00c80ff0) -- the flag does not restart a finished effect.
##
## == An emitter's life (READ, 0x00c84e70 and CEFElement::vslot_001) ==
## Every frame the emission recomputes the emitter's "done" flag (+0x10,
## CEFGroup::vslot_003) from t = owner age - delay: 1 when t >= duration,
## else 0. It is not latched: an emitter whose owner's age goes back to 0
## (a kept root particle, or a NormalTimeLoop owner) emits again, with its
## accumulator as it was. An emitter goes only when its owner dies (the
## death kills the owner's child emitters, CEFElement::vslot_001).
##
## == The per-particle program (READ, EFEffect::FUN_00c893f0) ==
## Scheduling (READ, the loop at 0x00ca9276-0x00ca9354): a command's key i
## runs at frame ftol(f_i), where f_0 = start and f_{i+1} = f32(f_i + step),
## while f_i <= end -- a single-precision running sum, truncated by the fldcw
## at 0x00ca92b0. Value i of a Frame* parameter is key i.
## The command's `space` byte is added to its opcode by its factory (READ:
## FUN_00ca8140 registrations, e.g. SetConeVel = 0x3e + space), and the
## interpreter's switch gives each opcode its meaning:
##   position commands (SetPosition, SetConePos, SetBANPos): space = r*3 + o;
##     o: 0 add to the current position, 1 start from the parent particle's
##     position, 2 from the "link" object's; r: the value is rotated by 0 no
##     matrix, 1 the particle's own rotation, 2 the parent's, 3 the link's.
##   SetSpherePos: a point in the unit ball by rejection sampling of
##     (r - 0.5) * 2 from the 5000-entry random table. Space 1 / 2: the point
##     times the value, added to the parent's / link's position. Space 0
##     (0x00c8a4c5-0x00c8a5d4): the point is written straight INTO the
##     position, and then position += value * a stack vector the case never
##     sets. That vector is whatever an earlier command of the same frame's
##     run left there -- the cone cases, ConeForce, Attraction and SetSpherePos
##     itself write it -- and uninitialised when none did. This client keeps
##     that vector per particle run (`_scratch`) and starts it at zero (OURS
##     for the uninitialised case: 66 retail commands use space 0).
##   SetVelocity / SetConeVel: velocity = the value rotated by space 0 none,
##     1 own, 2 parent, 3 link. Force / ConeForce add the same to the velocity
##     (READ, the add at 0x00c8aae8). ConeForce space 0 (case 0x46) falls
##     through into case 0x47 (READ, 0x00c8ac1d -> 0x00c8ac23), so it adds a
##     second cone rotated by the particle's own rotation.
##   Attraction: velocity += normalize(pos - parent pos) * value (space 0),
##     the link's (space 1).
##   Cone (AngleVector1 {a, b}): the vector (0, lerp(b.x, b.y, r1), 0) turned
##     r2 * b.z about Z (IDecoSkill::FUN_00a4d820: FUN_00b44b40 fsin,
##     FUN_00b44a10 fcos) then r3 * 2*pi about Y (FUN_0043cda0). b.z is a.z in
##     radians in every retail value (MEASURED); that the trig takes b is
##     INFERRED.
##   SetRotation* / SetBANRot: rotation = M (space 0), M then own (1), M then
##     the parent's (2), then the link's (3). SetRVelocity*: the per-frame
##     rotation. SetShapeRot / SetShapeRotVel: the shape's rotation and its
##     per-frame step.
##   SetGraphScale: scale = the key's Vector3. SetGraphDiffuse: colour = the
##     key's D3DCOLOR. TextureSlide: the UV rectangle (u0, v0, du, dv) at
##     particle +0x22c = the key (READ, 0x00c8af77). Its head is unused here
##     (OPEN). SetGraphRandomScale: scale = the node's BlendScaleGraph at a
##     random time (FUN_00c89140: first key before a, last after b, linear
##     between; which var the pointer names is INFERRED to be the node's first
##     BlendScaleGraph).
##   The link (+0x34) is the particle the same emitter spawned before this
##     one that is still alive (READ, round 621: the emitter's particle list
##     at emitter+0x30 has prev offset 0x34 and next offset 0x38,
##     FUN_00c88320; the particle init FUN_00c88490 appends at the tail;
##     a death unlinks). Every variant that names the link does nothing
##     when the particle has none -- the oldest live one of its emitter
##     (READ: the interpreter tests +0x34 first in every such case; the
##     full list is names_link below and EFP_FORMAT.md "The link"). See
##     EfpLinks for the chain's drawing.
##
## == Motion per frame and the follow levels (READ, round 621: CEFUpdater::
## vslot_002, CEFGroup::vslot_004, the particle init FUN_00c88490) ==
## The node's 20-byte block (node +0x154..+0x16c) holds flags b0 b1 b5 b7
## and four follow LEVELS: u2 position (orbit), u3 rotation, u4 velocity,
## u6 translation. The emitter init turns a level N into an ancestor: 0 none,
## 1 the emitter's owner, N the owner N-1 more times up; the effect itself
## sits above the root node's particles, so level depth+1 is the effect.
## The levels are signed (READ: the walk compares `1 < level`, u3 `< 1` and
## `< 0`). MEASURED over the 95,801 retail nodes, read signed: no u2, u3, u4
## or u6 is above depth+1; the only negative value is u3 = -1, in 135 nodes
## of 101 files. A negative u3 names no ancestor and resets the inherited
## rotation at spawn (emitter +0x74); a negative u2/u4/u6 would name the
## owner (none in retail). Each frame, per particle, in
## node order (a node's particles, its commands, then its child nodes):
##   b0: old rotation (+0x64) = rotation; b1: old position (+0xa4) = position;
##   the "changed" flag (+0x60) clears;
##   u2 ancestor F, if F changed: position = (position - F.old) * F.delta + F.old;
##   u3 ancestor, if changed: rotation = rotation * its delta; changed = true;
##   u4 ancestor, if changed: velocity = velocity * its delta;
##   b5: rotation = rotation * rotation velocity; changed = true;
##   u6 ancestor A (every frame, no gate): position += A.position - A.old;
##   position += velocity; b7: shape = shape * shape velocity;
## then the node's commands run (every rotation command sets "changed",
## cases 0x00-0x03, 0x05-0x08, 0x0a-0x0d, 0x0f-0x12), and
## with b0 each particle's delta = inverse(old rotation) * rotation.
## MEASURED over the 95,801 retail nodes: an ancestor followed through u2 or
## u6 has b1 (so its old position is fresh) in 149,167 of 149,233 cases, and
## through u3/u4 has b0 in all 77,375; b5 is set exactly on the 423 nodes
## with a SetRVelocity command and b7 on the 31,138 with SetShapeRotVel.
## The effect (_root) is placed by set_origin() (READ: CEFEffect::vslot_008
## stores the position -- divided by the effect's scale -- and flags +0x28b;
## vslot_007 stores the matrix too and flags +0x60 and +0x28b). Its owner
## places it every frame, before the update (READ, round 785:
## CRTModParticle::FUN_00c81450 calls FUN_00c81190 -> vslot_007, then
## FUN_00c80ff0 -> the update, then the draw; a skill's decoration
## CIDecoSkill::vslot_014 places a following effect through
## IDecoSkill::FUN_00a4ddc0 -> vslot_007, then updates it). So in a frame
## with an update the update's follows carry the placement and
## CEFEffect::vslot_000 then stores it as old and clears both flags, and the
## draw runs no pass; in a frame without one the draw FUN_00cabda0 runs the
## follow pass FUN_00c863a0 with the placement's turn as the effect's delta,
## then stores the placement as old. One pass a frame either way: set_origin
## runs it at once, or leaves it to the step when one is due (`step_due`,
## round 785; round 621 ran both, so a frame with a step followed twice).
## It is "changed" only when the placement actually moved or turned (OURS:
## retail flags every placement; the same result, cheaper: on a still
## placement every ancestor's move and turn in the pass is zero, dead ones
## included, below).
## == Dead ancestors (READ, round 786 re-read; round 785 had them frozen) ==
## A particle is reference-counted: each child emitter (CEFGroup) made for it
## at its spawn holds it (FUN_00c86cd0: +1 per child node; released by
## CEFGroup::vslot_002, 0x00c879f0) and each particle holds its emitter
## (+1 at 0x00c8875e; released by CEFElement::vslot_002, 0x00c87aa0). The
## particle init (FUN_00c88490, 0x00c8874c-0x00c8878d) links a newborn into
## four lists: its node updater's MOTION list (updater +0xb0: head +0xd8,
## next offset at +0xc8), its emitter's list (+0x30), the updater's executor
## list (+0x48: head +0x70, next offset at +0x60; the commands 0x00c84f90,
## the ages 0x00c84e20/0x00c84d80 walk it) and the effect's draw list
## (+0x258). A death (CEFElement::vslot_001, 0x00c87a20) unlinks it from
## three of them -- draw (0x00c87a3c), executors (0x00c87a4e), emitter
## (0x00c87a5a) -- kills its child emitters and sets its dead flag (+4); it
## leaves the MOTION list only when it is released (0x00c87aa0: the unlink
## at 0x00c87aaa, updater +0xb0), i.e. when no child emitter of it still
## has a particle. The motion pass (CEFUpdater::vslot_002 0x00c85fa0-
## 0x00c862ff, the draw's FUN_00c863a0, the shift FUN_00c865a0) walks that
## list with no test of the dead or dying flags. So a dead particle that
## still has descendants is not frozen: every pass it stores its old
## position (b1) and rotation (b0), follows its own ancestors (u2 / u3 / u4 /
## u6), turns by its rotation velocity (b5), moves by its velocity (last
## value: no command changes it any more) and its turn (delta) is
## recomputed -- it is only not drawn, aged or commanded. Its followers'
## `pos += A.pos - A.old` therefore carries what the dead holder does now:
## the body's motion through the holder's own follows, not a frozen last
## move. (Round 785 read "out of every list, its state frozen", and so had
## orphans keep the host's last move after it stopped -- the rings left
## behind the user reported; round 621 stopped following a dead ancestor,
## leaving them where it died. Both OURS.) This client keeps every particle
## still in memory in `_order` (live, dying, and dead with a live
## descendant, in spawn order): the step's and the pass's motion walk it,
## the commands, ages, draws and counts walk `particles` (live and dying).
## Retail updates node by node (a node's particles move, then its commands
## run, then its child nodes); this client runs each particle's motion,
## commands and turn in spawn order, which also finishes every ancestor
## before its followers (OURS order, same dependencies).
## So a particle whose node follows nothing (u6 = 0) stays where it was
## born in the effect's space while the effect moves: the trails.
## At spawn (READ, FUN_00c88490): position = the owner's position, velocity
## = the owner's velocity minus the u6 ancestor's, rotation = the owner's
## (identity with a negative u3), scale 1, colour 0xFFFFFFFF, UV rectangle
## (0, 0, 1, 1). Retail also offsets the position by (A.old - A.position)
## for the follow pass that runs after its spawn; this client spawns after
## the step's follows, so it does not (OURS, same result).
##
## == Order within a frame (OURS where retail's order was not read) ==
## 0 the deaths queued last frame are flushed (READ, see "Dying"), 1 motion,
## 2 each particle's commands for its age, 3 emission (new particles run
## their frame-0 commands at once, so none is drawn at its parent's origin
## first), 4 ages advance and deaths are queued (READ: last, after every
## node's emission and program), and a kept effect revives its root
## particles.
##
## == Caps (OURS) ==
## MAX_PARTICLES per effect. Across all live effects, MAX_TOTAL - RESERVE
## for everyone else's effects and the full MAX_TOTAL for `reserved` ones
## (the local player's casts, hits and level-up), so a crowd's auras cannot
## starve the player's own effects. A refused spawn is counted in `dropped`
## and gives its 1.0 back to the emitter. Retail has none of these (READ,
## round 761: its particles come from a free list that grows by 8,192 and
## never refuses, and nothing counts them); its one crowd thinning is per
## character, effects frozen past a camera distance (docs/rounds/r761.md).
## USER DECISION 2026-10-09 (round 763): when EquipFx's masters simulate in
## Rust (EfpSimNative) they have no global cap, as retail; they count their
## own particles (EfpSimNative.live_native), so this cap -- kept for every
## GDScript effect, the masters' fallback included -- neither counts nor
## refuses them.

const FRAME_SEC := 0.05 ## READ: 50 ms, see the header
const MAX_STEPS_PER_ADVANCE := 10 ## OURS: a long hitch catches up at most 0.5 s
const MAX_PARTICLES := 300 ## OURS
const MAX_TOTAL := 2000 ## OURS: ~7 us a particle-frame in GDScript (MEASURED), so <= ~14 ms a 50 ms frame
const RESERVE := 600 ## OURS: of MAX_TOTAL, kept for reserved (own) effects
const MAX_KEYS := 100000 ## OURS: bound on one command's scheduling loop
## Round 761: growth_bounds' ceiling on a spawn count (far above MAX_PARTICLES;
## keeps the products in range).
const FAN_MAX := 1 << 20

const LIFE_EXTINCT := 0
const LIFE_LOOP := 1
const LIFE_NEVER := 2

## The number of particles alive across every EfpSim (the global cap).
static var live_total := 0
## Round 761 (QA): the cap in force, MAX_TOTAL unless OPENSRO_QA_EFP_CAP
## names another (0: no global cap), for measuring what the cap saves.
static var cap_total := _qa_cap()

static func _qa_cap() -> int:
	var v := OS.get_environment("OPENSRO_QA_EFP_CAP")
	if v == "" or not v.is_valid_int():
		return MAX_TOTAL
	return int(v) if int(v) > 0 else 1 << 30

## The global cap an effect's spawn is held to: cap_total for a reserved
## effect, cap_total - RESERVE for any other.
static func limit_for(is_reserved: bool) -> int:
	return cap_total if is_reserved else cap_total - RESERVE
## The emission quality globals handed to EfpReader.emit_tick (see above).
static var interval_mul := 0
static var threshold := 0

## Opcode bases (READ: the FUN_00ca8140 factory registrations add the command's
## space byte to these).
const OP_BASE := {
	"SetRotationMat": 0x00, "SetRVelocityMat": 0x04, "SetRotation": 0x05,
	"SetRVelocity": 0x09, "SetRotationAxis": 0x0a, "SetRVelocityAxis": 0x0e,
	"SetBANRot": 0x0f, "SetPosition": 0x13, "SetConePos": 0x1f,
	"SetBANPos": 0x2b, "SetSpherePos": 0x37, "SetVelocity": 0x3a,
	"SetConeVel": 0x3e, "Force": 0x42, "ConeForce": 0x46, "Attraction": 0x4a,
	"TextureSlide": 0x4c, "SetGraphScale": 0x4d, "SetGraphRandomScale": 0x4e,
	"SetGraphDiffuse": 0x4f, "SetShapeRot": 0x50, "SetShapeRotVel": 0x51,
}

# The command families _run dispatches on (compiled once, not a string match
# per particle per frame).
enum { K_POS, K_CONEPOS, K_BANPOS, K_SPHERE, K_VEL, K_CONEVEL, K_FORCE, K_CONEFORCE,
	K_ATTRACT, K_ROT, K_BANROT, K_RVEL, K_SHAPE, K_SHAPEVEL, K_SCALE, K_DIFFUSE, K_SLIDE,
	K_RANDSCALE }
const KIND := {
	"SetPosition": K_POS, "SetConePos": K_CONEPOS, "SetBANPos": K_BANPOS,
	"SetSpherePos": K_SPHERE, "SetVelocity": K_VEL, "SetConeVel": K_CONEVEL,
	"Force": K_FORCE, "ConeForce": K_CONEFORCE, "Attraction": K_ATTRACT,
	"SetRotationMat": K_ROT, "SetRotation": K_ROT, "SetRotationAxis": K_ROT,
	"SetBANRot": K_BANROT, "SetRVelocityMat": K_RVEL, "SetRVelocity": K_RVEL,
	"SetRVelocityAxis": K_RVEL, "SetShapeRot": K_SHAPE, "SetShapeRotVel": K_SHAPEVEL,
	"SetGraphScale": K_SCALE, "SetGraphDiffuse": K_DIFFUSE, "TextureSlide": K_SLIDE,
	"SetGraphRandomScale": K_RANDSCALE,
}

## One node, compiled once per file and shared by every playing copy.
class Tpl:
	var node: EfpReader.EfpNode
	var index: int
	var parent: int = -1 ## -1 for the root (owned by the effect)
	var children: Array[int] = []
	var frames: int
	var life: int
	var emit = null ## {delay, duration, interval, max_live, per_trigger} or null
	## The emitter's five values as ints / a float, read once (round 623's
	## review: the per-frame tick allocated a Dictionary per emitter).
	var e_delay := 0
	var e_dur := 0
	var e_int := 0
	var e_max := 0
	var e_per := 0.0
	var schedule: Array = [] ## frame -> Array of [kind, space, payload] (see _payload)
	var scale_graph = null ## the node's first BlendScaleGraph var, or null
	## The follow levels and flags of the node's 20-byte block (READ, see the header).
	var lv_orbit := 0 ## u2
	var lv_rot := 0 ## u3 (negative: reset the inherited rotation)
	var lv_vel := 0 ## u4
	var lv_move := 0 ## u6
	var keep_rot := false ## b0
	var keep_pos := false ## b1
	var follows_any := false ## any level names an ancestor (the fast path skips the follows)
	var pos_read := false ## a follower reads this node's old position (u2/u6)
	var rot_read := false ## ... or its turn (u2/u3/u4)
	var unsupported: PackedStringArray = PackedStringArray()

## A compiled effect: the node templates in preorder (parents first).
class Template:
	var tpls: Array[Tpl] = []
	var unsupported: PackedStringArray = PackedStringArray() ## names no rule covers
	## Round 761 (growth_bounds), per node: `rate`, at most how many
	## particles one of its emitters spawns in one frame; `kids`, at most how
	## many a newborn of it makes spawn in the same frame (its children's
	## emitters, recursively); `fan` = rate x (1 + kids), one emitter's frame
	## all told. `fan_child`: the largest `kids`, what a newborn's emitters add
	## per later frame. Filled by compile(); a Template built otherwise leaves
	## them empty and gets the loose bound.
	var rate: PackedInt32Array = PackedInt32Array()
	var kids: PackedInt32Array = PackedInt32Array()
	var fan: PackedInt32Array = PackedInt32Array()
	var fan_child := 0
	## Round 763: the template compiled for the native simulation
	## (EfpSimNative.native_template: an SrEfpTemplate), made on first use;
	## `native_tried` once it was tried (a null `native` then: this template
	## stays GDScript, for the reason in `native_error`).
	var native: Object = null
	var native_tried := false
	var native_error := ""

class Particle:
	var tpl: int
	var emitter: Emitter ## the emitter that spawned it (its death refunds acc)
	var parent: Particle ## null for the effect's own root holder
	var age: int = 0
	var alive := true
	## Queued to die (+0x30): still drawn, flushed at the next step's start.
	var dying := false
	var pos := Vector3.ZERO
	var vel := Vector3.ZERO
	var rot := Basis.IDENTITY
	var rvel := Basis.IDENTITY
	var shape := Basis.IDENTITY
	var shape_vel := Basis.IDENTITY
	var has_rvel := false
	var has_shape_vel := false
	var scale := Vector3.ONE
	var color := 0xFFFFFFFF
	var uv := Vector4(0, 0, 1, 1)
	## The emitter's previous live particle (+0x34) and next one (+0x38).
	var link: Particle = null
	var next_link: Particle = null
	## The follow state (READ, see the header): old position (+0xa4), old
	## rotation / this frame's turn (+0x64), changed (+0x60), and the
	## ancestors the node's levels name.
	var old_pos := Vector3.ZERO
	var old_rot := Basis.IDENTITY
	var delta := Basis.IDENTITY
	var changed := false
	var f_orbit: Particle = null
	var f_rot: Particle = null
	var f_vel: Particle = null
	var f_move: Particle = null
	## Round 786: scratch for _flush_deaths -- a live descendant holds it.
	var held := false

class Emitter:
	var tpl: int
	var owner: Particle
	var acc := 0.0
	## This frame's "done" (+0x10): recomputed every frame (READ, 0x00c84e70),
	## latched only for a node with no StaticEmit.
	var done := false
	## The newest live particle of this emitter (the list's tail).
	var tail: Particle = null
	## Round 761 (growth_bounds): its particles queued to die, each of whose
	## deaths will give 1.0 back to `acc` at the next flush.
	var dying := 0

var template: Template
var particles: Array[Particle] = []
var emitters: Array[Emitter] = []
var age := 0 ## the effect's own age, in frames
var dropped := 0 ## spawns refused by a cap
var spawned := 0
## The local player's own effect: may use the RESERVE share of MAX_TOTAL.
var reserved := false
## The kept flag (+0x49; AT_LOOP): the root node's particles are
## revived at age 0 instead of dying (READ, see "Dying, and the kept effect").
var keep := false
## How many times a kept effect revived a root particle (tests, census).
var revived := 0
var _root := Particle.new() ## the effect's origin: owner of the root emitter
var _acc := 0.0
var _rng := RandomNumberGenerator.new()
var _scratch := Vector3.ZERO ## the interpreter's stack vector (see SetSpherePos)
## Round 759 (EfpSimBatch): while stepped on a pool thread, this sim does not
## touch the shared `live_total`: its spawns and deaths go to `_live_delta`,
## and end_deferred() hands the delta back on the main thread. Round 761: the
## cap is decided as the main thread decides it, `live_total < limit` with
## live_total what it would be had the effects before this one in the batch
## all advanced first (EfpSimBatch.Job.admit): a spawn at own delta d is
## surely taken while d < `_sure_below` and surely refused from
## `_sure_from` on; between the two the gate (`_gate`, the batch's Job) is
## asked, and waits for the effects before this one when it must.
var _deferred := false
var _gate: Object = null
var _gate_index := 0
var _sure_below := 0
var _sure_from := 0
var _live_delta := 0
## Round 761: the particles queued to die (growth_bounds).
var _dying_n := 0
## Round 786 (READ, see "Dead ancestors" in the header): every particle
## still in memory, in spawn order -- the live and dying ones of `particles`
## and the dead ones a live descendant still holds -- which the motion of a
## step and of a pass walks, as retail's node motion list (updater +0xb0).
var _order: Array[Particle] = []

## Compiles a decoded file (or its root node) into a template. Unsupported
## command names are listed, not fatal.
static func compile(root: EfpReader.EfpNode) -> Template:
	var t := Template.new()
	if root == null:
		return t
	_compile_node(t, root, -1)
	# Which nodes a follower reads (OURS, a saving with the same result):
	# only those need their old position / rotation kept and their turn
	# computed each frame.
	for tp in t.tpls:
		for pair in [[tp.lv_orbit, 3], [tp.lv_move, 1], [rot_level(tp.lv_rot), 2], [tp.lv_vel, 2]]:
			var a := _tpl_ancestor(t, tp.index, int(pair[0]))
			if a >= 0:
				var k: int = pair[1]
				if k & 1:
					t.tpls[a].pos_read = true
				if k & 2:
					t.tpls[a].rot_read = true
	for tp in t.tpls:
		tp.keep_pos = tp.keep_pos and tp.pos_read
		tp.keep_rot = tp.keep_rot and tp.rot_read
	_compile_fan(t)
	return t

## Round 761: Template.rate, kids, fan and fan_child (growth_bounds). An
## emitter spawns ftol(min(per_trigger + acc, cap)) - ftol(acc) a frame
## (emit_spawns), at least 0: none without StaticEmit or an interval, none
## with per_trigger <= 0 (acc only falls) or max_live <= 0 (the cap is 0 or
## below); else acc stays in [0, cap], so at most max_live, and at most
## ftol(per_trigger) + 2 (the float32 sum can round across one more
## integer). Out of the plain range (NaN, above 2^24) the bound is FAN_MAX.
## Each newborn starts its children's emitters, which may spawn in the same
## frame (the emission loop runs the emitters appended during it). Preorder
## puts children after parents, so one pass from the end.
static func _compile_fan(t: Template) -> void:
	var n := t.tpls.size()
	t.rate.resize(n)
	t.kids.resize(n)
	t.fan.resize(n)
	t.fan_child = 0
	for idx in range(n - 1, -1, -1):
		var tp: Tpl = t.tpls[idx]
		var kids := 0
		for k in tp.children:
			kids = mini(kids + t.fan[k], FAN_MAX)
		t.fan_child = maxi(t.fan_child, kids)
		var r := 0
		if tp.emit != null and tp.e_int > 0:
			if is_nan(tp.e_per) or tp.e_per > 16777216.0 or tp.e_max > 16777216:
				r = FAN_MAX
			elif tp.e_per > 0.0 and tp.e_max > 0:
				r = mini(int(tp.e_per) + 2, tp.e_max)
		t.rate[idx] = r
		t.kids[idx] = kids
		t.fan[idx] = mini(r * (1 + kids), FAN_MAX)

## The node `level` levels above node `i` (-1: none, or the effect).
static func _tpl_ancestor(t: Template, i: int, level: int) -> int:
	if level == 0:
		return -1
	var a := t.tpls[i].parent
	var k := level - 1
	while k > 0 and a >= 0:
		a = t.tpls[a].parent
		k -= 1
	return a

static func _compile_node(t: Template, n: EfpReader.EfpNode, parent: int) -> void:
	var tp := Tpl.new()
	tp.node = n
	tp.index = t.tpls.size()
	tp.parent = parent
	tp.frames = maxi(n.frames, 0)
	tp.life = LIFE_LOOP if n.loops() else (LIFE_NEVER if n.never_extinct() else LIFE_EXTINCT)
	tp.emit = n.emission()
	if tp.emit is Dictionary:
		tp.e_delay = int(tp.emit["delay"])
		tp.e_dur = EfpReader.i32(int(tp.emit["duration"]))
		tp.e_int = EfpReader.i32(int(tp.emit["interval"]))
		tp.e_max = EfpReader.i32(int(tp.emit["max_live"]))
		tp.e_per = float(tp.emit["per_trigger"])
	# A node without the block (synthetic trees) follows its parent's
	# translation, round 620's behaviour (OURS default); retail always has it.
	var fl: Dictionary = n.flags
	# The reader keeps these as u32 (its dump matches the Go reader's); the
	# emitter init compares them SIGNED (READ, CEFGroup::vslot_004: `u3 < 1`,
	# `u3 < 0`, `1 < level`), and retail stores u3 = -1 in 135 nodes of 101
	# files (MEASURED).
	tp.lv_orbit = signed32(int(fl.get("u2", 0)))
	tp.lv_rot = signed32(int(fl.get("u3", 0)))
	tp.lv_vel = signed32(int(fl.get("u4", 0)))
	tp.lv_move = signed32(int(fl.get("u6", 1 if fl.is_empty() else 0)))
	tp.follows_any = tp.lv_orbit != 0 or tp.lv_rot > 0 or tp.lv_vel != 0 or tp.lv_move != 0
	tp.keep_rot = int(fl.get("b0", 0)) != 0
	tp.keep_pos = int(fl.get("b1", 0)) != 0 or fl.is_empty()
	for v in n.vars:
		if v is Dictionary and String(v.get("type", "")) == "BlendScaleGraph" and tp.scale_graph == null:
			tp.scale_graph = v.get("value")
	tp.schedule.resize(tp.frames)
	for f in range(tp.frames):
		tp.schedule[f] = []
	for c in n.commands:
		if not KIND.has(c.name):
			if not tp.unsupported.has(c.name):
				tp.unsupported.append(c.name)
			if not t.unsupported.has(c.name):
				t.unsupported.append(c.name)
			continue
		var kind: int = KIND[c.name]
		for pair in key_frames(c, tp.frames):
			var pl = _payload(kind, c, int(pair[1]))
			if pl == null:
				continue
			(tp.schedule[int(pair[0])] as Array).append([kind, int(c.space), pl])
	t.tpls.append(tp)
	if parent >= 0:
		t.tpls[parent].children.append(tp.index)
	for k in n.children:
		_compile_node(t, k, tp.index)

## The value one key of a command runs with, resolved once at compile time
## so the per-particle loop does no dictionary or key lookups: a Vector3, a
## Basis, a colour int, a Vector4, the cone's b Vector3, or true; null when
## the key has no value (the command then does nothing, as before).
static func _payload(kind: int, c: EfpReader.EfpCommand, key: int):
	var val = c.value
	if not (val is Dictionary):
		return true if kind == K_RANDSCALE else null
	match kind:
		K_POS, K_SPHERE, K_VEL, K_FORCE:
			return val.get("value", Vector3.ZERO)
		K_CONEPOS, K_CONEVEL, K_CONEFORCE:
			return val.get("b", Vector3.ZERO)
		K_BANPOS:
			var ps: PackedVector3Array = val.get("positions", PackedVector3Array())
			return ps[key] if key < ps.size() else null
		K_ATTRACT:
			return float(val.get("value", 0.0))
		K_ROT, K_RVEL, K_SHAPE, K_SHAPEVEL:
			return basis_of(val.get("matrix"))
		K_BANROT:
			var ms: Array = val.get("matrices", [])
			return basis_of(ms[key]) if key < ms.size() else null
		K_SCALE:
			var fs: PackedVector3Array = val.get("frames", PackedVector3Array())
			return fs[key] if key < fs.size() else null
		K_DIFFUSE:
			var cs: PackedInt64Array = val.get("colors", PackedInt64Array())
			return cs[key] if key < cs.size() else null
		K_SLIDE:
			var ks: Array = val.get("keys", [])
			return ks[key] if key < ks.size() else null
		K_RANDSCALE:
			return true
	return null

## [frame, key] pairs a command runs at over a program of n frames (READ, the
## scheduling loop: see the header). Frames outside [0, n) are dropped.
static func key_frames(c: EfpReader.EfpCommand, n: int) -> Array:
	var out: Array = []
	var fr := c.frame_range(n)
	if not bool(fr["ok"]):
		return out
	var st := EfpReader.f32(float(fr["step"]))
	var endf := float(int(fr["end"]))
	var f := EfpReader.f32(float(int(fr["start"])))
	var key := 0
	while f <= endf and key < MAX_KEYS:
		var fi := EfpReader.ftol(f)
		if fi >= 0 and fi < n:
			out.append([fi, key])
		key += 1
		var nf := EfpReader.f32(f + st)
		if nf <= f:
			break
		f = nf
	return out

func _init(tmpl: Template = null, seed_value: int = 0) -> void:
	template = tmpl
	if seed_value != 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()
	restart()

## Starts the effect over: no particles, the root emitter fresh.
func restart() -> void:
	clear()
	age = 0
	dropped = 0
	_acc = 0.0
	if template != null and not template.tpls.is_empty():
		var e := Emitter.new()
		e.tpl = 0
		e.owner = _root
		emitters.append(e)

## Round 759 (EfpSimBatch): the next advance() may run off the main thread.
## Round 761: `gate` (EfpSimBatch.Job) decides the global cap for it, as
## effect `index` of the batch's ordered list; nothing is sure until it says.
func begin_deferred(gate: Object, index: int) -> void:
	_deferred = true
	_gate = gate
	_gate_index = index
	_live_delta = 0
	_sure_below = -FAN_MAX
	_sure_from = FAN_MAX

## Back on the main thread: its particles counted in `live_total` again.
func end_deferred() -> void:
	_deferred = false
	_gate = null
	live_total += _live_delta
	_live_delta = 0

## Round 761 (EfpSimBatch): bounds on how much advance(delta) can change this
## sim's particle count, Vector2i(least, most), from its state now and
## without changing it -- so an effect later in a batch knows, before this
## one has finished, whether the cap can bind for it. Sound by construction
## (efp_sim_batch_test holds it against the real deltas):
## - the steps are advance()'s own count (the same float arithmetic);
## - in one step only the particles queued to die die (the flush at its
##   start; a death queued in the step goes at the next), in more any of them;
## - spawns: in the first step, each emitter whose owner survives the flush
##   and whose timing fires this frame (emit_spawns' tests, the owner's age
##   unchanged until after the emission) spawns at most its node's `fan`; in
##   each later step every surviving emitter may, and every particle spawned
##   so far adds at most `fan_child` more;
## - the count never passes MAX_PARTICLES.
func growth_bounds(delta: float) -> Vector2i:
	var steps := 0
	var a := _acc + maxf(delta, 0.0)
	while a >= FRAME_SEC and steps < MAX_STEPS_PER_ADVANCE:
		a -= FRAME_SEC
		steps += 1
	if steps == 0 or template == null or template.tpls.is_empty():
		return Vector2i.ZERO
	var c := particles.size()
	var dying := _dying_n
	var least := -dying if steps == 1 else -c
	var most := MAX_PARTICLES - c
	var fan := template.fan
	if fan.size() != template.tpls.size():
		return Vector2i(least, most)
	var tpls := template.tpls
	var rate := template.rate
	var kids := template.kids
	var first := 0
	var every := 0
	for e in emitters:
		var f: int = fan[e.tpl]
		if f == 0:
			continue
		var owner := e.owner
		if owner != _root and owner.dying:
			continue
		every = mini(every + f, FAN_MAX)
		# emit_spawns' timing (its tests in its order, EfpReader.i32 inline:
		# on the pool's threads a GDScript call costs more than the
		# arithmetic, round 761's bench).
		var tp: Tpl = tpls[e.tpl]
		var t := (((age if owner == _root else owner.age) - tp.e_delay + 0x80000000) & 0xFFFFFFFF) - 0x80000000
		if t >= tp.e_dur or t < 0 or tp.e_int <= 0:
			continue
		var interval := tp.e_int
		if interval_mul > 1:
			var m := ((interval * interval_mul + 0x80000000) & 0xFFFFFFFF) - 0x80000000
			if m < tp.e_dur:
				interval = m
		# Round 763's review, L4: the multiplied interval can wrap to 0 or below.
		if interval <= 0 or t % interval != 0:
			continue
		# What fits under the cap above acc after the flush's give-backs
		# (each max(acc - 1, 0): max(acc - dying, 0) in all): emit_spawns
		# returns ftol(nxt) - ftol(acc) with nxt <= cap <= max_live.
		var r: int = rate[e.tpl]
		if r < FAN_MAX and e.acc >= 0.0 and e.acc < 16777216.0:
			r = mini(r, maxi(tp.e_max - int(maxf(e.acc - float(e.dying), 0.0)), 0))
		first = mini(first + r * (1 + kids[e.tpl]), FAN_MAX)
	var spawns := first
	for _s in range(1, steps):
		spawns = mini(spawns + every + spawns * template.fan_child, FAN_MAX)
	return Vector2i(least, mini(most, spawns - dying))

## Round 763: how many particles are alive (EfpSimNative answers from its
## native state, where `particles` stays empty).
func count() -> int:
	return particles.size()

## Round 763: the particles as objects (EfpSimNative builds a snapshot): the
## QA log and tests.
func particle_list() -> Array[Particle]:
	return particles

## Round 762's review (EquipFx): the step clock's phase, so masters made
## together do not step in the same rendered frame.
func set_phase(acc: float) -> void:
	_acc = acc

func _live_add(n: int) -> void:
	if _deferred:
		_live_delta += n
	else:
		live_total += n

## Drops every particle (and its share of the global count) and every
## emitter: the effect is finished.
func clear() -> void:
	for p in _order:
		if p.alive:
			_live_add(-1)
			p.alive = false
		# Break the link/next_link pairs: Particle is RefCounted, so a
		# chain left linked would keep itself alive (round 621).
		p.link = null
		p.next_link = null
		if p.emitter != null:
			p.emitter.tail = null
	for e in emitters:
		e.tail = null
	particles.clear()
	_order.clear()
	emitters.clear()
	_dying_n = 0

## True once nothing is alive (a particle queued to die still counts) and
## no emitter spawns this frame -- FUN_00ca9ee0's test: every root emitter
## done and no particle left.
func finished() -> bool:
	if not particles.is_empty():
		return false
	for e in emitters:
		if not e.done:
			return false
	return true

## Advances by `delta` seconds of scene time, one frame per 50 ms. Returns
## the frames stepped.
func advance(delta: float) -> int:
	_acc += maxf(delta, 0.0)
	var n := 0
	while _acc >= FRAME_SEC and n < MAX_STEPS_PER_ADVANCE:
		_acc -= FRAME_SEC
		step()
		n += 1
	if n == MAX_STEPS_PER_ADVANCE:
		_acc = minf(_acc, FRAME_SEC)
	return n

## Round 785: whether advance(delta) will step at least one frame (its own
## arithmetic): the placement is then left to the step (set_origin's
## `step_due`), as retail's update follows the effect's placement in the
## same frame and its draw does not.
func step_due(delta: float) -> bool:
	return _acc + maxf(delta, 0.0) >= FRAME_SEC

## Round 785: true once after a pass on a frame without a step moved a
## follower of a frozen dead ancestor. Round 786: a dead ancestor is not
## frozen (it follows the placement itself, see the header), so a still
## frame's pass moves nothing and none runs: always false (kept for
## EfpEffect and the native interface).
func take_pass_moved() -> bool:
	return false

## One 50 ms frame.
func step() -> void:
	if template == null:
		return
	var tpls := template.tpls
	# 0 last frame's queued deaths go now (READ: the updater flushes its
	# death queue first), and the emitters of the dead with them.
	_flush_deaths()
	# Round 785: the effect is not reset here. A placement made for this
	# frame (set_origin with step_due) is still pending -- the effect's
	# position against its old one, its turn as its delta -- and this step's
	# follows carry it, as retail's update follows the placement its owner
	# made before it in the same frame (READ, see the header); the effect's
	# old state is stored at the end of the step (_end_root).
	# 1-2 each particle moves and follows, runs its commands, then notes this
	# frame's turn -- in spawn order, so every ancestor (spawned earlier)
	# has finished its frame before a particle follows it, as retail's
	# node-by-node order guarantees (READ order, see the header). Round 786:
	# a dead particle still held moves too (retail's motion list), but runs
	# no commands (out of the executor list, READ, see "Dead ancestors").
	for p in _order:
		var tp: Tpl = tpls[p.tpl]
		if tp.keep_rot:
			p.old_rot = p.rot
		if tp.keep_pos:
			p.old_pos = p.pos
		p.changed = false
		if p.has_rvel:
			# retail's order with b5: u2, u3, u4, then the rotation velocity,
			# then u6 (READ, see the header).
			if tp.follows_any:
				var f := p.f_orbit
				if f != null and f.changed:
					p.pos = f.delta * (p.pos - f.old_pos) + f.old_pos
				f = p.f_rot
				if f != null and f.changed:
					p.rot = f.delta * p.rot
					p.changed = true
				f = p.f_vel
				if f != null and f.changed:
					p.vel = f.delta * p.vel
			p.rot = p.rvel * p.rot
			p.changed = true
			var m := p.f_move
			if m != null:
				p.pos += m.pos - m.old_pos
		elif tp.follows_any:
			_follow(p)
		p.pos += p.vel
		if p.has_shape_vel:
			p.shape = p.shape_vel * p.shape
		var sched: Array = tp.schedule
		if p.alive and p.age >= 0 and p.age < sched.size():
			var cmds: Array = sched[p.age]
			if not cmds.is_empty():
				_run_list(p, tp, cmds)
		if tp.keep_rot and p.changed:
			p.delta = p.rot * p.old_rot.inverse()
	# 3 emission (the list grows as particles spawn child emitters)
	var i := 0
	while i < emitters.size():
		_emit(emitters[i])
		i += 1
	# 4 ages advance (newborns included: their frame 0 has run); a particle
	# whose life is over is queued to die (READ, see "Dying"): it is still
	# drawn this frame and goes at the next step's start.
	for p in particles:
		var tp: Tpl = tpls[p.tpl]
		var dies := false
		match tp.life:
			LIFE_EXTINCT:
				p.age += 1
				if p.age >= tp.frames:
					p.age = maxi(tp.frames - 1, 0)
					dies = true
			LIFE_LOOP:
				p.age += 1
				if tp.frames > 0:
					p.age %= tp.frames
			LIFE_NEVER:
				if p.age != 1:
					p.age += 1
				if tp.frames == 0:
					dies = true
		if not dies:
			continue
		if keep and p.parent == _root:
			# READ, CEFEffect::vslot_000: a kept effect's root particle is
			# revived -- dying flag cleared, age 0 -- so it never dies.
			p.age = 0
			revived += 1
		else:
			p.dying = true
			_dying_n += 1
			if p.emitter != null:
				p.emitter.dying += 1
	age += 1
	_end_root()

## Removes the particles queued to die last frame (READ: the start of
## CEFUpdater::vslot_002) and the emitters their deaths kill (READ:
## CEFElement::vslot_001 kills the particle's child emitters). Round 786: a
## dead particle stays in `_order` -- still moving -- while a live
## descendant holds it, and goes when the last one dies (READ: released
## at reference count 0, see "Dead ancestors").
func _flush_deaths() -> void:
	var any := false
	for p in particles:
		if p.dying:
			any = true
			break
	if not any:
		return
	var kept: Array[Particle] = []
	for p in particles:
		if p.dying:
			p.alive = false
			_on_death(p)
		else:
			kept.append(p)
	particles = kept
	# Which dead particles are still held: walked newest first, so every
	# descendant (spawned after its ancestors) is seen before them.
	for p in _order:
		p.held = false
	var order: Array[Particle] = []
	for i in range(_order.size() - 1, -1, -1):
		var p: Particle = _order[i]
		if p.alive or p.held:
			order.append(p)
			if p.parent != null:
				p.parent.held = true
	order.reverse()
	_order = order
	var live_emitters: Array[Emitter] = []
	for e in emitters:
		if e.owner == _root or e.owner.alive:
			e.dying = 0
			live_emitters.append(e)
	emitters = live_emitters
	_dying_n = 0

## The end of a step for the effect (_root): its placement is now its old
## one and it has not changed (READ: CEFEffect::vslot_000, after the
## update, copies the effect's rotation and position to their old slots and
## clears its flags, so the draw that follows the update runs no pass).
func _end_root() -> void:
	_root.old_pos = _root.pos
	_root.old_rot = _root.rot
	_root.changed = false

## Places the effect in its own simulation space -- where its host (or
## bone) is now, and how it is turned. Retail's owner places the effect on
## every frame (CEFEffect::vslot_007 / vslot_008 flag it), and in that frame
## either the update follows the placement (CEFEffect::vslot_000 runs the
## tree with the effect's new position against its old one, then stores it
## as old and clears the flags) or, on a frame without an update, the draw
## runs the follow pass (READ: FUN_00cabda0 -> FUN_00c863a0): each particle
## keeps its old state, clears "changed", and takes its u2 / u3 / u4 follows
## (if the ancestor changed) and its u6 translation, in spawn order; no
## velocity, no rotation velocity, no commands. So a particle following the
## effect moves with its host every render frame, once.
## Round 785: `step_due` (EfpEffect: the advance that follows in this frame
## will step) leaves the placement to that step, as retail's update takes it
## and its draw then runs no pass; without it the pass runs now. A placement
## that neither moved nor turned the effect needs no pass (the same result:
## OURS, retail flags every placement: on a still placement every move and
## turn in the pass is zero, a dead ancestor's included -- round 786).
## Returns whether anything moved.
func set_origin(pos: Vector3, rot: Basis = Basis.IDENTITY, step_due: bool = false) -> bool:
	var moved := not (pos.is_equal_approx(_root.old_pos) and rot.is_equal_approx(_root.old_rot))
	_root.pos = pos
	_root.rot = rot
	_root.changed = moved
	if moved:
		_root.delta = rot * _root.old_rot.inverse()
	if step_due or not moved:
		return moved
	_pass()
	return true

## The follow pass on a frame without a step (see set_origin), and the end
## of it for the effect. False when there was nothing to move.
func _pass() -> bool:
	var ran := false
	if template != null and not _order.is_empty():
		ran = true
		var tpls := template.tpls
		# Round 786: the held dead too (retail's motion list, READ).
		for p in _order:
			var tp: Tpl = tpls[p.tpl]
			if tp.keep_rot:
				p.old_rot = p.rot
			if tp.keep_pos:
				p.old_pos = p.pos
			p.changed = false
			if not tp.follows_any:
				continue
			_follow(p)
			if tp.keep_rot and p.changed:
				p.delta = p.rot * p.old_rot.inverse()
	_root.old_pos = _root.pos
	_root.old_rot = _root.rot
	_root.changed = false
	return ran

## Round 785: whether `p` follows a dead ancestor that moved or turned on
## its last pass -- a translation in it (u6), or a turn (u2 / u3 / u4 gated
## on its "changed"). Round 786: the simulation no longer needs it (a dead
## ancestor still moves with its own ancestors); tools may ask.
static func follows_moving_dead(p: Particle) -> bool:
	var f := p.f_move
	if f != null and not f.alive and f.pos != f.old_pos:
		return true
	f = p.f_orbit
	if f != null and not f.alive and f.changed:
		return true
	f = p.f_rot
	if f != null and not f.alive and f.changed:
		return true
	f = p.f_vel
	return f != null and not f.alive and f.changed

## A particle's four follows (READ, see the header): u2, u3, u4 gated on
## the ancestor having changed, u6 every time.
static func _follow(p: Particle) -> void:
	var f := p.f_orbit
	if f != null and f.changed:
		p.pos = f.delta * (p.pos - f.old_pos) + f.old_pos
	f = p.f_rot
	if f != null and f.changed:
		p.rot = f.delta * p.rot
		p.changed = true
	f = p.f_vel
	if f != null and f.changed:
		p.vel = f.delta * p.vel
	f = p.f_move
	if f != null:
		p.pos += f.pos - f.old_pos

## Moves everything by -v: every particle's position and old position, and
## the effect's own placement, so the simulation space can be re-centred
## without anything moving in the world (the same shift as retail's
## CEFEffect::FUN_00c865a0, which adds one vector to every particle's
## position and old position).
##
## Round 786: the held dead particles too -- FUN_00c865a0 walks each node's
## motion list (updater +0xb0, head +0xd8), which still holds them (READ,
## see "Dead ancestors").
func shift(v: Vector3) -> void:
	for p in _order:
		p.pos -= v
		p.old_pos -= v
	_root.pos -= v
	_root.old_pos -= v

## Where the effect is placed (tests).
func origin() -> Vector3:
	return _root.pos

## The ancestor `level` owners up from a new particle (READ: CEFGroup::
## vslot_004): 0 none, 1 its owner, and so on; the effect (_root) is above
## the root node's particles and nothing is above it.
##
## The walk is READ with its signed compares: a level of 0 names nothing;
## any other level names the owner and then walks up while `1 < level` --
## so a NEGATIVE u2, u4 or u6 names the owner (level 1). u3 is tested
## `u3 < 1` first: 0 or negative names nothing (negative also resets the
## inherited rotation). Callers pass u3 through rot_level().
static func _ancestor(p: Particle, level: int) -> Particle:
	if level == 0:
		return null
	var a := p.parent
	var k := level - 1
	while k > 0 and a != null:
		a = a.parent
		k -= 1
	return a

## u3 as the walk takes it: below 1 names nothing (READ, see _ancestor).
static func rot_level(u3: int) -> int:
	return u3 if u3 >= 1 else 0

## A u32 read as the client's signed int.
static func signed32(v: int) -> int:
	v &= 0xFFFFFFFF
	return v - 0x100000000 if v >= 0x80000000 else v

func _owner_age(e: Emitter) -> int:
	return age if e.owner == _root else e.owner.age

func _emit(e: Emitter) -> void:
	var tp: Tpl = template.tpls[e.tpl]
	if tp.emit == null:
		e.done = true
		return
	var n := emit_spawns(tp, _owner_age(e), e)
	for k in range(n):
		# Round 763's review, L3 (OURS, the same state): once the effect holds
		# MAX_PARTICLES every remaining spawn of this emission is refused for
		# that alone (no death comes in between), each giving 1.0 back -- so all
		# at once, not one by one (a corrupt emission count would otherwise
		# loop for seconds). Exact: acc holds an f32 value, so maxf(acc - rest,
		# 0) is the repeated maxf(acc - 1, 0). Mirrored in native efp_sim.rs.
		if particles.size() >= MAX_PARTICLES:
			var rest := n - k
			dropped += rest
			e.acc = maxf(e.acc - float(rest), 0.0)
			break
		_spawn(e.tpl, e.owner, e)

## One emitter frame: EfpReader.emit_tick's rules (READ, 0x00c84e70) on the
## template's precomputed values, with no Dictionary per call. Sets e.done
## (READ, 0x00c84e9c / 0x00c84ea5: set or cleared every frame) and e.acc and
## returns how many particles spawn. efp_keep_test checks it against
## emit_tick.
static func emit_spawns(tp: Tpl, owner_age: int, e: Emitter) -> int:
	var t := EfpReader.i32(owner_age - tp.e_delay)
	if t >= tp.e_dur:
		e.done = true # the cheap early-out: a finished emitter costs one compare
		return 0
	e.done = false
	var interval := tp.e_int
	if interval <= 0 or t < 0:
		return 0
	if interval_mul > 1:
		var m := EfpReader.i32(interval * interval_mul)
		if m < tp.e_dur:
			interval = m
	# Round 763's review, L4: the multiplied interval can wrap to 0 or below
	# (a modulo by zero); no frame fires then. Mirrored in efp_sim.rs.
	if interval <= 0 or t % interval != 0:
		return 0
	var cap := tp.e_max
	if threshold > 0 and float(threshold) < tp.e_per and cap > 0:
		cap = maxi(EfpReader.ftol(EfpReader.f32(float(cap) * 0.5)), 1)
	var old := EfpReader.ftol(e.acc)
	var nxt := EfpReader.f32(tp.e_per + e.acc)
	var capf := EfpReader.f32(float(cap))
	if capf < nxt:
		nxt = capf
	e.acc = nxt
	return maxi(EfpReader.i32(EfpReader.ftol(nxt) - old), 0)

## A particle dies: the global count drops and its emitter's acc gives back
## 1.0, so `max_live` caps the live particles (READ, FUN_00c87a20).
func _on_death(p: Particle) -> void:
	_live_add(-1)
	if p.emitter != null:
		p.emitter.acc = maxf(p.emitter.acc - 1.0, 0.0)
	_unlink(p)

## The emitter's particle list (READ, see the header): append at the tail.
static func _link_in(p: Particle, e: Emitter) -> void:
	if e == null:
		return
	p.link = e.tail
	if e.tail != null:
		e.tail.next_link = p
	e.tail = p

## ... and unlink on death (CEFElement::FUN_00c873a0).
static func _unlink(p: Particle) -> void:
	if p.next_link != null:
		p.next_link.link = p.link
	if p.link != null:
		p.link.next_link = p.next_link
	if p.emitter != null and p.emitter.tail == p:
		p.emitter.tail = p.link
	p.link = null
	p.next_link = null

## Whether one more particle fits the caps (see the header).
func can_spawn() -> bool:
	if particles.size() >= MAX_PARTICLES:
		return false
	if _deferred:
		if _live_delta < _sure_below:
			return true
		if _live_delta >= _sure_from:
			return false
		var sure: Vector2i = _gate.admit(_gate_index, _live_delta)
		_sure_below = sure.x
		_sure_from = sure.y
		return _live_delta < _sure_below
	return live_total < limit_for(reserved)

func _spawn(tpl_index: int, owner: Particle, from: Emitter = null) -> void:
	if not can_spawn():
		dropped += 1
		if from != null:
			from.acc = maxf(from.acc - 1.0, 0.0) # OURS: a refused spawn is not live
		return
	var tp: Tpl = template.tpls[tpl_index]
	var p := Particle.new()
	p.tpl = tpl_index
	p.emitter = from
	p.parent = owner
	p.pos = owner.pos
	p.old_pos = owner.pos
	p.vel = owner.vel
	p.rot = Basis.IDENTITY if tp.lv_rot < 0 else owner.rot
	p.old_rot = p.rot
	p.f_orbit = _ancestor(p, tp.lv_orbit)
	p.f_rot = _ancestor(p, rot_level(tp.lv_rot))
	p.f_vel = _ancestor(p, tp.lv_vel)
	p.f_move = _ancestor(p, tp.lv_move)
	if p.f_move != null:
		p.vel -= p.f_move.vel # READ: the velocity is relative to the followed ancestor
	_link_in(p, from)
	particles.append(p)
	_order.append(p)
	_live_add(1)
	spawned += 1
	if tp.schedule.size() > 0 and not (tp.schedule[0] as Array).is_empty():
		_run_list(p, tp, tp.schedule[0])
	for k in tp.children:
		var e := Emitter.new()
		e.tpl = k
		e.owner = p
		emitters.append(e)

# ---------------------------------------------------------------- commands

## A D3D row-major 4x4 (16 floats) as a Basis acting like `v * M`.
static func basis_of(m) -> Basis:
	if not (m is PackedFloat32Array) or (m as PackedFloat32Array).size() < 11:
		return Basis.IDENTITY
	var a: PackedFloat32Array = m
	return Basis(Vector3(a[0], a[1], a[2]), Vector3(a[4], a[5], a[6]), Vector3(a[8], a[9], a[10]))

func _parent_of(p: Particle) -> Particle:
	return p.parent if p.parent != null else _root

## The rotation a space selector names: 0 none, 1 own, 2 parent, 3 link
## (READ; a link variant is skipped before this when there is no link).
func _frame(p: Particle, sel: int) -> Basis:
	match sel:
		1:
			return p.rot
		2:
			return _parent_of(p).rot
		3:
			return p.link.rot if p.link != null else Basis.IDENTITY
	return Basis.IDENTITY

## True when command `name` with this space byte names the link (+0x34):
## the variants the interpreter runs only when the particle has one (READ,
## see the header).
static func names_link(name: String, space: int) -> bool:
	return KIND.has(name) and kind_names_link(int(KIND[name]), space)

## The same by command family (what _run dispatches on).
static func kind_names_link(kind: int, space: int) -> bool:
	match kind:
		K_POS, K_CONEPOS, K_BANPOS:
			return space % 3 == 2 or space / 3 == 3
		K_SPHERE:
			return space == 2
		K_VEL, K_CONEVEL, K_FORCE, K_CONEFORCE, K_ROT, K_BANROT:
			return space == 3
		K_ATTRACT:
			return space == 1
	return false

func _rand() -> float:
	return _rng.randf()

## A cone vector from AngleVector1's b = (min, max, angle in radians).
func _cone(b: Vector3) -> Vector3:
	var r := lerpf(b.x, b.y, _rand())
	var tilt := _rand() * b.z
	var spin := _rand() * TAU
	# (0, r, 0) * Rz(tilt) * Ry(spin), row vectors (READ order).
	var x := -r * sin(tilt)
	var y := r * cos(tilt)
	return Vector3(x * cos(spin), y, x * sin(spin))

func _ball() -> Vector3:
	for _i in range(64):
		var q := Vector3((_rand() - 0.5) * 2.0, (_rand() - 0.5) * 2.0, (_rand() - 0.5) * 2.0)
		if q.length_squared() <= 1.0:
			return q
	return Vector3.ZERO

## A position command: origin o, rotation frame r (space = r*3 + o).
## SetConePos's o=0 cases (0x1f/0x22/0x25/0x28) build the vector in the
## interpreter's stack vector (0x00c899a1), so `stack` records it there.
func _set_pos(p: Particle, space: int, v: Vector3, stack: bool = false) -> void:
	var o := space % 3
	var r := space / 3
	var d := _frame(p, r) * v
	if o == 1:
		p.pos = _parent_of(p).pos
	elif o == 2:
		p.pos = p.link.pos
	elif stack:
		_scratch = d
	p.pos += d

func _run_list(p: Particle, tp: Tpl, list: Array) -> void:
	_scratch = Vector3.ZERO # OURS: the stack vector's uninitialised start
	for entry in list:
		_run(p, tp, entry[0], entry[1], entry[2])

func _run(p: Particle, tp: Tpl, kind: int, s: int, v) -> void:
	if p.link == null and kind_names_link(kind, s):
		return # READ: every link variant tests +0x34 first (round 621)
	match kind:
		K_POS, K_BANPOS:
			_set_pos(p, s, v)
		K_CONEPOS:
			_set_pos(p, s, _cone(v), true)
		K_SPHERE:
			if s == 0:
				# READ, 0x00c8a4c5: position = the ball point, then
				# position += value * the stack vector (see the header).
				p.pos = _ball()
				_scratch = (v as Vector3) * _scratch
				p.pos += _scratch
			else:
				var o: Vector3 = p.link.pos if s == 2 else _parent_of(p).pos
				p.pos = o + _ball() * (v as Vector3)
		K_VEL:
			p.vel = _frame(p, s) * (v as Vector3)
		K_CONEVEL:
			p.vel = _frame(p, s) * _cone(v)
		K_FORCE:
			p.vel += _frame(p, s) * (v as Vector3)
		K_CONEFORCE:
			var c1 := _cone(v)
			_scratch = c1
			p.vel += _frame(p, s) * c1
			if s == 0:
				# READ: case 0x46 falls through into 0x47 (own rotation).
				var c2 := p.rot * _cone(v)
				_scratch = c2
				p.vel += c2
		K_ATTRACT:
			var d := p.pos - (p.link.pos if s == 1 else _parent_of(p).pos)
			if d.length_squared() > 0.0:
				_scratch = d.normalized() * float(v)
				p.vel += _scratch
		K_ROT, K_BANROT:
			_set_rot(p, s, v)
		K_RVEL:
			p.rvel = v
			p.has_rvel = p.rvel != Basis.IDENTITY
		K_SHAPE:
			p.shape = v
		K_SHAPEVEL:
			p.shape_vel = v
			p.has_shape_vel = p.shape_vel != Basis.IDENTITY
		K_SCALE:
			p.scale = v
		K_DIFFUSE:
			p.color = v
		K_SLIDE:
			p.uv = v
		K_RANDSCALE:
			if tp.scale_graph is Dictionary:
				p.scale = sample_scale_graph(tp.scale_graph, _rand())

## M, then the frame's rotation (row vectors: M * F) as Godot bases: F * M.
func _set_rot(p: Particle, s: int, m: Basis) -> void:
	p.changed = true # READ: the rotation commands set +0x60
	match s:
		0:
			p.rot = m
		_:
			p.rot = _frame(p, s) * m

## A BlendScaleGraph {a, b, times, scales} at time t (READ shape, FUN_00c89140).
static func sample_scale_graph(g: Dictionary, t: float) -> Vector3:
	var times: PackedFloat32Array = g.get("times", PackedFloat32Array())
	var scales: PackedVector3Array = g.get("scales", PackedVector3Array())
	var n := mini(times.size(), scales.size())
	if n == 0:
		return Vector3.ONE
	if t < float(g.get("a", 0.0)) or t <= times[0]:
		return scales[0]
	if t > float(g.get("b", 1.0)) or t >= times[n - 1]:
		return scales[n - 1]
	for i in range(1, n):
		if t <= times[i]:
			var span := times[i] - times[i - 1]
			var w := (t - times[i - 1]) / span if span > 0.0 else 1.0
			return scales[i - 1].lerp(scales[i], w)
	return scales[n - 1]

## A raw D3DCOLOR as a Godot colour (INFERRED 0xAARRGGBB).
static func color_of(c: int) -> Color:
	return EfpReader.d3dcolor(c)
