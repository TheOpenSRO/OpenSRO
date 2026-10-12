# Who a skill hits: the `efr` target collectors (round 785)

READ from `SR_GameServer.exe` (decomp `/var/tmp/decomp_server`, objdump), round 785; implemented in
`server/internal/session/skilltargets.go`. Labels READ / MEASURED / INFERRED / OURS / OPEN.
The value vocabulary (value[1] kind, [2] radius, [3] cap, [4] falloff, [5] flags) is round 265's
(`skill_params.md`); this page adds what an implementation needs.

## The dispatcher, `Skill_CollectTargetsByEffect` 0x58cb70

- Only the `efr` run whose **value[0] is 1** reaches it (the builders pass field `+0x28c`,
  0x585a3e / 0x585aa2). Runs with value[0] 2 or 3 (`+0x290`, `+0x294`) are buff-rule markers.
- Arguments `(skill, efr, role)`: role 0 for the row's own run, 1 for an imbue's run (the linked
  row, ctx+0x18 -> +0x78, pushed at 0x585aaf).
- Kind is forced to 5 (party) when value[1] is not 5/6 and value[5] is exactly 4 or 5.
- The vector's entries are 8 bytes `{u32 id, u8 role @+4, u8 share @+5}`; the primary is pushed
  first by the action prep (`GObjPC::FUN_0048d690` 0x48d8de) with share 100.

## Shared machinery (kinds 1-4 and 6)

- Candidates come from the cells within **300.0** (.rdata 0xb45c40) of the CASTER.
- Two lists per cell: the PC list (always walked) and the object list (monsters), walked only when
  **value[5] & 0x10**.
- PC list: skip the primary and the dead; bit **1** adds the caster, bit **8** hostile PCs on an
  offensive row (`FUN_00589d20`, `FUN_005a1ad0`), bit **4** the caster's party (`FUN_005a1b70`),
  bit **2** PCs outside the party.
- Object list: alive, not the caster or the primary, `vslot0x43c == 0`; an offensive row needs
  hostility, a non-offensive one needs `dtnt` and a monster.
- **Share**: b starts at `100 - v4`; each add stores b, then `b = trunc((100 - v4) * b / 100)`
  (fldcw |0xc00 at 0x58a23d). 35 % falloff: 100 (primary), 65, 42, 27, 17, 11, 7, 4.
- **Cap**: after each add, stop when `v3 != 0 && len(vector) >= v3` (the primary and the caster
  count).

| kind | collector | test |
|---|---|---|
| 1 | 0x58a020, around the caster | `dist3D(t, caster) <= casterBC + v2 + tBC`; a monster caster re-collects its own target |
| 2 | 0x58a7c0, around the primary | `dist3D(t, primary) <= casterBC + v2 + tBC` (the CASTER's BC) |
| 3 | 0x58b160, a line | aim = primary - caster, y = 0, normalised, length Action_Range (the weapon's when 0); `Skill_WithinLine` |
| 4 | 0x58b870, a line to the primary | aim = primary - caster (3-D, unscaled); `Skill_WithinLine` from the caster |
| 5 | 0x58bef0, the party | PC caster only; v5 bit 0 adds the caster; members alive (any life state with `resu`), adjacent region, same instance, `dist3D <= v2`; share 100, no cap |
| 6 | 0x58c170, a chain | R = min(v2 (v3 + 1), 450); then v3 - 1 times the candidate nearest the PRIMARY within v2 (3-D); with `eshp` and no primary, the lowest-HP% candidate becomes it |
| 7 | 0x58ca60, the monster group | monster casters only |

`Skill_WithinLine` (0x58af60): d = the horizontal offset caster -> t; pass when `|d| <= |aim| +
casterBC + tBC` and `sin(theta) |d| < tBC + v2`, theta = angle(aim, d). No cos >= 0 test: a point
behind the caster on the line passes.

## How the share scales a hit (Combat_ResolveDamage 0x58f590..0x58f5d2)

Per hit: total = the two halves + the `att` extras + `pdmg`, x `atca` when it applies, then
**`trunc(share x total / 100)`**, then the floor of 1. An imbue's role-1 targets have their physical
half zeroed. Heals with a kind-6 chain scale `v0`/`v2` by the share too (0x59431b..0x594438).

## MEASURED (the ENC export, 6,115 player rows)

| efr (v1, v5) | rows |
|---|---:|
| (2, 24) area around the target | 595 |
| (3, 24) line | 251 |
| (1, 24) area around the caster | 207 |
| (1, 5) -> party | 166 |
| (4, 24) line to the target | 115 |
| (6, 24) chain | 99 |

## OpenSRO (round 785)

- `collectSkillTargets` builds the list for every player cast at a monster: kinds 1, 2, 3, 4, 6
  over the zone's monsters (the object list, bit 0x10); the PC list adds nobody to an attack (no
  player-versus-player outside duels, OURS).
- Order: retail adds in cell and list order; OpenSRO adds the **nearest first** (OURS stand-in).
- The share scales each hit (`areaShare`), the cap and falloff are retail's.
- Party heals and buffs (kind 5, kind 6 with v5 4/5) are in `skillsupport.go`.
- OPEN: kind 7 (monster casters), the PC-target branches (PvP).
