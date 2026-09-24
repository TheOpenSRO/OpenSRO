extends RefCounted
class_name MonsterStrikes

## Which of a counterattack's two reports the attacker's own client draws it
## from -- its OpAttackResult, or the zone's OpMonsterAttacked push (0x007D,
## docs/protocol/monster_ai.md, "srrevamp's own monster protocol
## (placeholders)") -- so a counter is drawn once, never twice and never not at
## all, against a server that sends the push and one that does not. Pure and
## static so a headless test can hold it to account; World3D's
## _draw_counter_at_landing, _settle_counter and _on_monster_attacked are the
## glue.
##
## The server resolves a counterattack inside performAttack
## (server/internal/session/combat.go, the branch after
## combat.Hub.CounterattackReady; rounds 254 and 505) and reports it to the
## attacker in that attack's OpAttackResult. A server with the strike push
## sends the same numbers to the whole zone, the attacker included, as an
## OpMonsterAttacked right BEHIND that result, from the same goroutine. The
## attacker's client draws the counter when its own blow lands (`lands_after`,
## the swing's hit event), and by then the push has normally arrived: the
## counter is drawn from the push. Against an older server, or with the push
## off, none comes, and it is drawn from the result as before round 540.
##
## A wait is a Dictionary:
##   damage, hp, critical, blocked, died  the counter the result reported,
##            which the push repeats number for number
##   push     the OpMonsterAttacked that claimed it, or null
##   drawn    no push had come when the blow landed, so the result drew it
##
## `waits` maps a monster id to its waits, oldest first.
##
## THE CLIENT DOES NOT KNOW ITS OWN CHARACTER ID. No message tells it:
## OpEnterWorldResult carries a zone, a position, a gender, vitals and the
## others in the zone, but no id (server/internal/session/world.go
## EnterWorldResult), and adding one would change a layout. So a push is
## taken as a strike on this player only when it repeats a counter this
## client's own result reported (`repeats`) and its target is none of the
## other players the client has drawn (World3D._other_bodies). Every strike
## the server can push today is such a counter; a monster striking on its own
## (mob-battle-chase) will need the id.

## What claim() did with a push.
## CLAIM_NONE: it repeats no counter this client is waiting on -- another
## player's strike, drawn at once.
## CLAIM_HELD: it repeats a counter still waiting for its blow to land; it is
## drawn from the push then (settle).
## CLAIM_DRAWN: it repeats a counter the result already drew (no push had come
## when the blow landed); there is nothing more to draw.
const CLAIM_NONE := 0
const CLAIM_HELD := 1
const CLAIM_DRAWN := 2

## Whether an OpAttackResult reports a counterattack. The server fills the
## counter's fields only in performAttack's counter branch, and a counter that
## lands deals at least 1: combat.ResolveBlow floors the blow at 1 in
## MitigateDamage and again in ApplyLevelAdvantage, and ApplyFloorBand never
## takes it below 1 (server/internal/combat/combat.go). So a counter is exactly a
## blow taken or a blow blocked. A killing blow draws none (the monster that
## died does not strike back) and a refusal carries nothing.
static func result_countered(result: CombatNet.AttackResult) -> bool:
	if result == null or result.error != "" or result.monster_died:
		return false
	return result.player_damage_taken > 0 or result.player_blocked

## Starts waiting for `result`'s counter from `monster_id`, and returns the
## wait for World3D to settle when the blow lands. Waits the result already
## drew are dropped first: a push for one of them follows its own result from
## the same goroutine, and this counter comes at least one more attack later
## (a monster strikes again only past its attack skill's ReuseDelay,
## combat.Hub.CounterattackReady) -- so a push that has not come by now is not
## coming, and the list stays short against a server that never sends one.
static func expect(waits: Dictionary, monster_id: int, result: CombatNet.AttackResult) -> Dictionary:
	var kept: Array = []
	for w in waits.get(monster_id, []):
		if not bool(w["drawn"]):
			kept.append(w)
	var wait := {
		"damage": result.player_damage_taken,
		"hp": result.player_hp,
		"critical": result.monster_critical,
		"blocked": result.player_blocked,
		"died": result.player_died,
		"push": null,
		"drawn": false,
	}
	kept.append(wait)
	waits[monster_id] = kept
	return wait

## Whether `attacked` repeats the counter `wait` holds: the same damage, target
## HP, critical, block and death -- what a server with the push copies out of
## the one outcome both messages report.
static func repeats(wait: Dictionary, attacked: CombatNet.MonsterAttacked) -> bool:
	return int(wait["damage"]) == attacked.damage \
		and int(wait["hp"]) == attacked.target_hp \
		and bool(wait["critical"]) == attacked.critical \
		and bool(wait["blocked"]) == attacked.blocked \
		and bool(wait["died"]) == attacked.target_died

## A push claims the oldest unclaimed wait on its monster that it repeats
## (repeats), and says what became of it (CLAIM_*). A wait the result already
## drew is removed as it is claimed; a held one stays until it is settled.
static func claim(waits: Dictionary, attacked: CombatNet.MonsterAttacked) -> int:
	if attacked == null or not waits.has(attacked.monster_id):
		return CLAIM_NONE
	var list: Array = waits[attacked.monster_id]
	for i in range(list.size()):
		var w: Dictionary = list[i]
		if w["push"] != null or not repeats(w, attacked):
			continue
		if bool(w["drawn"]):
			list.remove_at(i)
			if list.is_empty():
				waits.erase(attacked.monster_id)
			return CLAIM_DRAWN
		w["push"] = attacked
		return CLAIM_HELD
	return CLAIM_NONE

## When the blow lands: the push that claimed `wait`, which World3D draws the
## counter from, and the wait is done. With no push, null: World3D draws the
## counter from the result, and the wait stays, marked drawn, so a push that
## comes after all is claimed (CLAIM_DRAWN) and not drawn a second time.
static func settle(waits: Dictionary, monster_id: int, wait: Dictionary) -> CombatNet.MonsterAttacked:
	var pushed: CombatNet.MonsterAttacked = wait["push"]
	if pushed == null:
		wait["drawn"] = true
		return null
	# By identity: Array.erase compares Dictionaries by content.
	var list: Array = waits.get(monster_id, [])
	for i in range(list.size()):
		if is_same(list[i], wait):
			list.remove_at(i)
			break
	if waits.has(monster_id) and list.is_empty():
		waits.erase(monster_id)
	return pushed
