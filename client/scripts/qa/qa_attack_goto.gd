extends RefCounted
class_name QaAttackGoto

## OPENSRO_QA_ATTACK_GOTO's choice of which monster to stand beside and where,
## taken from a FRESH monster list rather than from the drawn bodies (round
## 539). Kept apart from World3D so a headless test can hold it to account.
##
## Why a fresh list: qa_shot.sh's movie writer steps the client 1/60 s a frame
## at about 0.33 s of wall time, so the client runs about 20x slower than the
## wall-clock server (docs/protocol/monster_ai.md, "The live checks"). With the
## monster AI on, a drawn body is therefore stale: a walking one is drawn up to
## OtherWalk.RESYNC_DISTANCE from where the server has it, and a list
## refresh leaves it there (MonsterMotion.reconcile). A GOTO beside the drawn
## body can put the player out of reach of the real monster, so its first
## swing would be refused as too far away; live check 2 measured two targets
## drawn 20.7 and 24.7 units from where the server listed them. So World3D
## asks for the list and, in the reply, stands the player beside the position
## the SERVER listed -- read before World3D._sync_monster_bodies reconciles it
## into the drawn one.
##
## What only a live run can show: how far the monster walks between the
## server building the list and the swing reaching it (at most about one
## client frame of wall time plus the round trip), and so whether the first
## swing lands. Live check 2 (docs/protocol/monster_ai.md, "Run 2, measured"):
## all 9 first swings landed, each monster stopping within 0.8 units of where
## it was listed.

## Where the player stands relative to the monster: 8 units along +x. The
## hook's own offset since it was written -- a QA choice that keeps the
## target in front of the camera, not a game value. For a Mangyang it is
## inside the stop distance of any plain swing: unarmed that is 10
## (CombatNet.approach_band(4, 6, 0)), and a weapon's Range only widens it. A
## species with a smaller BCRadius can have a stop under 8.
const STAND_OFFSET := Vector3(8.0, 0.0, 0.0)

## The monster to stand beside, from `fresh` (CombatNet.MonsterSnapshot, a
## list result just decoded): `preferred_id` when the list still has it alive,
## else the listed monster nearest `from` on the ground plane whose name
## contains `wanted` (any name when it is empty). A monster with no HP, or
## one `dying` holds for its death clip (World3D._dying_until), is never
## picked. null when nothing qualifies.
static func pick(fresh: Array, preferred_id: int, wanted: String, from: Vector3, dying: Dictionary) -> CombatNet.MonsterSnapshot:
	var best: CombatNet.MonsterSnapshot = null
	var best_d := INF
	for entry in fresh:
		var m: CombatNet.MonsterSnapshot = entry
		if m == null or m.hp <= 0 or dying.has(m.monster_id):
			continue
		if wanted != "" and not m.monster_name.contains(wanted):
			continue
		if m.monster_id == preferred_id:
			return m
		var d := Vector2(m.x, m.z).distance_to(Vector2(from.x, from.z))
		if d < best_d:
			best_d = d
			best = m
	return best

## Where the player stands for `m`: its listed position plus STAND_OFFSET. The
## caller resolves the height off the ground.
static func stand_spot(m: CombatNet.MonsterSnapshot) -> Vector3:
	return Vector3(m.x, m.y, m.z) + STAND_OFFSET

## How close to the stand spot, on the ground plane, counts as already
## standing there. A QA choice, not a game value.
const ALREADY_THERE := 1.0

## Whether the player at `here` must be moved to `spot`. A player already
## there is not moved again: the teleport sends an OpMove, and the server
## cancels a running keep-up on every one (session/world.go's move handler),
## so a second GOTO onto a monster already held -- one whose drawn body is
## still gliding to where the server stopped it -- would end the keep-up that
## holds it while it lives.
static func needs_teleport(here: Vector3, spot: Vector3) -> bool:
	return Vector2(here.x, here.z).distance_to(Vector2(spot.x, spot.z)) > ALREADY_THERE
