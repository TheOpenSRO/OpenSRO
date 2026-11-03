# What using an item looks and sounds like (round 859, lane A)

The potions' red and blue swirls, the vigor potion's, the pills' water cure, a scroll's ring and
the pet potions', read out of `sro_client.exe` and `SR_GameServer.exe` on the RE box (decomps
`/var/tmp/decomp_client`, `/var/tmp/decomp_server`, asm `/var/tmp/sro_client.asm`) and measured
in the box's Media.pk2. Labels: READ, MEASURED, INFERRED, OURS, OPEN. Code:
`server/internal/session/useitem_effect.go`, `client/scripts/effects/item_use_effect.gd`.

## Who is told: 0x305C

- READ, server. `Item_HandleUseItem` (`s:0x510980`), on an accepted use, sends its 0xB04C
  reply and then builds **0x305C** (`FUN_00430a00(0x305c)` at `s:0x5110a0`) with two fields:
  `u32` the user's unique id (`iStack_cc = param_1[2]`, the PC's `+8`, read at the handler's
  top) and `u32` the used item's RefItemID (`uStack_d0`, the item's vslot 1, read before the
  use), and sends it through `GObjPC::FUN_00484d90` -- the region-scoped send that reaches every
  PC in the user's 3 x 3 blocks, **the user included** (round 749). Nothing on the way gates it
  by the item's kind: every use that answers 1 sends it.
- READ. A pet's potion used from the player's bag is an ordinary `Item_HandleUseItem` use (the
  client's 0x704C carries the COS's uid, round 805), so its 0x305C names **the player**: the
  original draws a pet potion's effect on the player, not on the pet.
- READ. `GObjPC::COS__UseItem` (`s:0x4d57b0`) sends a 0x305C with the COS's own id after a COS's
  own use (0x70C5 / 0xB0C5). OpenSRO has no such use (OPEN).
- OURS. The server's use-item handler watches its own reply through `gateway.Session.Tap`
  (a new, minimal send observer): an `OpUseItemResult` with no error is retail's 0xB04C of 1,
  and the 0x305C follows it to the equipment broadcasts' receivers (`equipObservers`, the 3 x 3
  view, the user included; another player only while its client holds the user's body). Every
  kind's path (potions, pills, scrolls, COS items, berserk potions, skill items, ...) answers
  through that reply, so none is left out.

## Which effect: 0x305C's handler (READ, `NetProcessInInner::FUN_008735d0`, c:0x8735d0)

Reads `u32 uid`, `u32 ref`. Returns at once when the ref is `DAT_00eeeb7c` -- the ref the loader
looks up by name at `c:0x83b0f5..0x83b197`: `ITEM_ETC_AUTOMOB` -- or the uid names no object
(`IGIDObject::FindObjectByID`). Then:

1. `FUN_0095d950(2, code name)`: itemeffect.txt's `#section itemcodename` rows whose state
   column is 2 (MEASURED: 0 equip, 1 unequip, 2 use, 3 time-out by the Nasrun rows' names). A
   match starts that effect (`FUN_00a950a0` -> `FUN_00a54020`) and returns.
2. By the type word (each test `!(w & 2) && (w & 0x1c) == 0xc && (w & 0x60) == 0x60`, i.e.
   TypeID1 3, TypeID2 3, then TypeID3 by `w & 0x780`, TypeID4 by `w >> 11`):
   `FUN_00666d70` 3/3/3 -> 0x80000004; `FUN_00666de0` 3/3/1 with `FUN_00871e20` /4 1 ->
   0x80000001, `FUN_00871e60` /4 2 -> 0x80000002, `FUN_00871ea0` /4 3 -> 0x80000003, /4 4 ->
   0x80000023, /4 5 -> 0x80000024, /4 9 -> 0x80000025; `FUN_00666e10` 3/3/2 with /4 1 or 6 ->
   the name `PARAM_CURE_ALL`, /4 7 -> `STATUS_CURE_COS` (`FUN_00a950a0`).
3. `FUN_00666ce0` 3/3/6 (fireworks): `FUN_00ba36d0(&DAT_00eef6d0, {ref, obj})` makes a
   firework object -- no body effect. OpenSRO's server does not use fireworks (OPEN).
4. Otherwise, when step 2 started nothing (the decoration's `+0x60` empty, c:0x8737c8): the
   item's own code name as an effect id (`FUN_00a950a0(code)`); a name with no rows starts
   nothing.

The ids' names (READ, the client's static table at `0x00ec73f8`, `{wchar*, u32}` pairs read
from the exe): 0x80000000 SYSTEM_CH_HWANMODE, 0x80000001 SYSTEM_HPPOTION, 0x80000002
SYSTEM_MPPOTION, 0x80000003 SYSTEM_LIFE, 0x80000004 SYSTEM_RETURNSCROLL, 0x80000005
SYSTEM_RETURNSCROLLRESULT, 0x80000006 SYSTEM_LEVELUP, 0x80000007 SYSTEM_APPEAR, ...,
0x80000023 SYSTEM_COS_HPPOTION, 0x80000024 SYSTEM_COS_MPPOTION, 0x80000025
SYSTEM_COS_HGPPOTION, 0x80000026 STATUS_CURE_COS, ... 0x80000035 SYSTEM_FREEPVP_CHANGE_YELLOW.
No code pushes or moves 0x80000005 (one `push 0x80000004`, at 0x8736c4; the name strings have
no code reference): SYSTEM_RETURNSCROLLRESULT is in the table only (READ, as far as constants
go; a computed id is not ruled out).

## How it plays (READ)

`FUN_00a54020(0, obj, key, 0, 1, 0)` sets the decoration's key and calls `FUN_00a53850`:
`+0xbc = 3` (the ACT_S / ACT_L pair), the start rows (`+0xc8 + 3*4`, ACT_S) for its fourth
argument 0 and the sustained rows (`+0xcc + 3*4`, ACT_L) either way, `snd_activate` with the
negative key (`PLAYER:snd_activate:-:...`, no row: silent), and -- for its fifth argument 1,
`cmp [esp+0x48],edi` at `c:0xa53bfb` -- `FUN_00a53120`, the decoration's end, at once: every
effect is let go (slot 4 with 0), so an AT_LOOP row plays its cycle out and ends
(`EfpEffect.release`). Each row that starts plays its SndBegin and SndEnd at the body
(`IDecoSkill::FUN_00a4fe70`, round 614). The handler attaches the decoration to the object
(`GlobalDataManager::FUN_009cd050`), or frees it when nothing started (`+0x60` empty).

The potion's sound is the reply's, not the effect's: `Item_OnUseItemResult` (0xB04C,
c:0x87ac14) plays `UI:snd_potion:-:-:-:-` for an accepted 3/3/1 or 3/3/2 -- the user's own
client only (round 615; `UiSounds.use_replied`). MEASURED: its effectsound row is
`ui\itpotiondrink.wav` at volume 80.

