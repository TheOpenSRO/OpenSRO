extends RefCounted
class_name SelfCast

## Casting a skill with no monster target (round 617): the decisions
## World3D._cast_skill and the buff/skill-move handlers make, kept here as
## plain functions so self_cast_test.gd can drive them without a world.
##
## How a skill is cast depends on two skilldata columns, Target_Required
## (col 22) and TargetType_Land (col 24), as the skill tick reads them
## (server 0x4ae590 phase 0, docs/protocol/auto_command.md; READ):
##
## - **Target_Required 0** -- Grass Walk, the imbues, the shields, a self-heal
##   (669 kind-3 and 80 kind-0 China rows, skills_spec §1.5, MEASURED): the
##   tick goes straight to the cast with no target, so the cast goes out with
##   nothing selected, as OpUseSkill targetType 0 (PLAN_SELF).
## - **Target_Required 1 with TargetType_Land 1** -- the 19 Ghost Walk rows:
##   the player picks a point on the ground, sent as targetType 2 with the
##   point (PLAN_GROUND). Retail's ground-cast sender is 0x9ec080 (READ); its
##   cursor and ground decal are not read (OPEN), so the mode's cursor is
##   OURS.
## - **Every other row** needs a monster (PLAN_TARGET), or is refused with
##   nothing selected (PLAN_NEED_TARGET). Whether retail falls back to the
##   caster for a Target_Required 1 heal with nothing selected is OPEN
##   (skills_spec §2.2); it is refused here, as before.

const PLAN_SELF := "self"
const PLAN_GROUND := "ground"
const PLAN_TARGET := "target"
const PLAN_NEED_TARGET := "need_target"

## How a skill is cast. `reach` is HudPanels.skill_reach(skill_id) -- empty
## for a skill the catalog does not know, which keeps the old rule: cast at
## the target, or refuse with none.
static func plan(reach: Dictionary, has_target: bool) -> String:
	if not reach.is_empty() and reach.has("target_required"):
		var tr := int(reach["target_required"])
		if tr == 0:
			return PLAN_SELF
		if tr == 1 and int(reach.get("target_land", 0)) == 1:
			return PLAN_GROUND
	return PLAN_TARGET if has_target else PLAN_NEED_TARGET

## Whether an attack result answers a self or ground cast rather than a blow
## on a monster, so World3D draws no swing, flinch or counter for it.
##
## With the server's echo (`echoed`, the reply's trailing targetType) the type
## is the request's own: a type-0/2 reply is the cast's, unless it reports
## damage on a monster (a damaging Target_Required 0 row a server resolves
## against a target) or the player's death, which are drawn as ever.
##
## Without the echo (an older server) the type is the request queue's guess,
## and a keep-up repeat or a swing dropped inside its re-use delay puts that
## queue out of step. So such a reply is taken as the cast's only when it
## carries nothing that matters to draw: no damage, no kill, no death and no
## error.
static func is_self_reply(target_type: int, echoed: bool, monster_damage: int, monster_died: bool,
		player_died: bool, error: String) -> bool:
	if target_type == SkillNet.TARGET_ENTITY:
		return false
	if monster_damage > 0 or monster_died or player_died:
		return false
	return echoed or error == ""

## The phase timing SkillEffects.cast gets for a self or ground cast, so the
## effects' phases agree with the body clip World3D._play_self_cast_anim
## plays for the same skillaniset2 row (round 616-620 integration):
## - READY, WAIT and SHOT all "none" (Grass Walk, the imbues): no body clip,
##   and a phase with no clip of its own advances at once (READ,
##   IDecoSkill FUN_00a53480: the per-phase clip count at +8 + phase), so
##   prep 0 and cast 0 -- READY's rows at the send, then WAIT, then SHOT.
## - a WAIT clip (Ghost Walk): the body plays it at once, so READY spans 0
##   (a READY clip retail would play first is not played here, OPEN) and the
##   WAIT loop holds -- READ, until the server's skill-action message forces
##   SHOT (FUN_00a56680 -> FUN_00a53090), which is World3D's
##   SkillEffects.shot on OpSkillMove or cancel_cast on a refusal. cast_ms is
##   only the fallback end if no answer comes: the WAIT clip's length
##   (`clip_seconds`, OURS), or SkillEffects.READY_LOOP_MAX without a clip.
## - otherwise (no row, or only READY/SHOT, whose timing is unread): {} --
##   SkillEffects times the phases from skilldata (its header, INFERRED).
static func effect_timings(aniset_row: Dictionary, clip_seconds: float) -> Dictionary:
	var plan := SkillEffectReader.cast_body_anim(aniset_row)
	match String(plan["kind"]):
		"none":
			return {"prep_ms": 0, "cast_ms": 0}
		"wait":
			var hold := int(round(clip_seconds * 1000.0)) if clip_seconds > 0.0 \
				else int(SkillEffects.READY_LOOP_MAX * 1000.0)
			return {"prep_ms": 0, "cast_ms": hold}
	return {}

