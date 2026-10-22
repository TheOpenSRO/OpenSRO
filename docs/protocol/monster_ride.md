# A monster's ride, die model and death effects (round 809)

skilleffect.txt's `#section characterInfo` gives some monsters a second object -- Ishade's ice crystal,
Tiger Woman's blue tiger, Uruchi's dragon, Tahomet's devil -- and others a model to die as (Mangnyang
cut in half, a tombstone in shards) and death effects. Labels: **READ** = from `sro_client.exe` at the
cited address (decompile `/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm` on the render box);
**MEASURED** = counted in the archives; **INFERRED** = a conclusion from read facts, with its basis;
**OURS** = OpenSRO's own choice; **OPEN** = not settled.

## The row (READ, `UI_ALCHEMYBOX::FUN_00a9ae80`)

Each row becomes a 0x44-byte record in a map at `0x110ab94`, keyed by the characterdata ref id (a code
ending `~NNN` expands to a range); the first row inserted is kept at `0x110ab34`. The object keeps the
record at `obj+0x728` (`icscriptobj::FUN_009e2590`). Lookup `FUN_00a95d30`: the ref id, then
`refobj+0x5c` (INFERRED the Org row: a `_CLON` finds its base row), then the first row.

| col | header | record | parsed as |
|---|---|---|---|
| 2 | Size | +0x08 | float x 0.5 (`0xe1b7d0`) |
| 3 | Ride Type | +0x18 byte | table `0xec7260`: none 0, RT_FIXED 1, RT_DUMMY 2, other 0xff |
| 4 | ride | +0x24 | `.bsr` path, "none" none |
| 5 | Die Bsr | +0x28 | `.bsr` path |
| 6 | Die Effect | +0x2c | a skill-effect id (`EVENT_DH_NACHAL_DEAD`) |
| 9 | BloodType | +0x1c | `hiteffect\<name>.efp` |
| 10 | Dead Effect | +0x38 byte | table `0xec7360`: none 0, DEFFECT_FLASH 1 |

