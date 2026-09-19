# Character window: every row the server can state, from the server (2026-09-19)

The UI note said thirteen rows stayed blank "because nothing on this server computes
them". By tonight the server had level, Str/Int with growth, HP/MP from the grounded
formulas, EXP on the real curve, stat points and both attack ranges -- the note was
stale and the panel was showing a single number where the client shows a range, and
that number was a fresh random roll on every open (`attackerDamage` returns
`rollDamage(min, max)`).

## The authored panel, dumped (`ifplayerinfo.txt`, 73 controls)

Value fields are the `_DAT` -- or `2` -- siblings of their labels: `TEXT_CURXP` is the
label at (32, 41) and `TEXT_CURXP2` at (96, 41) the value, likewise `NEXTXP/NEXTXP2`
and `STAT/STAT2`; `HONOR_DATA`; `STRENGTH_DAT`/`INTELLECT_DAT` with `BTN_ADDHP` (62, 109)
and `BTN_ADDMP` (62, 138) beside them -- the stat-point buttons, named for what a point
raises; `HP_DAT`/`MP_DAT` over `GAUGE_HPGAUGE`/`MPGAUGE` (`chr_hp.ddj`/`chr_mp.ddj`,
188x12); the eight combat `_DAT`s; the three job rows with grade, title, exp text and a
gauge each; `TEXT_LEVEL` across the top. The old code filled the label `TEXT_CURXP`
(no such value there) and never touched `CURXP2`.

## What the client itself does with them (`CIFPlayerInfo::vslot_012`, `0x006b8910`)

Its refresh formats `L"%d ~ %d"` for the two attack rows, `L"%d / %d"` for HP and MP
from the character block, `L"%I64d"` twice for the exp pair -- so Current/Next Exp.
are **absolute integers**, not percentages -- `L"%d"` for the plain rows, `L"%d %%"` for
the two balance rows and `L"%d%% (%d)"` for a job row, and builds the title from
`UIIT_STT_LV_LEVEL` and the level byte (`DAT_00eef5ec+0x21a`). The balance value is
`FUN_009d4d70`, a getter of a stored byte at `CICPlayer+0x20d8`, copied from `+0x868`
by `FUN_009d4d50`; where that comes from was not chased -- which is why those two rows
stay blank rather than get a formula.

## Wire and server

`CharacterStatsResult` grows an additive 28-byte tail (84 body bytes): `Str, Int,
StatPoints, PhysAttackMin, MagAttackMin, MagAttackMax, MagDefense`; a 56-byte result
still decodes with them 0 (`TestCharacterStatsResultCarriesCharacterRows`). The
builder is one function now (`buildCharacterStats`), the ranges come from
`combat.WeaponRange` for both attack types (`weaponRanges`: unarmed = the unarmed
damage, magical 0), `PhysAttack` is the range's TOP instead of a roll, and
`MagDefense` is the same armour sum as `PhysDefense` over the magical column.

New `OpSpendStatPoints 0x00F0` (name, u8 str, u8 int) applies
`GObjPC_SpendStatPoints`' rule (`0x00511470`: refused unless `s+i <= pool`, then
`Str += s`, `Int += i`, pool down by the sum; the same increment `GObjPC_SetLevel`
spends two of its five points through) via `SetLeveling`, and answers with the
refreshed stats result. `TestSpendStatPointsFollowsTheEngineRule` pins it: 4 of 3
refused untouched, 0 refused, 3 of 3 gives 23/22/0 with MaxHP = MaxHPFor(23, 2).

## Client

`HudPanels._fill_character_window` fills the rows listed in its header and wires the
two buttons once (`disabled` while the pool is empty); the title is the server's level
once its stats have arrived (World3D had been passing a placeholder 1, so the window
said "Lv 1" forever); HP/MP drive the authored gauges. `SRREVAMP_QA_SPEND_STAT=1`
presses the Str button once as soon as there is a point.

## Measured (render box, in-memory server from this branch, `--panels character --attack`, fast)

Log lines, each the server's own numbers:

    Lv 1 | exp 0 / next 118 | stat points 0 | str 20 int 20 | hp 126/200 mp 200/200 | phy 21~23 def 5 | mag 35~40 def 12
    Lv 1 | exp 97 / next 118 | ...                                        (four kills, 24 exp each)
    Lv 2 | exp 3 / next 470 | stat points 3 | str 21 int 21 | hp 214/214 mp 214/214 | phy 21~23 | mag 36~40
    spending 1 stat point(s) on Str
    Lv 2 | exp 3 / next 470 | stat points 2 | str 22 int 21 | hp 214/224 | phy 22~24 | mag 36~40

Str 21 -> 22, pool 3 -> 2, MaxHP 214 -> 224 (= 22 x 10 x 1.02), the physical range up
one at both ends (the Str reinforce), and the magical minimum 35 -> 36 at the
level-up (the Int reinforce) -- the arithmetic `WeaponRange` and `MaxHPFor` predict.
The frame (`scratchpad/charwin/charwin_440.png`) shows the same numbers in the
authored rows; the underbar's EXP 9.36% is 44/470. No layout was changed, so no
pixel comparison was made; `docs/reference/ui` carries no character reference image.

## Out of this lane, noted

The run's client log has `ObjectLoader: item\etc\drop_ch_money_large.bsr not found in
archive` (x8) and `drop_ch_bag.bsr` (x7): the ground items' drop models do not resolve
in this archive by that path -- the drops lane's, and the parent should look.
