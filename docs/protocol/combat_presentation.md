# The plain fight: what retail sends and draws, and what OpenSRO does (round 785)

The basic combat loop -- a plain swing (the weapon's base attack skill), the
keep-up, a monster's swing, the hit -- read off both binaries in round 785 and
compared path by path with OpenSRO. Labels: READ (address), INFERRED, MEASURED,
OURS, OPEN. The skill casts beyond the base attack are the skill lanes'
(`skill_hit_block.md`, the cast presentation); the auto-command actor is
`auto_command.md`.

## The server (SR_GameServer.exe)

- **No second reach test (READ).** The 0x7070 command a swing posts is consumed
  by slot 383 `0x4b21b0` (the dispatch table at `0xccf110`, entry `0x4b2440`)
  -> `0x59b7c0` -> `SkillActionHandler 0x589b50` -> `Skill_BuildUseContext_B
  0x586700` (kind 0; the CH bow and EU crossbow base rows are kind 1,
  `0x5857b0`). Its gate (`push 0xffff` at `0x586790`) tests the target's
  region within one of the caster's (`0x58cc70` -> `0x430ce0`, refusal
  `0x3006`) and a navmesh line (`0x3010`); no `0x3007` constant exists in the
  binary. The reach is the actor tick's alone: `Action_IsTargetWithinReach
  0x4ad4a0`, `int(dist) <= reach + 2`, from both objects' CURRENT positions,
  never a walk's destination.
- **One swing, in order (READ, `0x586700` with CastingTime 0):**
  `Combat_ResolveDamage 0x58e5f0` fills the damage block; the kind word is
  `0x3002`; the cooldown is armed for a PC only (`0x64c700`, `0x586c03..`);
  0xB070 result 1 goes out (`0x59e8f0`) to the caster's 3 x 3 regions; then
  `EngageSkill 0x593540` lowers the target's HP AT ONCE (`0x593bbf` ->
  `0x52a240` -> `0x4a87d0(-damage)`). No 0xB071 for a CastingTime-0 row (only
  the cast-time branch sends it, `0x586d61`). The 0xB070 layout: `u8 1, u16
  kind, u32 skillId, u32 casterId, u32 castId, u32 targetId, u8 flags`, the
  damage block when flags & 1 (`skill_hit_block.md`), a position when flags &
  0xA, an f32 heading only for a command with flag 0x40 (the 12 `fitp` rows).
- **A monster's swing is the same message (READ).** `AITactics_Handler_0e8`
  `0x5472a0` -> `0x5411a0` posts `0x7070 {u32 skillId, u8 1, u32 targetId}` to
  the monster's own command source; the same slot 383 consumes it, so every
  client in view gets a 0xB070 naming the monster's AI-picked skill
  (`CRefSkill+4`). The engine's cooldown arm and its IsReady gate are PC-only
  (`0x586c03`, `0x58d8f0`): what spaces a monster's swings is OPEN (round
  546's "ReuseDelay through the action machine" is not the cooldown table).
- **No facing on the server (READ).** No attack path sets the caster's
  heading except the `fitp` rows (`0x59b56a`, slot `0x398`). Phase 1's in-reach
  call `0x4ad780 -> 0x4b03f0(0)` only drops the approach walk (correcting
  `auto_command.md`'s "face the target"). A moving Activity-2 caster is stopped
  (`0x59b6b9` -> vslot `0x4b0` -> `0x4a9430`, 0xB023).
- **Walking into reach (READ).** `MoveTowardObject 0x4b0350` only records the
  follow; `0x4b0490` (from `CGObjChar::Update` at `0x4a89e9`, at most every
  100 ms) gives up beyond 1000.0 (`0xb45c68`), does nothing in reach, re-aims a
  0x7021 to `stop` short of the target when the caster stands or its walk is
  15 degrees or more off the line (`0.2618`, `0xb462b8`) -- echoed to the view
  as 0xB021 -- and backs off when closer than the two radii less 4.
- **Cadence (READ).** Every repeat is a new 0x7070, a new context and a new
  0xB070. The arm `0x64c700`: A = CastingTime + ActionDuration, the timer
  `round(A x param140 / 100 + max(0, ReuseDelay - A))`; param 140 is 100 at
  init (`GObjPC_InitStats`, `berserk_look.md`). On the 15 base rows ReuseDelay
  equals A, so the cadence is the ReuseDelay: spear 1166 ms, sword 1200,
  punch 1500, bow 840 (MEASURED, `/var/tmp/allskills.txt`).

## The client (sro_client.exe)

- **The swing's clip (READ).** Not skilldata: skilleffect.txt `#section
  skillaniset2` (loader `FUN_00a9c470`), the SHOT list (column 9).
  `FUN_00a54be0` stores `(u8)rand()` at deco+0xe4 and the SHOT phase plays
  `list[byte % count]` -- **a random pick, not a chain** (correcting
  `BSR_FORMAT.md`). The names map to action types in `FUN_009e5240`:
  ANI_ATTACK1 2, ANI_ATTACK2 5, ANI_ATTACK3 16 (`0x10`), ANI_ATTACK4 17 (`0x11`)
  (READ, the `local_102c` writes after each name). MEASURED rows:
  `SKILL_CH_SPEAR_BASE` and `SKILL_CH_SWORD_BASE` ANI_ATTACK1..4,
  `SKILL_EU_SWORD_BASE` 1..2, a bow ANI_ATTACK1, `MSKILL_CH_MANGNYANG_ATTACK01`
  ANI_ATTACK1, `..._ATTACK02` ANI_ATTACK2.
- **The clip's speed (READ).** `CCObjAnimation::FUN_00a5b550` -> AniMixer, rate
  `obj+0x4ec = 100 / obj+0x4e8` (param 140, 100 at init): the authored speed.
  ActionDuration never reaches the clip. MEASURED: the CH spear's four base
  clips run 1733-1833 ms against its 1166 ms cadence (the sword's 1133 against
  1200), so a spear's next swing starts its clip before the last one ended --
  INFERRED the same in retail, where each 0xB070 starts a new deco.
- **When the blow shows (READ).** The SHOT clip's type-1 events reach
  `FUN_00a59970` -> `FUN_00a52fe0`, which fires the phase's next hit slot ->
  `IDecoSkill::FUN_00a4f720` -> `FUN_00a49290`, which AT ONCE lowers the HP
  (`FUN_009c78b0(-dmg)`), enters the hit reaction (state 0xb, ANI_DAMAGE1)
  only for non-zero damage of a kind other than 2 (block) or 7 (wall), the
  death (state 1) for the 0x80 bit, and draws the text. The hit SOUND waits
  100 ms more (`CIDecoDamageEffect::vslot_014`, the frame milliseconds summed
  at +0x3c against the immediate 100, then `FUN_00a49780`).
- **The text (READ, `FUN_00a47720`).** Digits (`interface\hitcount\hitcount_%d.ddj`),
  a critical label, a blocking label alone, a resist label alone; no "miss"
  and nothing for zero.
- **Facing (READ).** `CIDecoSkill::vslot_014` (`0xa503f0`) turns the caster
  toward its target every frame: `CIDecoSkill::FUN_00a56cd0(current, desired,
  frame seconds x 10.0)` (`0xe1b840` = 10.0), the shorter way, landing within
  a step. The turn is skipped when the deco's skill object (deco+0x154,
  `FUN_0093f250`'s record; its skilldata row sits at +0x774) has a non-zero
  +0x78 -- that field is OPEN. The heading f32 in 0xB070 is read only when the
  damage flag is clear and that field is set.
- **Sounds (READ).** A monster's `snd_swing1..4` (`0xa71510`):
  `<obj>:snd_swingN:<Basic_Code>:-:-:-`; `snd_swing_s1..4` (`0xa718d0`) PC
  `PLAYER:snd_swing_sN:<Basic_Group>`, others `<obj>:..:<Basic_Code>`;
  `voc_shout1/2` (`0xa72260`) PC `<obj>:voc_shoutN:-:-:-:-`, others
  `<obj>:voc_shoutN:<Basic_Code>`. The skill an animation track keys by is the
  object's current skill deco's (`FUN_009ce0d0`). MEASURED rows:
  `MOB_MANGNYANG SND_SWING1 MSKILL_CH_MANGNYANG_ATTACK01`, `VOC_SHOUT1` and
  `SND_DMG` of the same skill, `SND_SWING1/2 ... ATTACK02`; `MOB_BIGEYEGHOST`
  keyed by `MSKILL_CH_BIGEYEGHOST_CLON_ATTACK01`. No rate limit on a key (no
  clock in `vslot_009` or `FUN_00a6f7f0`).
- **Frame rate (READ).** The turn, the clip time and the 100 ms delay all scale
  by the frame's milliseconds (`DAT_0110f7f8`, clamped to 3000).

## What OpenSRO does (round 785)

Server (`session/combat.go`, `keepup.go`, `monsterstrike.go`):

- A click inside the base attack's re-use delay arms the swing for when it
  ends (`swingWait`, the keep-up's first swing) -- it was dropped with no
  reply, and the player stood idle beside the monster it had clicked
  (MEASURED: the second monster of a fight, clicked 0.5 s after the first one
  died, was never struck). A click on the monster the keep-up already swings
  at changes nothing (the 0x7074 duplicate refusal, 0x4004).
- A keep-up repeat that finds its target out of reach sends "too far away"
  naming it, after the monster's position (OURS, below); it used to end in
  silence. Every "too far away" names its monster and is preceded by
  `resyncMonster`: an `OpMonsterMoved` from where the server has the monster
  to its leg's end (a stop where it stands when it stands). OURS: retail's
  server walks the player itself; OpenSRO's client walks.
- `OpMonsterAttacked` carries the swung skill's id (a u32 after the wall block;
  the counter names the species' primary skill, characterdata col 83). The counter
  to a skill cast names it too; before the round 785 review it sent 0.
- A knocked monster's cell crossing reaches the watchers at the window's edge
  (enter / leave, as a step's crossing does; round 785 review).
- The AI trace logs both ends of a refused reach (`reach: ... refused`).

Client (`World3D.gd`, `audio_anim/anim_sounds.gd`, `world/combat_facing.gd`):

- The plain swing's clip is a random entry of the base skill's SHOT list
  (`_plain_swing_type`; the old cycle remains only as a fallback).
- Fighters turn toward their target at 10 rad/s while the swing plays
  (`CombatFacing`, `_face_while_striking`): the player on its own result, a
  monster on its push. OURS: every swing turns (the +0x78 condition is OPEN);
  a monster on a leg is left facing its path.
- A monster's swing plays its skill's clip (`_shot_clip_type`), its body's
  current skill is set so its swing and shout sounds key by the skill's
  Basic_Code, and its hit sound keys by it too.
- A monster's blow on this player moves the HUD's HP and the dead state at
  the blow's landing (the clip's hit event), not when the push arrives.
- Hit sounds 100 ms after the landing; no number and no hit reaction for a
  blow that dealt nothing.
- The keep-up's refusal walks the player back into reach and clicks again,
  at most `CombatNet.APPROACH_RETRY_CAP` (3) times without a blow between
  (`_rewalk_after_keepup_refusal`); a refusal puts the monster where the
  server's resync said it is (`_snap_to_server_pos`, OURS).
- The clip tick kept an ended one-shot in its list when the hand-back left the
  count unchanged: the one-shot "ended" again every frame and its sounds
  fired every frame (MEASURED: a struck monster's moan 20 times a second; the
  user's log, "+59 since the last line"). Fixed (`_tick_idle_animations`).

OPEN: the +0x78 field gating the deco's turn; whether a hit reaction cuts the
caster's own swing clip in retail (state 0xb has no mask, `0xec6190`, but the
deco's clip may sit on another layer); the hitcount ddj decoration (OpenSRO
draws a text number); the blocking/critical labels; what paces a monster's
swings in the engine.
