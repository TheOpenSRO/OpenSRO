# The combat numbers: retail's CIDamageText (round 786)

What the original client draws over a body when a hit lands -- the digits, the critical, the
block and the resist words -- and how OpenSRO's client (`client/scripts/effects/damage_text.gd`,
`DamageText`) reproduces it.

Labels: **READ** (address given; `sro_client.exe` dump `/var/tmp/decomp_client`, objdump
`/var/tmp/sro_client.asm`, constants read out of the PE image with `/var/tmp/r786-dmg/peread.py`
on the render box), **MEASURED**, **INFERRED**, **OURS**, **OPEN**.

## Who makes a number

| caller | when | arguments to `FUN_00a47bf0(target, hit, noCharAttacker, arena)` | label |
|---|---|---|---|
| `FUN_00a49290` (CIDecoDamageEffect's hit apply, from `IDecoSkill::FUN_00a4f720`) | every entry of a swing's or a skill's hit block, as the hit lands | `noCharAttacker = !(attacker && attacker IsKindOf CICharactor 0xef1a5c)`, `arena = 0` | READ |
| `NetProcessInNavAndSkill::FUN_008a4b00` case 1 -> `FUN_00a56230(obj, hp, dmg)` | a state's damage tick (poison, burn, ...) | `noCharAttacker = 1`, `arena = 0`; a stack hit `{kind 0, flags 1, dmg}` | READ |
| `UI_ARENA::FUN_004de6a0(amount)` | an arena message (`UI_ARENA::FUN_0089c940`) | on the local player, `noCharAttacker = 0`, `arena = 1` | READ (what the amount is: OPEN) |

`FUN_00a49290` calls it only when **all** of these hold (the 200.0 compare at 0xa49697, the call at 0xa496c3, READ): the target's
`+0x65c & 1` (OPEN what it is), the target's `+0xbc` (OPEN), the global byte `0xec4b58` (OPEN; it
also gates the name pass, NamePlates), and **`target+0x24c < 200.0` (0xe1b8b8) or the attacker is
the local player** (`DAT_00eef5ec`). `+0x24c` is the object's distance from the local player,
written at 0x9d6f7e (NamePlates' header, READ). So **another player's fight shows its numbers
too, within 200 world units of this player**; this player's own blows show at any distance.

`FUN_00a47bf0` creates the object through runtime class `0x110a730` (**CIDamageText**, a
CIOBillboard, 0x1e8 bytes, `CreateObject` 0xa46b70), fills it with `FUN_00a47720(this, target,
hit, noCharAttacker, arena)`, and plays `snd_blocking` at the target for a kind-2 hit.

## The art (READ, `FUN_00a92f70`)

All under `Media.pk2` `interface\hitcount\`, each with a `_shadow` twin:

| table | files | size (MEASURED, DDS A8R8G8B8) |
|---|---|---|
| `DAT_0110ab40` (10 x {shadow, fill}) | `hitcount_0` .. `hitcount_9` | 36 x 60 |
| `DAT_0110ab3c[2..3]` | `critical` | 96 x 24 |
| `DAT_0110ab3c[4..5]` | `blocking` | 104 x 40 |
| `DAT_0110ab3c[6..7]` | `resist` | 280 x 100 |

The fills are white (MEASURED: RGB 255 everywhere), the shadows black and thicker. The archive
also holds `hitcount_enemy_N`, `hitcount_player_N`, `critical_enemy`, `critical_player`,
`blocking_enemy/_player`, `miss_enemy`, `miss_player`: **this client never names them** (MEASURED:
not among its strings) -- there is no "miss" display.

Each sprite is drawn twice (`GlobalDataManager::FUN_00a62860`, FVF 0x104, 24-byte vertices):
its shadow texture under `D3DRS_TEXTUREFACTOR (0x3c) = colour & 0xff000000`, then the fill under
`colour` -- READ. That the texture stage multiplies by the factor (the shadow black, the fill
tinted) is INFERRED from the white fill art and the alpha-only factor.

## Which art (READ, `FUN_00a47720` 0xa47733..0xa47771)

| hit (`FUN_00a55e00`: +9 kind, +10 hitFlags, +0xc damage, +0x10 statusBits) | art (`+0x1e4`) |
|---|---|
| kind 0 or 4, `hitFlags & 2` | 1 critical |
| kind 0 or 4 otherwise; any kind but 2 (5 knockback, 7 a wall, 8 void, ...) | 0 number |
| kind 2 | 2 blocking |
| then: `hitFlags & 0x10` and `statusBits == 0` | 3 resist (overrides) |

Sprites (0xa479e0..0xa47a37): one word sprite when the art is not 0; digits only for arts 0 and
1 and only when the damage is non-zero. So a block or a resist is the word alone, a critical is
the word and its digits, **a plain 0 (a void hit, a zero blow) is nothing**. A knockback (kind 5)
never shows its critical -- only kinds 0 and 4 test `& 2`.

## The colour (READ, 0xa47771..0xa477cf)

`cVar2 = target IsKindOf CICUser (0xef1bc0)` -- any player character, the local one included.

| attacker | on a player | on anything else |
|---|---|---|
| a character (`noCharAttacker == 0`; monsters are CICharactor too) | `0xFFFF3A3A` red | `0xFFFFFFFF` white |
| none (`noCharAttacker != 0`: a state's tick) | `0xFFFFD33A` gold | `0xFFFF713A` orange |
| the arena's call (`arena == 1`) | `0xFF3A3AFF` blue | (same) |

So the number you deal on a monster is white, the number you take is red, another player's
damage is red too, and a monster hit by anyone is white. A critical is not recoloured: it is told
by its bigger digits and the "Critical" word.

## The layout (READ)

Reference screen 1600 x 1200: `CIDamageText::vslot_009` (0xa465a0) sets `+0x164 = scale *
width / 1600` (0xde54c8) and `+0x168 = scale * height / 1200` (0xde54c0); `FUN_004f9cd0()+0x24`
is the width and `+0x28` the height (READ: the centring at funcs_010 68080, `w/2 - 150`,
`h/2 - 72`). `FUN_00a626f0` places each sprite at the projected anchor plus `pos * (+0x164,
+0x168)` with size `size * (+0x164, +0x168)`. At 1280 x 720 a plain digit is 19 x 24 pixels
(x and y scale differently off 4:3 -- as retail does).

| sprite | size (ref px) | place | source |
|---|---|---|---|
| plain digit | 24 x 40, advance 22 | centred row: `x = -w/2 - ((n-1)/2 - i) * advance`, `y = -h/2` | 0xec5c78, 0xa47b7d..0xa47b96 |
| critical digit | 36 x 60, advance 33 | the same | 0xec5c78 + 12 |
| "Critical" | 96 x 24 | centred, **45 below** the digits' centre | 0xec5c48 + 12, 0xde5538 = 45.0 |
| "Block" / "Resist" | 60 x 28 at scale **2.0** | centred | 0xec5c48 + 24/36, the +0x1a0 track = 2.0 (0xd86ecc) at 0xa478bd |

## The motion (READ)

- **Anchor:** the target's position when `FUN_00a47720` runs (`+0x74..+0x8f` copied, 0xa477dc),
  plus **20 world units** up (0xe1b830 = 20.0; the arena's: half the body's height `+0x228`),
  re-projected every frame (`FUN_00a62860`, mode 0x104): it stays at that world point; it does
  not follow the body. Not drawn when the projected depth is <= 0 or > 1.
- **Rise:** the `+0x180` track (`FUN_009c7bc0`: `t += dt / duration`, linear) 0 -> **50.0**
  (0xd851a0) reference pixels over **1.0 s**; drawn as `+0x15c = -rise * height / 1200` (up;
  the arena's goes down). The art's scale does not apply to the rise.
- **Alpha:** the `+0x1c0` track **2.0 -> 0** (0xd86ecc) over the same 1.0 s; `vslot_009` draws
  255 while it is >= 1, else `round(a * 255)`: **opaque for 0.5 s, then a linear fade to nothing
  at 1.0 s**.
- **Scale:** constant (1.0, or 2.0 for the block and resist words): no pop, no bounce.
- **Life:** the object goes after 3000 ms (`+0x3c < 0xbb9`); OpenSRO frees it at 1.0 s, when it
  is already invisible (OURS).
- **Stacking:** none. Each hit is its own object at its own target's anchor; a multi-hit skill
  separates its numbers only by the times its hits land.

The local player's own blows also shake the camera (`UI_SILKMALL::FUN_0078db50(0, 50 or 200,
500, 20 or 25)` at 0xa49602; a camera shake, INFERRED from its arguments: a critical always (200/25 under the player's `+0x2c2 == 1`, else 50/20), a plain hit only under `+0x2c2 == 1` (50/20))
-- READ, not implemented (OPEN).

## OpenSRO

- `DamageText` (OURS: a Node2D under the OverlayView CanvasLayer -- over the bloomed frame, under
  the windows, as retail draws its billboards before the UI) carries every READ value above; the
  art is read from the player's `Media.pk2` at runtime (never committed). Without the archive the
  digits fall back to the default font (OURS).
- **Where numbers come from:** each entry of a hit block (`OpAttackResult` and `OpSkillCast`, the
  0xAB suffix, `docs/protocol/skill_hit_block.md`) as it lands -- a plain swing's hits at its
  clip's own hit events (a block over the monster too); the monster's counter and
  `OpMonsterAttacked` (red; `Critical` picks the critical art, `Blocked` the word); a wall's
  blow (kind 7: a plain number); a state's killing tick (`StrikeStatusTick`, the gold colour).
- **The server (round 786):** a debuff cast's entry carries 0x10 only when the cast itself rolls
  states (a row with state runs, not linked); before, every debuff entry carried it, so the client
  would have drawn "Resist" over a linked debuff whose states land with its pulses.
- **OPEN:** another player's **plain swing** on a monster draws no number -- OpenSRO tells
  watchers only `OpMonsterDamaged` (a total, no hit kinds or crit), which is also sent for skills
  whose numbers come from the act's block; drawing it would double them. The imbue's extra
  targets of this player's own plain swing (role 1 entries) draw none either. The colour of a wall
  entry's number (retail's names the wall object, whose class was not read). The arena's amount.
  `+0x65c & 1`, `+0xbc` and `0xec4b58`. The camera shake.
