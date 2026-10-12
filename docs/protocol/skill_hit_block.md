# The skill action block: targets, hits and the caster's move (round 785)

What a cast tells the clients about **whom it hit, how often, for how much, and where bodies
moved** -- retail's 0xB070/0xB071 tail, READ from both binaries, and how OpenSRO carries it. The
client lane (r785-skill-cli) builds its reader against this page.

Labels: **READ** (address given; `SR_GameServer.exe` dump `/var/tmp/decomp_server`, objdump of the
binary; `sro_client.exe` dump `/var/tmp/decomp_client`), **MEASURED**, **INFERRED**, **OURS**,
**OPEN**.

## Retail: the tail of 0xB070 (result 1) and 0xB071 (kind 1)

**The server's writer** is `FUN_0059e8f0` (0xB070; asm 0x59e8f0..0x59ea39) and the skill-act path
(0xB071), both ending in the same tail. After the cast header (`u8 1`, the skill, the caster, the
cast id) it writes, READ:

| field | width | source |
|---|---|---|
| target | u32 | the action's target uid (`[ebx+0x14]`, 0x59e985) |
| flags | u8 | `ctx+0x4c` (0x59e995): bit **1** a damage block follows, bit **2** a `tel2` move, bit **8** a `tele`/`tel3` move (FUN_005862e0 sets 2 or 8, 0x58638b/0x586473) |
| damage block | | when `flags & 1` (0x59e9a5 -> `FUN_00585730`) |
| move | u16 + 12 | when `flags & 0x0a` (0x59e9bf): `u16 region` (`rec+6`), then **12 bytes** `rec+8` = `i32 x, i32 y, i32 z` -- the landing in the region's own coordinates, truncated toward zero (`_ftol2`, 0x5866c1..0x5866ea) |
| heading | f32 | only when the action's `[+0xc] & 0x40` (0x59e9f6) -- not used by OpenSRO |

**The damage block** (`FUN_00585730`, asm 0x585730..0x58579d; per target `FUN_005856d0`, per hit
`FUN_005855f0`), READ:

```
u8  hitCount       attack record +5   (the 'mc' count; 1 when the row has none)
u8  targetCount    attack record +0x10 (the size of the target list at +8)
targetCount x {
    u32 targetUid  target record +8   (0x5856d7, 4 bytes)
    hitCount x hit (the target record's hit list at +0x58, in order)
}
```

**One hit** (`FUN_005855f0`):

```
u8 kind                      hit +5, written whole; bit 0x80 is a flag, kind = byte & 0x7f
kind 0, 4 (knockdown), 5 (knockback):
    u32 damage << 8 | hitFlags   (hit +0x20 << 8) | hit +6        (0x585664..0x585680)
    u32 statusBits               hit +8                            (0x585685)
    kind 4 and 5 only:
    u16 region                   hit +0xc                          (0x58569a / 0x5856a5)
    i32 x, i32 y, i32 z          hit +0xe, 12 bytes                (0x5856b5)
kind 7:
    u32 damage << 8 | hitFlags   (hit +0x20 << 8) | hit +6         (0x58560f..0x58562b)
    u16 wallHP                   hit +0x1a                         (0x585630)
    u16 wallMax                  hit +0x1c                         (0x585640)
any other kind: nothing after the byte
```

