# An attack skill, hit by hit (round 785)

What `Combat_ResolveDamage` (0x58e5f0; the loop 0x58ecf0..0x590616) does per target and per `mc`
hit, the chain, the imbue and the ammunition -- READ from `SR_GameServer.exe` in round 785
(objdump; `/var/tmp/r785-skill-srv/resolve.asm` on the RE box). Implemented in
`server/internal/session/skillhit.go`. Labels READ / MEASURED / INFERRED / OURS / OPEN.

## One hit, in the engine's order (READ)

1. **Critical** (damaging rows, RollChance tag 0x43): hitFlags 2 on a hit, else 1. The chance exists
   only for a physical blow (`att` value[0] & 4): `round(p12) + round(p12 x cr[1]/100) + cr[0]`
   (the attacking row's own `cr`), divided by `1 + target p57/100`. **Magic never crits.**
2. hitFlags `|= 4` when the attacker is in HWAN (body mode 1); `|= 8` when the action's
   `[ctx+0xc] & 0x10` (OPEN).
3. Ignore-defence (PC on a non-PC, chance p188, tag 0x4d): `|= 0x20`.
4. Walls: kinds 7 / 8 (`skill_buffs.md`).
5. **Block** (damaging rows without `ck`, tag 0x42): chance `target p10 + p136..139 by type`, divided
   by `1 + attacker p56/100`; kind 2, no damage (unless the target's +0xd2c, OPEN).
6. `ck` instant kill (tag 0x48) -> kind 0x86; no player row carries `ck` (MEASURED).
7. **Damage**: mitigation; `da`; `pdmg` or `lfst`; `atca`; the area share; a damaging row's 0 -> 1.
   A zero-damage row with states keeps 0 and sets hitFlags `|= 0x10` (effect only).
8. statusBits `|=` Combat_ApplyStatusEffects.
9. **Knockdown, then knockback** (both skipped when a wall took the hit).
10. Hate (below).
11. Death: the target's accumulated damage reaching its HP sets kind `|= 0x80`.

**There is no miss**: the only rolls are tags 0x43, 0x4d, 0x42, 0x48, 0x44, 0x45. Kind 8 is also a
void hit -- a later hit after the target fell in the same cast (0x5905ef).

## Knockdown `ko` (field +0x23c) -> hit kind 4 (READ 0x58fef0..0x590162)

- Needs: the row's `ko`; the target's characterdata **Knockdown** (col 81, RefObjChar +0x258) bit
  0; its motion state not already 8; a PC not sitting / changing motion / walled; the pair's +4
  byte 0.
- Chance (`FUN_0040fcb0`, ESI = ko[0]): `min(75, max(0, round(ko[1] x 2 ko[0] / (targetLevel +
  ko[0]))))` %, 75.0 the float at 0xb45de0. SKILL_CH_SWORD_KNOCKDOWN_A_01 is [19 50]: 50 % on a
  level-19 target.
- The target moves to `target + unit(horizontal, away from the attacker) x 20.0` (double
  0xb45ac8), truncated region-local, and goes to motion state 8 (KNOCKDOWN) for
  `(KO_RecoverTime (col 82) + the row's ActionDuration) / 1000 + 0.5` s (0xb45c68, 0xb45c50).
  RefObjChar's loader (0x6a58f0) makes a Knockdown with KO_RecoverTime 0 into 3000.
- MEASURED (the client's characterdata, monster rows): Knockdown 3 on 6,112, 0 on 724 (the fortress
  war monsters, structures, some uniques), 1 on 8, 2 on 6; KO_RecoverTime 3000 on 6,126.

## Knockback `kb` (field +0x254) -> hit kind 5 (READ 0x590164..0x590350)

- Needs the target's Knockdown bit 1, this hit not already kind 4, the pair's +4 byte 0.
- Chance RollChance(kb[0], tag 0x45): a raw percent, no level term, no cap.
- The target moves `kb[1]` units the same way, and goes to motion 16 (SKILL_KNOCKBACK) for 2.0 s
  (0xb46010).

## `da`, `atca`, `lfst`

- `da` (+0x240): when the target's motion state is 8 (knocked down), each mitigated half becomes
  `trunc(da[0] x half / 100)` -- the DOWNATTACK skills ([150] on 393 rows, [125] on 10, MEASURED).
- `atca` (+0x3bc): `damage = round(damage x (1 + atca[1]/100))` when `atca[0]` meets the target's
  abnormal-state mask; all 171 player rows are [16832 50] (sleep | root | blunting | stun, +50 %).
- `lfst` (+0x400): the HP drain replaces the damage: `D = lfst[0] + getv BSHP + mwhs term`, the
  level penalty, the share; the caster heals by the result (43 Warlock LIFEDRAIN rows).

## Hate

Per hit `hate += damage`; with `tant`: `hate = round(hate x (1 + tant[1]/100)) + tant[0]` (else the
same with `tnt2`); `pwtt`/`mwtt` add weapon terms; then `x (1 + attacker p187/100)`. Delivered to the
monster's AI as OnAttacked {source, damage, hate, hatePercent}; `dtnt` subtracts.

## The imbue (READ 0x58f28d..0x58f491)

An imbue is an action-kind-3 row with Basic_Activity 1 and `att` (the `*_GIGONGTA_*` Forces).
EngageSkill files its record at book+0x1e4, and every action dispatched while it runs -- skills
and plain swings -- carries its row (0x59b480 -> ctx+0x78). Per hit of a blow whose row has
`att` value[4] != 0:

- mastery `m = p1 <= 90 ? p1 : (p2 > 90 ? p2 : 90)`, p1 = MAAT(blow), p2 = MAAT(imbue) -- the
  "second record" of `combat.ClampMasteryPercent`;
- `phys, mag = Formula_Mitigate*(defender, attacker, m)` with the imbue row as the descriptor (its
  `att` is magical: `att 8 100 16 26 100`);
- `hit.total += round((phys + mag) x blowAtt.value[4] / 100)`;
- the imbue's own states are applied (cold `fz`/`fb`, fire `bu`, lightning `es`);
- an imbue with `efr` collects extra targets a second time (role 1, their physical half zeroed):
  the lightning imbue's `efr 1 6 35 2 80 24` chains 2 more.

China rows carry att value[4] = att value[1] (Smash A 143/143, sword base 60/60); Europe rows mostly
0, so a Europe blow takes no imbue damage (MEASURED). The imbue ends by its `dura`.

## Chains (READ, the skill tick 0x4ae590, the SERVER's own CGCharAutoCommandActor)

The client sends only the head; the server walks Basic_ChainCode itself, posting each link as its
own 0x7070 command: each link runs the gate (mask 0x91: cooldown, HP/MP, the duration window), its
own context builder, its own `att`, `mc`, `efr` and states, its own Consume_HP/MP and ReuseDelay.
MEASURED: no link costs MP or has a Preparing/CastingTime; 97 links have their own ReuseDelay.

Timing: a 500 ms budget B starts with the action; a non-final link waits its ActionDuration less
what is left of B (B is spent first); the next link posts after `max(CastingTime, wait)`; the
final link waits CastingTime + ActionDuration (+ the carried B when it hands off) and applies the
hand-off. Each link is its own 0xB070 (CastingTime 0: with the damage block) -- a new cast id.

## Ammunition `cnsm` (READ 0x58e32d..0x58e3c5, 0x585add..0x585ba3)

The item in equipment slot 7 must match `cnsm` value[0] (TypeID3) and, when non-zero, value[1]
(TypeID4), with a count above 0, else 0x300e (`UIIT_SKILL_USE_FAIL_RUNOUT_AMMO`). After the blow
the count drops by `cnsm[2] x mc[1]`, sent as 0x3201 `u16 count`; at 0 the item goes. 386 player
rows (China bows (4,1,1), Europe crossbows (4,2,1) and (4,2,3)).

## OpenSRO (round 785)

| mechanic | state |
|---|---|
| per-target, per-hit blows; area targets with falloff | implemented |
| magic never crits; the row's `cr` on the crit | implemented |
| knockdown / knockback (kind 4 / 5, the move, the monster held for the time) | implemented; the monster data needs the round-785 monsters CSV (cols 81/82), otherwise 3 / 3000 (the table's own commonest values, OURS fallback) |
| `da`, `atca` | implemented |
| the imbue's add, its states, its extra chain targets | implemented (skill casts and plain swings) |
| chains, link by link | implemented: every link resolved at its own time offset |
| hate (`tant`, `tnt2`, p187) | computed and credited to a per-monster `ai.ThreatTable`; the AI's retarget by hate is OPEN (the AI lane's `mob-threat-retarget`) |
| `lfst` HP drain | implemented (`lfstDamage`; the `mwhs` term OPEN) |
| hitFlags | 1 / 2 (critical), `|4` in HWAN; 0x10 on a debuff's effect-only hit |
| void hits | kind 8 after the target fell in the cast |
| ammunition | OPEN: OpenSRO keeps no count on the worn slot-7 item (docs/TODO.md) |
