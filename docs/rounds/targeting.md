# Targeting lane: the blow lands on the monster it was aimed at

## The report, and what it could not have been

"I think I just watched one Mangyang kill another Mangyang" -- on the public
server, v0.1.381. Server-side that cannot happen: the only damage paths are the
player's attack and the monster's counterattack on that same player
(`performAttack`), `internal/ai` is a state-machine spec that applies nothing,
`internal/world` applies no damage, and the server log for that window shows
exactly one session online. So the death was real (the player's own kill) and
the *attribution* was the client's.

## The cause, read in the client

`_on_attack_result` schedules the monster's hit reaction, its floating damage,
the skill hit effect and the monster's counter-swing `lands_after` seconds later
(the swing's own hit event), and every one of them looked up
**`_last_attack_target` at callback time** -- deliberately, per its comment,
"so a monster that died in the meantime keeps its die animation". A retarget
between the swing and its landing (a click, or the QA loop) therefore made the
*new* target flinch, take the number and swing back while the *old* one, whose
death arrived by the list sync, fell over. That is one Mangyang appearing to
kill another. `_on_monster_damaged` -- the zone broadcast the attacker also
receives -- mirrored the mistake: it played an immediate reaction on any monster
that was not the *current* target, so after a retarget the real victim would
have flinched twice.

The wire carried nothing to pin it: `AttackResult` had no monster id, though
the request did.

## The fix

- **Wire.** `AttackResult` gains `MonsterID int64`, appended after the three
  flag bytes (offset 34 after the error string, 42 bytes total). The decoder
  reads it only when present, so an older server's 34-byte result still decodes
  with `MonsterID 0`, and an older client stops at 34 and ignores it.
  `performAttack` fills it for the plain attack and the skill cast (both reuse
  the type), the "target not found" / "damage calculation failed" refusals name
  it too, and the no-combat skill reply carries the requested target.
  `TestAttackResultCarriesMonsterID` round-trips it and decodes a truncated
  (old-server) payload.
- **Client fallback.** `NetClient` keeps `_attack_targets_in_flight`: every
  `attack()` / `use_skill()` that actually went out pushes its target, every
  `OpAttackResult` pops the oldest, and a result whose `monster_id` is 0 (a
  server that predates the field) takes the popped id. Cleared on connect and
  disconnect.
- **Attribution.** `_on_attack_result` pins the hit reaction, the number, the
  effect and the counter-swing to the result's monster; a blow that killed
  plays no hit reaction (the die animation comes from the list sync). The
  result handler marks `_own_hit_until[monster]` for `lands_after + 750 ms`,
  and `_on_monster_damaged` skips its immediate reaction for a marked monster
  instead of comparing against the live target.
- **QA.** `SRREVAMP_QA_ATTACK_ALTERNATE=1` makes the attack loop swing at the
  nearest and second-nearest monster in turn, and the deferred callbacks log
  `blow lands on monster X (now targeting Y) -- animating X` whenever the live
  target has moved on.

## Measured

Render box, in-memory server built from this branch, Jangan farmland (`97\168`
at local 130,2280), fast attacks alternating between Mangyangs. Twenty-nine
deferred callbacks fired with the live target already on another monster --
`blow lands on monster 14 (now targeting 8) -- animating 14`, `counter-swing by
monster 14 (now targeting 8) -- animating 14`, `... 8 (now targeting 14) ... 8`,
and so on through monsters 17, 20, 25, 26, 27, 28, 29 -- and in every one the
animated id equals the result's monster. Under the previous code each of those
lines would have animated the "now targeting" id. Six kills in the run, each
followed by its gold and potion on the ground at the right corpse. `check`: 222
scripts load; Go: 54 packages ok.

## Not verified

The user's exact click sequence on the public server (no recording exists);
the reproduction is the same race driven by the QA loop. Nothing about the
server's combat resolution changed.
