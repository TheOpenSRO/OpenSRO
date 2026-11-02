# Berserk: what it looks like, sounds like and does (round 651)

The client and server sides of body mode 1 ("Hwan", berserk), as read out of
`sro_client.exe` and `SR_GameServer.exe` on the RE box (decomps
`/var/tmp/decomp_client`, `/var/tmp/decomp_server`; asm
`/var/tmp/sro_client.asm`, `/var/tmp/srv.asm`) and measured in Media.pk2.
Labels: READ, MEASURED, INFERRED, OURS, OPEN.

## Who draws it

- READ. 0x30BF kind 4 (`FUN_008a80a0`, `NetProcessInObject.cpp` line 0xae5)
  resolves the object id and calls the object's body-mode setter
  `FUN_009cf880(mode, 0, extra)` for **any object in view**. Only after that
  does it test for the player's own id (the flash, below, and round 629's
  orb display `FUN_00778ae0(0, 1)`).
- READ. `FUN_009cf880(this, mode, arg, extra)`: acts when the mode is 1 or
  differs from `+0x2c2`. It first undoes the old mode (1:
  `FUN_009dd620(0, arg, old extra)`; 4: the render object's alpha back to
  0xff), then applies the new one (1: `FUN_009dd620(1, arg, extra)`; 4: alpha
  0x50), then stores `+0x2c3 = extra`, `+0x2c2 = mode`.
- READ. `FUN_009dd620(on, arg, extra)`:
  - on, extra 0, hwan level (`+0x764`) 0: `FUN_00a54020(0, obj, 0x80000000,
    arg, 0, 0)` -- the decoration factory with effect key 0x80000000;
  - on, extra 0, hwan level > 0: the key of `L"SYSTEM_CH_HWAN2MODE"`;
  - on, extra 1: `SYSTEM_CH_HWAN2LINK_START` on the party members, then
    `SYSTEM_CH_HWAN2LINKMODE`;
  - off: `GlobalDataManager::FUN_009cd2b0(key)` removes the object's
    decoration whose `+0x5c` is that key.
- READ. The client's name tables (static initialisers at `0xd78375..`):
  `0x00ec73f8` maps `L"SYSTEM_CH_HWANMODE"` -> 0x80000000 (then HPPOTION
  0x80000001, MPPOTION, LIFE, RETURNSCROLL, RETURNSCROLLRESULT, LEVELUP ...);
  `0x00ec7378` is the SCT_ script table: SCT_ARROW 0x1, SCT_RUT 0x2,
  SCT_MOVER 0x4, SCT_SHAKECAM0..3 and _MOV0..3 0x8..0x400, **SCT_MAT 0x800,
  SCT_CHAR_SCALE 0x1000**, SCT_EFFECT_SCALE 0x2000.

## A body that arrives berserk

- READ, client. The spawn state block reader `GlobalDataManager::FUN_009d1300`
  (vtable slot 23 of every character class) reads, after the movement:
  `+0x271` (life state), `+0x273`, `+0x272`, **`+0x470` (the body mode)**,
  `+0x254` walk speed, `+0x258` run speed, `+0x4e8` a third float, then the
  buffs. `FUN_009d17e0` applies `+0x470` with `FUN_009cf880(mode, 1, 0)`:
  arg 1 makes `FUN_00a53850` skip the start effect (round 646), so a body
  drawn already berserk gets the kept rows only.
- READ, server. `GObjPC::FUN_004a9b70` (slot 293) writes that block:
  chardata bytes 0..3 (`[3]` is the body mode `CGObjChar::SetBodyMode`
  stores), then `EvaluateParam(23)`, `EvaluateParam(24)`,
  `EvaluateParam(140)` -- or, for a PC with `+0x21a4 == 1`, the two floats at
  `+0x21a8/+0x21ac` in place of the first two -- then the buff block
  (`FUN_0059cdc0`).
- The third float is **param 140, not a berserk move speed** (READ):
  `GObjPC_InitStats` sets it to 100.0 (`0xb45e10`), and the server's only
  other reader, `GObjPC::FUN_005a1a40`, uses it as a percentage of a time
  (`(a + b) * GetParam(140) / 100.0`); the client keeps `100 / value` beside
  it (`+0x4ec`).

## The rows (MEASURED, Media.pk2 `server_dep\silkroad\textdata\skilleffect.txt`)

`#section skilleffectset`, SkillEffectID `SYSTEM_CH_HWANMODE`:

