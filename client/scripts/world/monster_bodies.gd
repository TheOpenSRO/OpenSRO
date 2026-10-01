extends RefCounted
class_name MonsterBodies

## When a monster's body leaves the world. Two rules, kept apart from
## World3D so a headless test can hold them to account.
##
## The server's monster list is the whole zone (World3D._sync_monster_bodies),
## so a body whose id is missing from it is dead or gone. A dying monster is
## the exception: it is left where it fell while its own die clip (type 4 of
## its `default` group -- `die` in mangnyang's, docs/protocol/BSR_FORMAT.md)
## runs, held on the last frame -- since round 677 for its species' DecayTime
## from the death when that is known (the corpse, World3D._monster_corpse_seconds),
## after which it fades out. The hold is a deadline on World3D's
## animation clock (`_idle_anim_time`), kept per id in `dying_until`.

## Whether the body for `id` goes on this list refresh: it is not in the
## list, and no death clip holds it -- there is no hold, or `now` has reached
## it.
static func should_free(id: int, live_ids: Dictionary, dying_until: Dictionary, now: float) -> bool:
	if live_ids.has(id):
		return false
	return not dying_until.has(id) or now >= float(dying_until[id])

## The killer's own hold, set when the kill's attack result arrives.
##
## The player who landed the killing blow never hears OpMonsterDied: the
## server sends that broadcast to everyone in the zone but the attacker
## (session/combat.go performAttack, and session/gm.go's /kill, both skip
## `e.Session.ID() == sess.ID()`). The result handler then asks for the
## monster list at once, and that list no longer names the monster. So
## World3D._on_attack_result calls this BEFORE that request: the body is
## held for the rest of the swing (`lands_after`, the swing's own hit event;
## its millisecond unit is inferred, BSR_FORMAT.md "Events and walk points")
## plus the die clip's own length (`die_seconds`, the clip's
## BanReader duration). When the clip starts, World3D._begin_monster_death
## restarts the hold from the clip's real start.
##
## A later hold already on the id is kept. `die_seconds` 0 -- no die clip,
## or one of a single frame, which _play_once would not play -- sets
## nothing: there is nothing to watch, so the body goes on the next list.
##
## Residual races, disclosed rather than fixed:
## - A keep-up swing sends its OpAttackResult from the keep-up goroutine
##   (session/keepup.go autoAttack.loop), while OpMonsterList is answered on
##   the session's reader. A list reply can therefore overtake a keep-up
##   kill's result and free the body before this hold exists. This is the
##   usual kill path, not a corner: the OpAttack handler (session/combat.go)
##   swings once and then arms the keep-up ("One click is the whole fight"),
##   so every kill past the first swing comes from that goroutine. The
##   window is narrow: a list request must be handled on the reader between
##   the kill's ApplyDamage (which deletes the id) and the goroutine's
##   sess.Send of the result.
## - A GM /kill still vanishes on the GM's own screen: session/gm.go
##   refreshes the GM's list and sends the GM no died push, and no attack
##   result passes through here.
static func hold_for_kill(dying_until: Dictionary, id: int, now: float, lands_after: float, die_seconds: float) -> void:
	if die_seconds <= 0.0:
		return
	var until: float = now + maxf(lands_after, 0.0) + die_seconds
	if dying_until.has(id):
		until = maxf(until, float(dying_until[id]))
	dying_until[id] = until