The fields are tab-separated with empty cells kept: NPC_GOLDMINER's row, one cell short, reads "1.9" as its
Ride Type (0xff). MEASURED rides: MOB_KK_ISHADE / _CLON / STRONG / EVE (RT_FIXED, `ishade_ice.bsr`),
MOB_CH_TIGERWOMAN(_STR) (none, `bluetiger.bsr`), MOB_OA_URUCHI(_STR) (none, `uruchidragon.bsr`),
MOB_RM_TAHOMET* and MOB_RM_DEVILSAYTAN (RT_DUMMY, `*_devil.bsr`) -- 17 rows with a ride; 53 rows name a Die Bsr
(one of them MOB_TREASURE_BOX's opening box); one Die
Effect (Nachal) and two DEFFECT_FLASH rows (MOB_TK_BONELORD(_STR)).

OpenSRO: `SoundTable.parse_character_info(bytes, sizes, records)` -> `SoundTable.CharacterInfo`, the one
parse round 796's Size already used; `AudioService.character_record(code, org)`.

## The ride (READ, `CICMonster::vslot_025` 0x9d3850, asm 0x9d3a85..0x9d3c51)

- **Made** after the monster's own model, scale and appear fade: a separate world object of class
  CICRide (vtable `0xde2d44`; `CICRide : CICNonuser : CICharactor`), linked both ways (`monster+0x2ac`,
  `ride+0x2b0`), its Ride Type at `ride+0x2a9`, its model the ride `.bsr` (`FUN_009c4ec0(path, 1)`),
  started on group "cart" (`0xec62f0`, falling back to `default`) type 0, speed 1, the monster's
  position, cell and speeds copied, faded in over 2.0 s (`CIDecoAppear`). No scale call
  (`FUN_009c4510` is not called on it): INFERRED scale 1. No material index: INFERRED material 0
  (whether a Hashade's crystal takes the clone skin is OPEN).
- **Placed** every frame (`CICRide::vslot_009` 0x9dabd0): at the monster's position; type none turned
  `Ry(heading)`, types 1 and 2 the identity. The common tick then runs `ICharactor::FUN_009d05d0` on the
  rider (type none: the rider's world = the ride's `saddle` bone x the ride's world -- the COS riders'
  rule) and `FUN_009d0660` on the ride (type 2: the ride's world = the rider's world).

  | type | example | rider | ride |
  |---|---|---|---|
  | none 0 | Tiger Woman, Uruchi | on the saddle | the rider's place and heading |
  | RT_FIXED 1 | Ishade | where it stands | its place, world yaw 0, never turned |
  | RT_DUMMY 2 | Tahomet | unchanged | the rider's whole transform |

  MEASURED: bluetiger and uruchidragon have a `saddle` bone; ishade_ice and tahomet_devil do not.
  Ishade's lowest vertex is 4.5 over her origin, `ishade_ice.bms` spans y -5.34..16.66.
- **Animated** with the monster (0x9cfb40 / 0x9cfc10): every play and stop is passed with the same type,
  fades, speed and weight to the ride's `+0x9c` slot 3 / 5. A type the ride lacks leaves its clip
  (INFERRED, `FUN_00a5b550`'s miss returns 0). `ishade_ice` has only 0 (2333 ms), 4, 36, 62..66
  (MEASURED), so the crystal keeps its stand through her attacks and plays its die clip with her.
- **Gone** with the monster: the same `CIDecoDisappear`, 1.5 s (`FUN_009d3c90`).
- **Its plate.** The plate's mount path (`FUN_009d0a80`: mount `+0x22c` + 7.0) is taken only while the
  rider's byte `+0x440` is set, and its setters (`0x9ca2f0` from the COS and player spawn paths) are not
  in the monster's spawn: INFERRED a monster's plate stays over its own height (+2.0). OpenSRO keeps the
  monster's label.

OpenSRO (`client/scripts/world/monster_ride.gd`, World3D's "Monster rides and deaths"):
- the ride is assembled as a monster template (`MonsterDraw.Templates`, off the main thread) and the body
  waits for it, so the two fade in together; it hangs under the monster's body (node "Ride") -- OURS: it
  fades, culls and frees with the body;
- its skeleton is a clip-tick body of its own (`_animate_skeleton`); the monster's clip changes are
  mirrored where they are made (`_ride_mirror` from `_play_once` and `_set_monster_gait`), never polled;
- `_step_monster_rides` (each frame, from `_process`) places it by its type and seats a type-none rider;
  OURS: the seated rider keeps its class scale (champion 1.5 ...; whether the seat matrix carries it is
  OPEN);
- a monster without a ride pays one dictionary lookup at its build and an `is_empty()` test per clip
  change; no ride is drawn on the GPU crowd path (only other players use it).
- OPEN: the ride's own particle mods (tahomet_devil's `luster_tahometdevil.efp`, uruchidragon's dust)
  are not played -- the body particle work is separate; the ride's tint (`ride+0x74c` from
  `refobj+0x204`).

## The death (READ, state 1 DEAD: enter `0xa59cc0`, event `0xa59e30`)

- **The die model.** On entry, when the row names a Die Bsr: skipped only when the option byte
  `FUN_004f9ca0()+0x12e` is 0 **and** the body has its own type 36 in `default`; otherwise the monster's
  own model is replaced by the die `.bsr` in place (the world matrix saved and restored, the scale
  `obj+0xc4` re-applied), then 36 plays (in 200 ms) and 4 (0 / 200). `+0x12e` is set to the inverse of
  the selected shard entry's flag (`0x868bb3..0x868bd9`, the entry's +0x28 flag byte, server_list.md);
  the default shard's flag is OPEN. OURS: the option is on (every row's die model plays).
  MEASURED: tombstone, penon_f and planar have no 4 or 36 of their own, so they always swap.
- **Die Effect / Dead Effect** on the die clip's type-1 key: the effect id's skill-effect rows as an
  act (`FUN_00a53850`, ACT_S: `EVENT_DH_NACHAL_DEAD` is AT_SOURCE `dead_bluesghost.efp` at `Bip01`), and
  for DEFFECT_FLASH `FUN_00a42d20(&{255,255,255,128}, 0.2, 0.5)`, a CGWeatherManager colour: INFERRED a
  white screen flash at alpha 128/255; what 0.2 and 0.5 time is OPEN.

OpenSRO: `_swap_to_die_model` (the die template is asked for when the body is built; one not assembled
by the death is skipped, OURS), then the existing death (type 4 held, OpenSRO's death pose);
`_schedule_death_effects` fires at the type-4 entry's first type-1 key (MEASURED live: Nachal at 3272 ms,
Bone Lord at 4028 ms); the flash rises over 0.2 s and falls over 0.5 s (OURS).

## QA

`OPENSRO_QA_MOBS_ACT="<tick>:walk|run|stand|attack|die[;...]"` acts on every QA monster. Offline renders
(Karakoram 85/130, `OPENSRO_QA_MOBS=1 OPENSRO_QA_MOBS_CODES=<code>`): Hashade in her crystal, Tiger Woman
on the tiger (stand and run), Uruchi on the dragon, Tahomet under the devil; Mangnyang dies cut in two
and the tombstone in shards. Tests: `client/scripts/world/monster_ride_test.gd`.
