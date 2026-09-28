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
## on a monster: its request was not aimed at an entity, and it reports no
## damage on one. A server that predates targetType resolves a damaging
## Target_Required 0 row against the monster field World3D still fills with
## the selection, and that reply is a blow like any other.
static func is_self_reply(target_type: int, monster_damage: int, monster_died: bool) -> bool:
	return target_type != SkillNet.TARGET_ENTITY and monster_damage <= 0 and not monster_died

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
# The client is not told its own character id (MonsterStrikes has the same
# gap and why), and OpBuffStart / OpBuffEnd / OpSkillMove name their owner by
# id. So this player's own id is LEARNED: a start or a move for a skill this
# client cast within RECENT_CAST_MS, naming someone who is not another player
# drawn here, is this player's, and its id is kept from then on. An end is
# this player's when its owner is that id, or when it ends a token already
# claimed. Until the id is learned nothing else is claimed -- a buff the
# player did not cast (a party member's, when the server has those) moves no
# speed until then. OURS, disclosed.

## How long after a cast a start or move for the same skill is taken as its
## answer. OURS, a generous margin over a round trip and a cast time; not
## derived from any table.
const RECENT_CAST_MS := 10000

## This player's character id, once learned; -1 before.
var own_id := -1
## skill id -> Time.get_ticks_msec() of the cast.
var _recent_casts: Dictionary = {}
## Tokens of buffs claimed as this player's.
var _own_tokens: Dictionary = {}

## A self or ground cast went out.
func note_cast(skill_id: int, now_ms: int) -> void:
	_recent_casts[skill_id] = now_ms

func _claims(owner_id: int, skill_id: int, others: Dictionary, now_ms: int) -> bool:
	if own_id >= 0:
		return owner_id == own_id
	if others.has(owner_id):
		return false
	var at = _recent_casts.get(skill_id)
	if at == null or now_ms - int(at) > RECENT_CAST_MS:
		return false
	own_id = owner_id
	return true

## Whether an OpBuffStart is this player's (learning the id when it answers
## a cast of ours). `others` is World3D._other_bodies.
func claims_start(owner_id: int, skill_id: int, token: int, others: Dictionary, now_ms: int) -> bool:
	if not _claims(owner_id, skill_id, others, now_ms):
		return false
	_own_tokens[token] = true
	return true

## Whether an OpBuffEnd is this player's; forgets the tokens it ends.
func claims_end(owner_id: int, tokens: Array) -> bool:
	var mine := own_id >= 0 and owner_id == own_id
	for t in tokens:
		if _own_tokens.has(int(t)):
			mine = true
	if mine:
		if own_id < 0:
			own_id = owner_id
		for t in tokens:
			_own_tokens.erase(int(t))
	return mine

## Whether an OpSkillMove is this player's.
func claims_move(character_id: int, skill_id: int, others: Dictionary, now_ms: int) -> bool:
	return _claims(character_id, skill_id, others, now_ms)