## The census (MEASURED, the box's Media.pk2: 15,338 item rows, skilleffect.txt, itemeffect.txt)

| Kind (TypeIDs) | Items | Effect id | Effect file (row) | Bone | Sound | Who sees / hears |
|---|---|---|---|---|---|---|
| HP potions 3/3/1/1 | 19 | SYSTEM_HPPOTION | `system\item_hpotion.efp` ACT_S AT_ONE_FOLLOW | none (origin) | snd_potion (user) | everyone in the 3 x 3; the sound the user |
| MP potions 3/3/1/2 | 19 | SYSTEM_MPPOTION | `system\item_mpotion.efp` ACT_S AT_ONE_FOLLOW | none | snd_potion (user) | same |
| vigor / recovery 3/3/1/3 | 20 | SYSTEM_LIFE | `system\item_life.efp` ACT_S AT_ONE_FOLLOW | none | snd_potion (user) | same |
| pet HP potions 3/3/1/4 | 3 | SYSTEM_COS_HPPOTION | `system\item_hpotion.efp` | none, on the player | snd_potion (user) | same |
| 3/3/1/5 | 0 | SYSTEM_COS_MPPOTION | no rows | -- | -- | -- |
| pet revival 3/3/1/6 | 2 | none by type; code rows: none | -- | -- | snd_potion | -- |
| berserk potions 3/3/1/8 | 7 | by code: 3 have rows (E080723_HWAN_POTION, GNGWC_WHAN, QNO_RM_FLYSHIP2_2_02), 4 none | `system\item_qt_hwan.efp` / `system\system_hwan_keep.efp` | none / Bip01 Spine | `UI\HyanGet.wav` / `skill2\usk_wizard_light_untouch_a.wav` at the body, + snd_potion | everyone; the row sound everyone |
| HGP potion 3/3/1/9 | 1 | SYSTEM_COS_HGPPOTION | `system\item_hgppotion.efp` | none, on the player | snd_potion | everyone |
| fort repair kits 3/3/1/10 | 3 | none | -- | -- | snd_potion | -- |
| purification pills 3/3/2/1 | 6 | PARAM_CURE_ALL | `skill\china\water_cure_effect_a.efp` ACT_S AT_ONE_FOLLOW, Scale MOB_BASE | Bip01 | snd_potion | everyone |
| universal pills 3/3/2/6 | 6 | PARAM_CURE_ALL | the same | Bip01 | snd_potion | everyone |
| pet pills 3/3/2/7 | 2 | STATUS_CURE_COS | `skill\china\water_cure_effect_a.efp` | none, on the player | snd_potion | everyone |
| pill bags 3/3/2/8 | 4 | none | -- | -- | snd_potion | -- |
| every scroll 3/3/3 (return, reverse, COS summons, global chat, booths, ...) | 146 + ITEM_ETC_AUTOMOB | SYSTEM_RETURNSCROLL (ITEM_ETC_AUTOMOB, ref 3664, nothing) | `system\item_returnscroll.efp` ACT_S **AT_LOOP**, let go at once | none | none | everyone |
| fireworks 3/3/6 | 11 | the firework object | -- (OPEN) | -- | -- | -- |
| hwan scrolls 3/3/13 | 4 | by code | `system\item_qt_hwan.efp` | none | `UI\HyanGet.wav` | everyone |
| devil's spirits 3/1/14 (Nasrun), the extension 3/3/13 | 10 + 1 | itemeffect.txt use rows: ITEMSKILL_*_NASRUN_AWAKE / _EXTENSION_USE | `system\avatar_nasrun01_awake01.efp` | Bip01 Spine1 | `Avatar\Avatar_Nasrun1_Awake1.wav` | everyone |
| every other 3/3/x (speed scrolls 3/3/13/1, elixirs, stones, ...) | 3,657 | none (a speed scroll's buff draws its own aura, round 796) | -- | -- | -- | -- |

itemeffect.txt has 46 rows, 11 of them use rows (state 2), all Nasrun. Every effect file above
is in the box's Particles.pk2 (the run's own log shows each one built).

## OPEN

- The Scale column (`MOB_BASE` on PARAM_CURE_ALL) is parsed by SkillEffects and not applied to
  any effect (lane B's general effect pipeline).
- Fireworks (3/3/6): the object `FUN_00ba36d0` makes; OpenSRO's server refuses fireworks.
- `GObjPC::COS__UseItem`'s 0x305C (a COS's own use): OpenSRO has no 0xB0C5 use.
