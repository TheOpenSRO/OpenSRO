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
## THE CLIENT IS NOT TOLD ITS OWN CHARACTER ID WHEN IT ENTERS THE WORLD.
## OpEnterWorldResult carries a zone, a position, a gender, vitals and the
## others in the zone, but no id (server/internal/session/world.go
## EnterWorldResult), and adding one would change a layout. A party reply does
## carry one per member (PartyResult / PartyMemberSnapshot.CharacterID in
## server/internal/session/party.go, which PartyNet decodes), so the id can be
## learned by name once such a reply has arrived -- but only then, and a
## character outside a party never gets one (OpPartyInfo answers it an empty
## roster). Round 540 wrote "the client has no way to know its own id", which
## overstated it (corrected in round 544); the pairing was chosen so a strike
## is recognised from the first swing, party or no party. So a push is taken
## as a strike on this player only when it repeats a counter this client's
## own result reported (`repeats`) and its target is none of the other
## players the client has drawn (World3D._other_bodies).
##
## A monster striking on its own (round 546: the server's -monster-battle, the
## chase and the swing in session/monsterai.go's battleTick) sends no result
## to pair with. Such a push is recognised BY ELIMINATION (is_own_unpaired):
## the server tells this client of every other player in its zone -- the
## enter-world result's others, then an entered notice for each arrival, each
## drawn into World3D._other_bodies before any blow on them can arrive -- so a
## push whose target is drawn nowhere is a blow on this player. The one hole,
## closed here: a push for a player who has just LEFT the zone can cross that
## player's left notice (the strike worker sends off the tick, the notice from
## the world handler), and for LEFT_GRACE_MS after a left notice such a push
## is drawn as the swing alone instead. A disclosed stand-in: the retail client
## is told its own id when it spawns (the character-data packet), and a
## message carrying it here is a protocol addition this round did not make.

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

## How long after a player's left notice a push naming them is still taken as
## theirs rather than this player's (is_own_unpaired). OWN DESIGN, an
## engineering margin: the crossing it covers is one strike worker's store
## write against one world-handler notice, milliseconds apart on the server;
## ten seconds is long enough for any stalled write and short enough that an
## id the server reuses (it does not: character ids are the table's) could
## not matter.
const LEFT_GRACE_MS := 10000

## Whether a push that claims no counter is a blow on THIS player: its target
## is none of the other players drawn here (`others`, World3D._other_bodies,
## keyed by character id) and none that left within LEFT_GRACE_MS of `now_ms`
## (`left`, character id -> the tick the left notice came, World3D's
## _recently_left). See the class comment for why elimination is sound.
static func is_own_unpaired(target_id: int, others: Dictionary, left: Dictionary, now_ms: int) -> bool:
	if others.has(target_id):
		return false
	if left.has(target_id) and now_ms - int(left[target_id]) <= LEFT_GRACE_MS:
		return false
	return true

## Whether a blow that killed this player LEFT it dead -- the server's life
## state 2 (docs/protocol/character_state.md, rounds 411-413), HP 0 -- so the
## client holds the death pose, locks input and offers the Revive button
## (round 548). Told apart by the HP the report carries: a server with the
## dead state (-player-dead-state, its server half) leaves HP at 0 and makes
## no RespawnHP, while every server before it put the player back on its feet
## in the same call (session/monsterstrike.go's RespawnHP) and reported the
## respawned HP -- character.RespawnFraction of the maximum, 0.4, which is
## above 0 for any character with a maximum of 3 or more (the lowest shipped
## maximum is character.StartingMaxHP, far above it). Both the attacker's own
## OpAttackResult (player_died, player_hp) and the zone's OpMonsterAttacked
## (target_died, target_hp) are read through it, so the rule is one.
static func leaves_dead(died: bool, hp_after: int) -> bool:
	return died and hp_after <= 0