**The client reads exactly this** (`FUN_00a54be0` -> `FUN_00a548e0` -> per hit `FUN_00a55e00`,
READ): u32 target, u8 flags; `flags & 1` the block (u8 hits, u8 targets, per target u32 uid then
the hits); then `flags & 8` (`u16` + 12 bytes, the caster's slide) and `flags & 2` (`u16` + 12,
the caster's snap). Per hit it keeps `kind & 0x7f`, sets its "dies" flag from bit 0x80 and marks
the target object (`+0x2a8 = 1`) when it is set; `damage = u32 >> 8`, `hitFlags = u32 & 0xff`,
and the second u32. **The server writes one move block when `flags & 0x0a`; the client reads `& 8`
first, then `& 2` -- a row sets only one of them (FUN_005862e0), so the two agree.**

### What the fields mean (Combat_ResolveDamage 0x58e5f0)

| value | meaning | label |
|---|---|---|
| kind 0 | a hit that dealt damage (or a zero-damage hit of a damaging row) | READ |
| kind 2 | **blocked**: the block roll (`RollChance`, 0x58f0ef area) set it; damage 0, statusBits 0, nothing follows the byte | READ |
| kind 4 | **knockdown**: the row's `ko` (field `+0x23c`, skillparam.Field) rolled; the target is put in motion state 8 (KNOCKDOWN, target state `+0x44 = 8`) and pushed to `target + unit(target - attacker) * DAT_00b45ac8`; the u16 + 12 bytes are its new truncated position | READ (corrected in round 785's own review: the first draft of this page swapped 4 and 5) |
| kind 5 | **knockback**: the row's `kb` (field `+0x254`), only when the target accepts it (its `+600` bit 2) and the hit is not already a knockdown; motion state 16 (SKILL_KNOCKBACK, `+0x44 = 0x10`), moved `kb` value[1] units along the same line | READ |
| kind 7 | a **protection wall's** entry: the damage the wall took, its HP left (u16) and maximum (`pw` value[1]); it is a separate target entry (the wall's own object), `| 0x80` when the wall broke | READ |
| kind 8 | the blow was **absorbed** by a wall that covers its damage type (the attacker's hit; the wall's entry carries kind 8 too) | READ |
| kind 0x86 | a second roll after the first hit of the cast (`cStack_e5` set by a kill, knockback or knockdown) -- meaning OPEN | READ shape, OPEN meaning |
| bit 0x80 | **this hit killed the target** (the accumulated damage reached its HP, 0x590591) or broke the wall | READ |
| hitFlags 1 | an ordinary hit | READ |
| hitFlags 2 | **critical** (the first roll, 0x58f00c area) | READ (the client's crit text keys off it, INFERRED) |
| hitFlags \|4 | the attacker's vslot 0x100 answered 1 (an attacker state, not identified) | READ, OPEN |
| hitFlags \|8 | the action's `[+0xc] & 0x10` | READ, OPEN |
| hitFlags \|0x10 | set on one magical path (0x58fe..) | READ, OPEN |
| hitFlags \|0x20 | the ignore-defence chance (param 188, `msid`) rolled | READ |
| statusBits | `Combat_ApplyStatusEffects`' return, OR'd per hit: the abnormal-state bits this hit inflicted (`statuseffect.MaskForSlot`) | READ |
| damage | `hit+0x20`, the blow's total (both halves summed) | READ |

## OpenSRO: the same bytes as a suffix (OURS framing, retail bytes inside)

OpenSRO keeps its own result messages and **appends the retail tail** to them, so a client reads
it with a retail-shaped reader. Every id in it is the u32 uid OpenSRO already sends in its retail
messages: the low 32 bits of a character id, a monster's `combat.Hub` id. Because monster and
character ids overlap, an **OURS kinds array** follows the retail bytes.

```
ActionBlock (OURS framing):
  u8  0xAB                       marker, version 1
  --- retail tail, byte for byte as above ---
  u32 target uid                 0 when the cast names nobody
  u8  flags                      1 damage block, 2 snap, 8 slide (Ghost Walk)
  [flags & 1]   u8 hitCount, u8 targetCount, targetCount x { u32 uid, hitCount x hit }
  [flags & 0x0a] u16 region, i32 x, i32 y, i32 z
  --- OURS ---
  targetCount x u8 kind          0 a character, 1 a monster (the order of the targets above)
  u8  targetKind                 the kind of the leading target uid (0 character, 1 monster)
```

`region` is the retail region id (`(x << 8) | y`; a dungeon's region has bit 15), and x, y, z the
position in that region's own coordinates, truncated toward zero -- the same form OpenSRO's 0xB023
uses for its floats, here as i32 because retail writes i32.

**Where it rides:**

| message | where | when |
|---|---|---|
| `OpAttackResult` (0x0061, to the caster) | after the 59-byte EXP tail, the **wall suffix is always written** (13 bytes, all zero when there is no wall) and the ActionBlock follows | a skill cast that resolved a blow (one or many targets, one or many hits), a ground move, and a plain swing that hit (one target, the swing's hits) |
| `OpSkillCast` (0x00FA) phase 1 (act) | after the 43 bytes | every announced act whose cast resolved a blow or moved its caster |
| `OpSkillCast` phase 0 (start) | after the 43 bytes, **only the move** (flags 8, no damage block) | a Ghost Walk / Teleport, as retail's 0xB070 carries the move at the start |

**The skill id (OpAttackResult only, OURS, round 785 review).** After the trailer's leading-kind
byte: **u32 skillId (0 = plain swing)**. It is written whenever the ActionBlock is written in an
`OpAttackResult` and names the skill the result answers: the cast's skill id, or 0 for a plain
swing (the weapon's base attack). Chain links have no `OpAttackResult`; their `OpSkillCast`
already carries the link's id in its header. Without it, a keep-up swing's result that arrived
while a cast was pending was drawn as the cast's answer, and the cast's own result as a plain
swing. `OpSkillCast` does not append it.

A decoder that stops before the suffix decodes what it did before: an `OpAttackResult` of 59
bytes (no wall) or 72 (a wall) is unchanged; an ActionBlock is present when byte 72 is 0xAB. An
`OpSkillCast` longer than 43 bytes with byte 43 = 0xAB carries one.

The legacy single-target fields of `OpAttackResult` (`MonsterDamage`, `MonsterRemainingHP`,
`MonsterDied`, `PlayerCritical`, `MonsterID`) still describe the **first** target's **summed**
damage, so an older client keeps working.

**Kinds OpenSRO emits** (OURS which, READ shapes): 0, 2 (a block), 4 (knockdown), 5 (knockback),
8 (a void hit after the target fell in the same cast, READ 0x5905ef), with 0x80 on the killing
hit; hitFlags 1 or 2, `|4` while the caster is in HWAN, 0x10 on a debuff's effect-only hit;
statusBits from `statuseffect`. 7 (the walls) rides the wall suffix as before (a monster blow on
a player's wall); 0x86 (`ck`'s instant kill) is not emitted -- no player row carries `ck`.
**A plain swing carries the block too**: its target and its base attack's hits, plus the
running imbue's extra targets (role 1) since the round 785 review. The hits carry their kill bit,
void hits and status bits as a cast's do (`castContext.strike` / `apply`).

## Ghost Walk, Teleport and Sprint: the caster's move

READ, `FUN_005862e0` (asm 0x5862e0..0x5866ea), called from both context builders as
`EAX = tele (+0x2ec), push tel3 (+0x2f4), push tel2 (+0x2f0)` (0x586ba4..0x586bd4,
0x586f5c..0x586f8d):

- **The distance limit is value[1]** of the run (`[ptr+4]`, 0x586377 / 0x586463, a `fild` with the
  unsigned fix-up 0xb45ba4) -- Ghost Walk B lv1 `tele 500,100`: **100 world units** (= 10 m; one
  world unit is 0.1 m, AGENTS.md). There is **no** x10: the comparison is against the raw offset.
- **value[0] (500) is never read by the server** (every other use of +0x2ec/+0x2f0/+0x2f4 is a
  presence test: 0x586ba4, 0x586f5c, and the gate's 0x58e033). The client lane reads it.
- `tele` and `tel2` (no `tel3`): the point is the request's ground point (the context's position
  list, 14-byte entries `u16 region, i32 x, y, z`). **Within the limit (3-D length, `x²+y²+z²`)
  the caster lands ON the point; beyond it, at `caster + unit(offset) * limit`.** A nearer point
  is a shorter move -- retail never pushes to the full distance. Flags: `tele` 8, `tel2` 2.
- `tel3` (the Warrior's sprint): the point is the **target's** position. Within the limit the
  caster lands at `target - unit(offset) * (casterRadius + targetRadius)` on x and z (vslot 0x560,
  the two bodies' radii; the y term is multiplied by the constant at 0xb45ab0); beyond it,
  `caster + unit(offset) * limit`. Flag 8.
- Then the navmesh walk (`CRegionManagerBody::vslot_012`, skill_buffs.md "Ghost Walk"): stops at
  the first obstacle; refuses (no move, the cast fails) only off the mesh.
- The landing is stored truncated (`_ftol2`), region-local, and **applied at EngageSkill**
  (0x593540: `ctx+0x54` -> vslot 0x4c4 -> `GObjPC::FUN_0048b920`, SetPosition) -- after the row's
  CastingTime; every Ghost Walk and Teleport row has CastingTime 0 (MEASURED), so at once.
- The broadcast is the 0xB070 move block above (`flags & 8`), sent at the cast.

**OpenSRO (round 785):** `session.teleportDestination` is the clamp for `tele`/`tel2`,
`sprintDestination` for `tel3`; the landing is truncated in its region's coordinates; the move is
applied at the cast (every shipped row's PreparingTime and CastingTime are 0, MEASURED; a row with
a casting time would move at once too -- OURS); `OpSkillMove` (0x00F8, unchanged:
`{i64 characterId, i64 skillId, f32 x, f32 y, f32 z}`, world coordinates of the truncated landing)
goes to the zone with the caster, and the ActionBlock with `flags 8` rides the caster's
`OpAttackResult` and the zone's `OpSkillCast` start. OpenSRO's server has no navmesh: the client
walks the point to the first wall before it sends (r785-skill-cli), and the server's clamp is the
only distance limit, as in retail.

## Chain links on the wire (round 785; the main agent's decision, checked against retail)

Retail: each link of a chain is posted by the server's own skill tick as its own action
(`docs/protocol/skill_attack.md` "Chains") and announced by its own **0xB070** (result 1, the
link's skill id, a new cast id, the tail above). `FUN_0059e8f0` sends it through `GObjPC::FUN_00484d90`,
the 3 x 3-block broadcast that **includes the actor itself** (the same sender 0xB021 uses, round 737),
so the caster's client hears every link too (READ). The client sends only the head.

OpenSRO (`session/skillchain.go`): the head is answered as any cast is (its `OpAttackResult` with the
block; observers its `OpSkillCast`). Every **later link** reaches the caster **and** its watchers as an
`OpSkillCast` -- the start (phase 0) and then the act (phase 1), `casterId` the caster, `skillId` that
link's id, `castId` a new one; the act carries the 0xAB block. No `OpAttackResult` answers a link, and
`OpAttackResult` carries no skill id. A client draws an `OpSkillCast` naming itself only when its skill
is not the one it sent (an echo of its own request is ignored). The links' damage and deaths also go
to every watcher, the caster included, as `OpMonsterDamaged` / `OpMonsterDied`.

Timing (READ): a 500 ms budget is spent on the first durations; link i+1 posts `max(CastingTime,
ActionDuration - budget used)` after link i; the last link's AutoAttackType decides the hand-off after
its CastingTime + ActionDuration (+ the carried budget). A new cast by the same caster ends a chain
still playing (OURS: retail queues it behind, `Push` 0x4ad630).