| AniType | ActType | effect | StartBone | Script | SndBegin |
|---|---|---|---|---|---|
| ACT_S | AT_ONE_FOLLOW | `system\system_hwan_motion.efp` | Bip01 | none | `player\hwanchange.wav` |
| ACT_L | AT_LOOP | `system\system_hwan_keep.efp` | Bip01 Spine | `SCT_MAT,64,16,0,140,32,0,1000` | none |
| ACT_L | AT_LOOP | `system\system_hwan_keep_s.efp` | Bip01 L UpperArm | `SCT_CHAR_SCALE,1.1,1000` | none |
| ACT_L | AT_LOOP | `system\system_hwan_keep_s.efp` | Bip01 R UpperArm, L HandMid, R Finger2, L Calf, R Calf (one row each) | none | none |
| DEACT | AT_ONE_FOLLOW | `system\system_hwan_disappear.efp` | none | none | `player\hwanreturn.wav` |

`SYSTEM_CH_HWAN2MODE` (hwan level > 0) has the same shape with
`system_hwan2_*` files, `SCT_MAT,17,80,150,60,90,250,700` (blue) and
`SCT_CHAR_SCALE,1.2,1000`. `#section skillaniset2` has one row per mode too:
DamageEfp `hiteffect\hit_4_hwan.efp`, weapon trail length 160, colour
200,255,255,255, op ONE, texture `mirage_texture_hwan.ddj` (not drawn here,
OPEN). The five `.efp` and both `.wav` are in the box's Particles.pk2 and
Data.pk2 (`Prim\Snd\Player\`).

## The colour (READ)

- The row parser `GlobalEffectManager::FUN_00a9d0f0` reads the Script cell's
  name through the SCT_ table; for 0x800 it reads six ints as two
  `0xFFrrggbb` colours and a seventh as an int; for 0x1000 a float and an int
  times `0.001` (the double at `0xdd3020`). They land at the record's `+0x78`
  (flag), `+0x80`, `+0x84`, `+0x88`, `+0x8c`, `+0x90`.
- `IDecoSkill::FUN_00a513a0` (the row apply): for 0x800 each byte / 255.0
  (the double at `0xd83108`), then the character's compound object's vtable
  `+0x48` with both colours and the ms. The class is CCompChar
  (`CObjRendererVS::FUN_00c25800`, RTTI slot 18): flag `+0x1ec` = 1, colours
  at `+0x238`/`+0x244`, ms at `+0x250`, counter `+0x254` = 0, direction
  `+0x258` = 1, current colour = colour 1.
- `CCompChar::FUN_00c26ff0(dt)` runs each update while `+0x1ec` is set: the
  current colour is `c1 + (counter / ms) (c2 - c1)`; the counter climbs by dt
  to ms, then falls back to 0, and climbs again -- a triangle wave, period
  2 x ms.
- `CObjRendererVS::FUN_00c27180` (called by the draw paths `0xbf0e48`,
  `0xbf1898`, `0xbf29ca` when the renderer's `+0xe0` is set) uploads
  `SetVertexShaderConstantF` c11 = light diffuse x colour, c10 = light
  ambient x colour, c14 = second light's diffuse x colour. The ordinary path
  (`0xbf0ff1`) uploads c11 = light diffuse x the mesh material's diffuse
  (`fld [edi]`) instead, and skips that when `+0xe0` is set. The light
  colours are the D3DLIGHT9's own (`CObjRendererVS::vslot_025`: `+4`
  diffuse, `+0x24` ambient).
- The end (`CIDecoSkill::FUN_00a53dd0`): vtable `+0x4c`,
  `CObjRendererVS::FUN_00c258b0`, clears `+0x1ec`; the next draw is the
  material's own.
- Round 855 (READ): an abnormal state's pulse is the same slot on the same
  compound (`FUN_009cd5e0` calls `[obj+0x9c]+4`'s `+0x48` / `+0x4c`), so the
  last start wins and an end ends the colour, whoever set it. Round 856
  (READ): `FUN_009cd5e0` leaves a state bit's `+0x48` / `+0x4c` out while
  the body mode `+0x2c2` is 1 -- so a berserk body poisoned keeps berserk's
  colour, the poison's end leaves it, and berserk's end leaves a state still
  on uncoloured. Both go through `BodyPulse` (`docs/protocol/status_effects.md`,
  "A state's colour" and "The colour's guards").

## The size (READ)

`SCT_CHAR_SCALE` (flag 0x1000): the apply saves the current scale
(`+0xc8`), sets the target `+0x734` = 1.1 and the time `+0x744` = 1.0 s; the
end (`IDecoSkill::FUN_00a4db00`) targets the saved scale over the same time.
The fade is linear, READ (round 651's review): each frame `FUN_009d1d60`
runs `FUN_009c7bc0` on the `+0x72c` record (t += rate x dt, clamped at 1;
value = base + t x delta) and hands `+0x72c` to the render object's scale
(vtable `+0x24`).

## The flash (READ, own player only)

`0x8a827b..0x8a82be`, for the player's own id and a non-zero mode:
`FUN_00a42d20` on the scene's weather manager (`[0xeed870]+0x120`) with the
colour (255.0, 255.0, 255.0, 128.0) (`0xd85284`, `0xd821dc`), fade time 0.2 s
(`0xda95f8`) and 0.5 s (`0xe1b7e0`) kept at `+0xc4`. The manager's update
(`CGWeatherManager::vslot_009`) sends a finished fade with a non-zero alpha
back to alpha 0, over `+0xc4` when set. While a fade runs, `vslot_010` draws
a screen quad (`FUN_00a43270`: D3DRS_TEXTUREFACTOR = the colour, SRCBLEND
SRCALPHA, DESTBLEND SRCCOLOR, DrawPrimitiveUP triangle fan) -- the screen
gets white x alpha added, up to 128/255 in 0.2 s and back in 0.5 s. The fade
starts from the manager's current colour (`FUN_00a42280` copies it as the
base). Every finished fade with a non-zero alpha goes back to alpha 0, so the
alpha starts at 0; the starting RGB is whatever the last fade left, and the
constructor's first colour (`_DAT_00de523c`) was not read, so it is OPEN.
OpenSRO draws white throughout.

## The mechanics (READ, server)

- Damage: x2 after mitigation (`berserk.DamageNumerator`, recovered
  2026-09-15; `Formula_MitigatePhysicalDamage` `GetParam(189) + 2.0`). Applied
  by `performAttack` to basic attacks and skills.
- Duration: 60 s plus param 195 (`berserk.Duration`).
- **Death does not end it (READ, round 651's review):** `GObjPC_OnDeath`
  (`0x4e6980`) and `SetLifeState` (`0x4a9c80`) call no SetBodyMode; the end
  comes with the revive (`GObjPC::Revive`, body mode 2), as OpenSRO does.
- **A teleport ends it (INFERRED):** no SetBodyMode caller sits in
  `GObjPC::HandleTeleportUse` (`0x513590`); the world-entry setter
  `CGObjPC::vslot_391` (`0x4df9e0`, body mode 2 or 4) is the one that
  replaces mode 1, and a teleport reaching it is the re-entry chain
  character-data save -> `CMainProcess::CharDataSavingCompleted` -> 0x34b5 ->
  the client's 0x34b6 (`FUN_0086e100`) -> the entry handed off and rebuilt,
  whose link from the teleport handler is still not traced. OpenSRO ends a
  running berserk on a zone change (`endBerserk`) and the mover's client drops
  its own look silently on that arrival -- no DEACT burst or sound, since the
  original meets it with a rebuilt object (`BerserkLook.end(host, true)`).
- **Speed: OPEN (the magnitude).** `CGObjChar::SetBodyMode` (`0x4a9fc0`),
  entering mode 1 on a PC, looks up the `_RefHWANLevel` row of the byte at
  `+0x1c58` (`GObjPC::FUN_004ac7d0`) and applies each `{tag, value}` entry
  (`FUN_004ab030` -> `FUN_004aaf80`, then the speed republish at vtable
  `+0x4e8`); leaving it undoes them (`FUN_004ab060`):
  - `'SPDU'` value v: `SetParam(23 walk, slot 3, v)` and `(24 run, slot 3,
    v)` -- slot 3 is the percentage scale slot (stat_graph.md), and the undo
    writes 100.0 back, so v is a percent of the base speed;
  - `'DABR'` value v: `SetParam(174..177, slot 2, ctx 3, -v)` -- params
    `'dara'` writes, reduced by v while berserk.

  Both values are `_RefHWANLevel` DB rows. Neither Media.pk2
  (`hwanleveldata.txt` is titles only, re-checked) nor the server package on
  the box (`/opt/sro-files/server/y0gi_Easy_vPLUS`, no database) carries
  them, and the client moves by the speed the server sends. So OpenSRO
  applies no berserk speed change and no DABR; the mechanism above is what a
  found value plugs into.

## OpenSRO (round 651)

- Server: `sendBodyModesInView` (session/combat.go) sends an arrival -- world
  entry (`handleEnterWorld`) and zone change (`warpTo`) -- a 0x30BF kind 4
  value 1 for each character in its zone that is berserk, under that
  character's berserk turn. OURS: the carrier (OpenSRO's spawn is not
  retail's state block).
- Client: `effects/berserk_look.gd` (BerserkLook) draws all of the above on
  any body whose body mode is 1; `World3D._berserk_apply`; NetClient keeps
  `body_modes` (WorldNet.note_body_mode) so a body built later takes it.