# --- Ground-pick mode (Ghost Walk) --------------------------------------------

## The skill waiting for a ground click; 0 when the mode is off.
var pick_skill_id := 0
var pick_code := ""

func picking() -> bool:
	return pick_skill_id != 0

## Turns the mode on for a skill (replacing one already waiting).
func begin_pick(skill_id: int, basic_code: String) -> void:
	pick_skill_id = skill_id
	pick_code = basic_code

## Turns the mode off; true when it was on.
func cancel_pick() -> bool:
	var was := picking()
	pick_skill_id = 0
	pick_code = ""
	return was

## Takes the waiting skill for a click that found ground -- {"id", "code"} --
## and turns the mode off. Empty when the mode was off.
func take_pick() -> Dictionary:
	if not picking():
		return {}
	var out := {"id": pick_skill_id, "code": pick_code}
	cancel_pick()
	return out

# --- Whose buff or move is it ---------------------------------------------------
#
# OpBuffStart / OpBuffEnd / OpSkillMove name their owner by id, and the
# trailing ownerKind says whether that id is a character's or a monster's. A
# monster's buff is never this player's, whatever its id.
#
# This player's own id comes from OpSelfId (0x00F9, on world entry), or from
# the answer to its own sit (SitState.own_id): World3D passes either to
# tell_own_id, and from then on only that id is this player's. Before either
# has arrived -- a server that sends no OpSelfId -- the id is LEARNED as a
# fallback: a start or move for a skill this client cast within
# RECENT_CAST_MS, naming no other player drawn here, is this player's, and
# its id is kept. An end is this player's when its owner is that id, or when
# it ends a token already claimed. OURS, disclosed.

## How long after a cast a start or move for the same skill is taken as its
## answer (the fallback only). OURS, a generous margin over a round trip and a
## cast time; not derived from any table.
const RECENT_CAST_MS := 10000

## This player's character id; -1 before it is told or learned.
var own_id := -1
## Whether own_id was told (OpSelfId or the sit answer) rather than learned.
var own_id_told := false
## skill id -> Time.get_ticks_msec() of the cast.
var _recent_casts: Dictionary = {}
## Tokens of buffs claimed as this player's.
var _own_tokens: Dictionary = {}

## The id the server gave (OpSelfId) or the sit answer taught. A learned id
## that disagrees is replaced, and the claimed tokens with it.
func tell_own_id(id: int) -> void:
	if id < 0:
		return
	if own_id != id:
		_own_tokens.clear()
	own_id = id
	own_id_told = true

## A new character entered the world: forget whose it was.
func forget_owner() -> void:
	own_id = -1
	own_id_told = false
	_own_tokens.clear()
	_recent_casts.clear()

## A self or ground cast went out.
func note_cast(skill_id: int, now_ms: int) -> void:
	_recent_casts[skill_id] = now_ms

func _claims(owner_id: int, owner_kind: int, skill_id: int, others: Dictionary, now_ms: int) -> bool:
	if owner_kind == SkillNet.OWNER_MONSTER:
		return false
	if own_id >= 0:
		return owner_id == own_id
	if others.has(owner_id):
		return false
	var at = _recent_casts.get(skill_id)
	if at == null or now_ms - int(at) > RECENT_CAST_MS:
		return false
	own_id = owner_id
	return true

## Whether an OpBuffStart is this player's. `others` is World3D._other_bodies.
func claims_start(owner_id: int, owner_kind: int, skill_id: int, token: int, others: Dictionary, now_ms: int) -> bool:
	if not _claims(owner_id, owner_kind, skill_id, others, now_ms):
		return false
	_own_tokens[token] = true
	return true

## Whether an OpBuffEnd is this player's; forgets the tokens it ends.
func claims_end(owner_id: int, owner_kind: int, tokens: Array) -> bool:
	if owner_kind == SkillNet.OWNER_MONSTER:
		return false
	var mine := own_id >= 0 and owner_id == own_id
	if not own_id_told:
		for t in tokens:
			if _own_tokens.has(int(t)):
				mine = true
	if mine:
		if own_id < 0:
			own_id = owner_id
		for t in tokens:
			_own_tokens.erase(int(t))
	return mine

## Whether an OpSkillMove is this player's (a move names a character).
func claims_move(character_id: int, skill_id: int, others: Dictionary, now_ms: int) -> bool:
	return _claims(character_id, SkillNet.OWNER_CHARACTER, skill_id, others, now_ms)
