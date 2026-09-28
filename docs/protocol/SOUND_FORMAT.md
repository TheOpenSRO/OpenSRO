# Sound: the retail tables, the formats, and the client's audio contract

Recovered 2026-09-27 (rounds 611-612) from `sro_client.exe` on the render box (decompile
`/var/tmp/decomp_client`, asm `/var/tmp/sro_client.asm`) and measured on the real archives.
Every fact carries a label: **READ** (from the exe or a data file), **MEASURED** (counted or run
against the archives), **INFERRED** (reasoned, not observed), **OURS** (this client's choice).
The research notes, with every address, are the audio research round's `audio_spec.md`,
`sec_A.md` and `sec_B.md`; the evidence dumps are under `/var/tmp/raudio/` on the box.

## The contract (round 611)

Rounds 2-5 of the audio plan -- music, footsteps and animation sounds, combat and skill sounds,
interface sounds and the option window -- code against this and nothing else:

```
AudioBank.stream(path: String) -> AudioStream          # "prim\snd\...wav" (Data.pk2) or "x.ogg" (Music.pk2 root), cached
SoundTable.play_key(key: String, pos = null, obj = null) -> void   # effectsound key: random pick, blank counter, cull, falloff
SoundTable.play_file(path: String, pos = null) -> void # a plain Data.pk2 path at row volume 1.0
AudioOptions { bgm, effect, env: int 0..100; bgm_muted, effect_muted, env_muted: bool } -> bus volumes
Buses: "BGM", "Effect", "Env", each sending to "Master"
```

| Name | File | What |
|---|---|---|
| `AudioBank` (static) | `client/scripts/audio/audio_bank.gd` | `stream(path)`, `looping(path)`, `read_table(archive, path)`, `wav_from_bytes(bytes)` |
| `SoundTable` (static) | `client/scripts/audio/sound_table.gd` | `play_key`, `play_file`, `set_listener(node, facing)`, `sound_object(refobj_code)`, `make_key(object, handle, skill, e1, e2, e3)`, `has_key`; the parse and the volume law |
| `AudioOptions` | `client/scripts/audio/audio_options.gd` | the six values, `load_saved()`, `save()`, `apply_to_buses()`, `slider_db(v)`; bus names `BUS_BGM`/`BUS_EFFECT`/`BUS_ENV` |
| `AudioService` | `client/scripts/audio/audio_service.gd` | the autoload node **`Audio`** (`project.godot`) behind the static calls; `AudioService.instance()`; `set_options(o)` applies and saves |

- **Keys are exact.** The table stores the handle lowercased and the skill token uppercased
  (READ), so build a key with `SoundTable.make_key(...)`; `-` is a literal token.
- **`pos`** is a world `Vector3`; **`obj`** a `Node3D` whose `global_position` is used when `pos`
  is null (retail plays a character's sounds at the object's position). Neither: a 2-D sound at
  full distance volume.
- **A miss is silent**, with one `AUDIO:` log line per missing archive, file or key.
- **The listener** (OURS; retail's is OPEN): distances from the node given to `set_listener` --
  World3D gives the player -- and left/right from the `facing` node, World3D's camera. A
  character's own sounds therefore always sit inside the 100-unit full-volume radius.

## Archives and formats (MEASURED)

| Archive | Audio |
|---|---|
| `Music.pk2` | 45 Ogg Vorbis files, flat at the root; stereo, 44.1 kHz except `roc_bgm_total.ogg` (48 kHz). 7 CP949-named duplicates of English-named files are never referenced. |
| `Data.pk2` | 2,961 `Prim\Snd\<dir>\*.wav`, all RIFF PCM (format tag 1): 16-bit mono/stereo at 22,050 / 24,000 / 44,100 Hz, three 8-bit files (`UI\questopen`, `ENV\day_bird01`, `event\winter_princess\winter_princess_kiss`) and four 24-bit files (`event\winter_snow\*`). |
| `Media.pk2` | the tables only (below); `Map.pk2` and `Particles.pk2` hold no audio. |

Godot 4.2.2 loads them at run time (MEASURED on the box, `client/tools/probe_audio.gd`):
`AudioStreamOggVorbis.load_from_buffer` (static) for the music (`jangan_town.ogg` 63.97 s,
`maintheme_cut.ogg` 120.19 s), `AudioStreamWAV` for the rest. 8-bit WAV is unsigned (RIFF, READ)
and Godot's 8-bit is signed (INFERRED from its mixer), so each byte is XORed with 0x80; 24-bit
keeps the top two bytes of each sample. The `data` chunk is found by walking the chunks.

## effectsound.txt (READ; parser `CGEffSoundBody::vslot_008`, 0xa75020)

`Media.pk2 server_dep\silkroad\textdata\effectsound.txt`, 712,683 bytes, CP949 with CRLF. The
Korean is only in comments and the description column; the parse works on bytes (checked: no
CP949 trail byte is a space, tab or `/`). The `resinfo\` copy is older and not loaded (INFERRED).

```
//  object  handle  skill_ID  event1  event2  event3  blank  folder  filename  volume  description
    ITEM    SND_EQUIP  -      SWORD   -       -       0      ui\     itSword.wav  80  ...
```

- Space and tab both separate; rows start with a tab. `//` runs to the end of the line; `/* */`
  blocks are skipped (the shipped file has none, MEASURED).
- **Key** = the first six tokens joined with `:` (`DAT_00dd28a0`); handle lowercased
  (`__strlwr_s`), skill uppercased; object and events as written.
- **Several rows share a key**; a trigger takes row `rand() % n`.
- **`blank`** (entry +0) with a counter (entry +2, from 0): a trigger decrements the chosen row's
  counter, the row sounds when it goes negative, and the counter resets to `blank` -- the first
  trigger plays, then every `blank + 1`th. Non-zero: SND_STAND 2-23, VOC_MOAN 3, SND_SWING1/2 1.
- **Volume** = `clamp(atoi(col), 0, 100) / 100` (the double 100.0 at `_DAT_00e1b7d8`); `-` is 0,
  and one row's 200 is 1.0.
- **Path** = `("prim\snd\" + folder + filename)` lowercased.
- MEASURED on the shipped file: **6,004 rows under 5,428 keys**, parsed in 136 ms on the box. One
  more row has nine tokens (a `MOB_JUPITER_BABILION SND_STAND1` row missing a column) and is
  skipped (OURS; its key would end in the blank column's `0`, which nothing builds, so it could
  never play -- INFERRED). 24 rows carry `-` for a filename (13 `PLAYER SND_SWING4`, 8
  kangaroo-pet voices, two `PCF_KANGSI` sit/stand, one `MOB_FW_BATTLEGOLEM SND_DEATH`); they
  parse, and are silent when picked, as a missing file is in retail.

**skilleffect.txt `#section characterInfo`** (READ; wide tokenizer, `FUN_00a9ae80`):
`server_dep\silkroad\textdata\skilleffect.txt`, UTF-16LE with a BOM (MEASURED: `ff fe`, 4,539,278
bytes). Column 1 is a characterdata code, column 2 its sound object (`MOB_CH_MANGNYANG ->
MOB_MANGNYANG`, `NPC_CH_SMITH -> PLAYER`). MEASURED: 1,484 rows, 1,447 codes; one code
(`MOB_ANTHEIA_DESERT_KHULOOD_DARK`) is listed twice with different objects and the later row
wins here (OURS; retail's map insert order not read).

## Playing a key (READ; `FUN_00a6f7f0`, `CPrimSound::FUN_00c1ebb0` + `vslot_002`)

In this order:
1. **Cull.** A positioned sound whose squared distance from the listener exceeds 360000.0
   (`_DAT_00da98fc`, 600 units) is dropped -- before the pick, so it spends no counter.
2. Look the key up; a miss is silent.
3. Pick `rand() % n`; apply the blank counter.
4. **Volume**, in hundredths of a dB, with near 100 and far 300 (`CGame::vslot_007` at 0x841c41,
   floats 0xd85154 / 0xd85224) and floor F = -3000, ceiling C = 0 (0xbc1a78):

```
d       = |src - listener|                    # prim+0x7c scale INFERRED 1.0
distMB  = 0 for d <= 100; F + (1 - (d-100)/200) * (C - F) up to 300; F beyond
optFrac = (effectMB - F) / (C - F)            # effectMB = 20*slider - 2000
vol     = F + int((distMB - F) * optFrac * rowVolume)   # rowVolume = prim+0x80, INFERRED = column/100
played only if vol > F
```

   A 2-D sound takes distMB = 0 (INFERRED). Effect muted: nothing plays.
5. **Pan** = `int(lateral / 300 * 10000)` DirectSound units, lateral = the source's signed
   distance from the listener's forward line in XZ; every buffer is created with caps 0xC0
   (pan and volume only; `CPrimSound::vslot_001`, 0xc1ee40), so nothing is 3-D in DirectSound's
   sense.
6. **Voices.** Each loaded sound owns N duplicated buffers; a play takes the first idle one, or
   restarts a random one when all are busy (`FUN_00c1db70`). N is OPEN.

How this client does it (OURS, labelled in `audio_service.gd`): a 2-D sound plays on an
`AudioStreamPlayer`, a positioned one on an `AudioStreamPlayer3D` with Godot's attenuation off;
the Effect bus carries the slider and each voice plays at `vol/100 - bus dB`, so voice plus bus
is retail's number; the 3-D voice is placed on the unit circle around the camera at
`sin = pan / 10000`, so Godot's panner is fed retail's pan number but applies its own gain law,
not DirectSound's; `VOICES_PER_SOUND = 4`; the pick uses Godot's `randi()`.

## Options (READ; `CIFOption_Audio`, audio_spec section 7)

Three rows, BGM / Effect / Environment, each a 0..100 slider (step 1) and a mute box; no master
volume. A slider sends `20*v - 2000` hundredths of a dB (`FUN_00835380`): **dB = v/5 - 20**.
Mute sends -10000 (silence; BGM stops and restarts from the top on un-mute). Defaults
(constructor 0x848cb0): **BGM 30 (-14 dB), Effect 50 (-10 dB), Env 50 (-10 dB)**, unmuted.
OURS: saved in `user://settings.cfg` under `[audio]` (`bgm`, `effect`, `env`, `bgm_muted`,
`effect_muted`, `env_muted`), not retail's `Setting\SROptionSet.dat` (layout not read). The
values are ints and bools; a string there would have to be quoted (round 583).

## Zone music and ambient (round 612)

`client/scripts/audio/`: `EnvSoundTable` (the parse), `ZoneMusic` (the music state machine),
`AmbientBeds` (the ambient tick), `MusicDirector` (the node, child `Music` of the `Audio`
autoload: `Audio.music`). World3D calls `Audio.music.set_area_at(region_x, region_y, local_x,
local_z)` every tenth tick and `enter_loading(reason)` on world entry and on a zone change;
Login calls `play_intro()`.

### effectenvsnd.txt (READ; second half of `CGEffSoundBody::vslot_008`, 0xa75020)

`Media.pk2 server_dep\silkroad\textdata\effectenvsnd.txt`, 24,458 bytes, CP949, CRLF.

```
<1>	Jangan
//	"halloween_bgm.ogg"
	"Jangan_Town.ogg"
	<2>	낮                        (CP949 B3 B7: the day list)
			<3>	"day_wind.wav"	0~0
			<3>	"day_bird01.wav"	15~30
	<2>	밤                        (CP949 B9 E3: the night list)
			<3>	"night_wind.wav"	0~0
```

- `<1> name` opens a zone; the **next non-comment line**'s quoted name is its music, optionally
  followed by a repeat count (0 or absent: -1, loop for ever; no line sets one). A later
  duplicate zone replaces the earlier (`Asia_Minor` appears twice; the second wins).
- `<2>` picks the day or night list by the CP949 label bytes; `<3> "file.wav" a~b` is an entry
  under `prim\snd\env\`. Tokens split on `=` `"` `,` space and tab; `//` and `/* */` are comments.
  OURS: a quoted name is kept whole (`ENV\bell towel 3.wav` has spaces), and an unknown label
  logs and skips where retail asserts.
- MEASURED (`probe_audio.gd`): **59 zones, 561 live entries, 117 beds** (the research counted
  569 entries over all 60 blocks; the replaced first `Asia_Minor` block holds the other 8).
  Every zone name exists in the English regioninfo.txt. Jangan and Bandit_Fortress both play
  `Jangan_Town.ogg`. 11 referenced music files and 5 `kk_*` wavs are not in the archives; they
  are silent, as in retail.
- `Media.pk2 config\option.txt`: `IntroBGM = "maintheme_cut.ogg"` (READ; parsed at 0x84762d).

### Which zone (READ; `CRegionManagerBody::vslot_024`, 0x414600)

The region's first `RECT` claim containing the region-local position (inclusive), else its
`ALL` zone -- `RegioninfoReader.zone_for_position`. The names are the **English** table's:
`Data.pk2` root `regioninfo.txt` (65 sections, 61 names; md5-identical to Media.pk2's
`server_dep\silkroad\textdata\regioninfo.txt`), `RegioninfoReader.ENGLISH_PATH`, read by
`ParsedTable.zone_name_for_position`. The zone label keeps reading `Shader\regioninfo.txt`
(`SHADER_PATH`). MEASURED: Jangan's spawn (97/168, local 1002, 1020) is `Jangan`; 96/168 is
`Jangan_Field`.

### Music (READ unless marked; `ZoneMusic`)

- SetArea (vslot_026, 0xa732d0) does nothing for an unchanged area. On a change it stops the
  ambient; an **unknown zone leaves the music playing**; a known one calls PlayBGM, which
  **does nothing for the track already current** (FUN_00a67d70).
- A change while music plays **fades out in 10 steps**, linear in hundredths of a dB from the
  BGM volume to -30 dB (FUN_00bb6640), then **hard-starts** the new track at full volume: no
  crossfade, no fade-in. From silence it starts at once. The step pacing is one quarter of the
  1 s stream buffer, about **2.5 s** in all (INFERRED; `FADE_STEP_SECONDS = 0.25`).
- Four override levels (PushBGM +0x54 / PopBGM +0x5c): 0 the title's IntroBGM
  (`CPSTitle::OnCreate`, 0x86be78), 1 `fortress_war.ogg` (siege), 2 a record's BGM (table not
  read), 3 a script's `S_SetBGM`. `Audio.music.push_bgm(name, level)` / `pop_bgm(all, level)`
  are the hooks; only level 0 is used yet. Server, character select and create touch nothing,
  so the title music keeps playing through them (INFERRED).
- The loading screen (FUN_0084ab20) stops music and ambient, clears the area and pops every
  level: **silent**, and the first world frame starts the zone's music from the top.
- BGM mute stops the track; un-mute restarts it from the top.
- OURS: tracks loop seamlessly (retail replays on its end-of-track message after a zero tail,
  a 0.25-0.5 s gap INFERRED); a level keeps one entry per name; World3D asks every tenth tick,
  not every frame; the area is not resolved while the loading screen is up.

### Ambient (READ unless marked; `AmbientBeds`)

- On an area change the zone's day or night list starts: `0~0` entries loop (beds); every other
  entry is a one-shot with a countdown from `a`. Every **2 s** tick (timer id 1 / 2000 ms; that
  it drives vslot_005 is INFERRED) a countdown below 3 plays once and resets to
  `rand() % (b - a) + a`, otherwise loses 2: `a~b` is seconds.
- Everything is 2-D at the one Env volume; no per-entry volume. Day is game hour 4..20
  (`h < 4 || h > 20` is night, FUN_0084ac90), chosen only at an area change.
- **The clock:** this client has no game clock (the server's 0x34be time sync is neither sent
  nor handled; `docs/protocol/game_clock.md`), so **the day list always plays** and the log
  says so once. `Audio.music.set_game_hour(h)` is the hook for a clock.
- OURS: the tick's phase restarts at each zone entry; Env un-mute restarts the beds (retail
  leaves them silent until the next area change, a bug read at 0xa6e36c and not copied).

### Log lines

As printed by the box's live runs (round 612; `docs/RE_COMPLETION.md` has the runs):

```
AUDIO bgm: title -> maintheme_cut.ogg
AUDIO bgm: maintheme_cut.ogg playing=true at 0.99 s of 120.19 s (player volume 0.0 dB on the BGM bus)
AUDIO bgm: Jangan -> Jangan_Town.ogg (start)
AUDIO clock: this client has no game clock -- the day ambient list plays (retail: night is hour < 4 or > 20)
AUDIO ambient: Jangan day: beds ["day_wind.wav"], 6 one-shots
AUDIO bgm: Jangan_Field -> Jangan_Field.ogg (fade out Jangan_Town.ogg over 2.5 s, then start)
AUDIO bgm: loading (zone change) -- Jangan_Town.ogg stops, the loading screen is silent
AUDIO bgm: Donwhang -> Donwhang_Town.ogg (start)
AUDIO ambient: Donwhang one-shot donhwang_wind04.wav first play, next in 14 s
```

and, from the code, for the other outcomes: `AUDIO area: <from> -> <to>: same track <file> keeps
playing`, `AUDIO area: <zone> has no sound record -- the music keeps playing (<file>)`,
`AUDIO bgm: <file> is not in Music.pk2 -- silence ...`.

## Combat and skill sounds (round 614)

`client/scripts/audio/`: `CombatAudio` (the keys, pure), `SkillAudio` (the skill tables, the
skill context and the cast sounds), `AudioLog` (one rate-limited `AUDIO ...` line per fired
sound, OURS: a tag prints at most once a second and the next line counts the repeats). World3D
fires them; the animation-fired sounds (swings, voices, footsteps) are the `.bsr` tracks' and are
not here.

### The handlers (READ)

All go through `CGEffSoundBody::vslot_009` (0xa72a70) as (handle, object, skill); every handler
plays at **its object's own position** (`FUN_00a64900(out, obj+0x90, ...)`).

| Event | Caller | Handle | Object |
|---|---|---|---|
| a damage decoration starts | `CIDecoDamageEffect::FUN_00a49780` | `snd_cridmg` if the hit's flags `& 2`, falling back to `snd_dmg` when it returns 0; `snd_ddmg` when the decoration's +100 is set | `FUN_00517250(deco+0x70)` (+0x74 for ddmg); skill deco+0x6c |
| a blocked blow (damage record byte +9 == 2) | `FUN_00a47bf0` | `snd_blocking` | the struck object, skill 0 |
| a skill decoration activates | `FUN_00a53850` | `snd_activate` | the caster, its skill |

deco+0x70 is the **attacker** (INFERRED: all 212 non-player `snd_dmg` rows are keyed by that
monster's own attack skill, MEASURED), so a hit sounds **at the attacker**.

| Handle | Player character (`PLAYER`) | Anything else (`<obj>` = obj+0x664) |
|---|---|---|
| `snd_cridmg` (0xa70410) | `PLAYER:snd_cridmg:-:-:-:-`, berserk `PLAYER:snd_cridmg:-:HWAN:-:-` | `<obj>:snd_cridmg:<code>:-:-:-` |
| `snd_dmg` / `snd_ddmg` (0xa708f0 / 0xa70f30) | `PLAYER:snd_dmg:<group>:-:-:-`, then only if that key is missing `PLAYER:snd_dmg:<WEAPON>:-:NORMAL`; berserk `PLAYER:snd_dmg:-:HWAN:-:-` alone | `<obj>:snd_dmg:<code>:-:-:-` |
| `snd_blocking` (0xa70280) | `PLAYER:snd_blocking:-:-:<NORMAL\|CRITYCAL>:-` | nothing |
| `snd_activate` (0xa71c10) | `PLAYER:snd_activate:<group>:-:-:-` | nothing |

- `<group>` / `<code>`: the skill's Basic_Group / Basic_Code after following the +0x5c link to 0
  (`GEffSound::FUN_00a65180`), `-` (DAT_00d81ea0) with no skill. The link is skilldata's
  Basic_Original, column 6 0-based (INFERRED: `GSKILL_CH_SWORD_BASE_00n` carry 2, the id of
  `SKILL_CH_SWORD_BASE_01`; every China mastery skill 0).
- "Missing" is exact: `FUN_00a6f7f0` returns 0 only for a key not in the table; a culled or
  blank-skipped trigger returns 1.
- `<WEAPON>`: slot 6's TypeID4 through `FUN_00a64560` -- 2,7 SWORD; 3 BLADE; 4 SPEAR; 5 TBLADE;
  6 BOW; 8 TSWORD; 9 DUELAXE; 10,15 WAND; 11 STAFF; 12 CROSSBOW; 13 DAGGER; 14 HARP; 16 HAMMER;
  any other `""`; `PUNCH` with the slot empty (`FUN_00a648d0`).
- **The weapon key has five tokens.** The asm (0xa70b10-0xa70b43) appends the weapon to the
  prefix `PLAYER:snd_dmg:` and then the literal `:-:NORMAL` (0xde6534): `PLAYER:snd_dmg:SWORD:-:NORMAL`.
  The table's weapon rows load as `PLAYER:snd_dmg:-:SWORD:-:NORMAL`, so **the fallback never
  finds a row**; nor do the `- HWAN <weapon> -` rows against `PLAYER:snd_dmg:-:HWAN:-:-`.
  (audio_spec 5 and sec_B wrote the weapon key with six tokens; the asm has five.) INFERRED: in
  retail every blow carries a skill, so the group key is what sounds.
- CRITYCAL on a block is `obj+0x441 & 2` (`FUN_00a63560`); that it is the blow's critical flag is
  INFERRED (bit 2 is the critical in the damage record's flags too).

### What this client feeds them

- **The player's blow** (World3D `_audio_blow_lands`, when the swing's hit event lands and the
  number shows): object `PLAYER`, at the player. The skill is the cast's, or for a plain swing the
  weapon's **base attack** -- the retail server's `g_DefaultAttackSkillByTID4`
  (`SkillBook::DefaultAttackSkillIDForWeaponTID`, 0x0059e650; `combat.BaseAttackSkillFor`, READ in
  round 256), mirrored as `CombatAudio.BASE_ATTACK_SKILL`: the server resolves a swing to it and
  retail's decoration carries it, while srrevamp's OpAttackResult names no skill. Critical is
  `AttackResult.player_critical`, berserk `berserk_active`. No hit sound for a blow that dealt
  nothing (INFERRED: no damage decoration). A sword swing therefore plays
  `PLAYER:snd_dmg:SKILL_CH_SWORD_BASE:-:-:-` (the six `batSwordHit*` files, MEASURED), a Smash
  `PLAYER:snd_dmg:SKILL_CH_SWORD_SMASH_A:-:-:-`. A bare hand's group is `SKILL_PUNCH`, while the
  table's punch rows say `SKILL_PUNCH_BASE` (MEASURED): **a bare-handed hit is silent**, as the
  keys say it is in retail.
- **A monster's blow on a character** (`_audio_monster_blow`, when its strike lands): the
  monster's sound object (`SoundTable.sound_object`) at the monster, with skill `-`, because the
  server names no monster attack skill. Every monster hit row names one (MEASURED), so this is
  **silent and logged** until the server sends the skill (OPEN).
- **A block** (`_audio_block`): the player's shield stopped the counter (`player_blocked`, or
  OpMonsterAttacked's blocked flag for any character), at the blocker, when the monster's blow
  would land; CRITYCAL from the blow's critical flag (INFERRED, above).
- **`snd_ddmg`**: no caller. srrevamp has no absorbing skill (ice wall, screens), so the client
  never learns of such a blow (OPEN). `CombatAudio.play_ddmg` is ready.
- **`snd_activate`**: when the server accepts a cast (INFERRED for the moment, below). Its only
  rows are five `SKILL_CH_BOW_NORMAL_*` and two rogue stealth skills (MEASURED).

### skilleffect.txt `#section skilleffectset` (READ; loader `GlobalEffectManager::FUN_00a9d0f0`)

UTF-16. The file's own header names the columns; 0-based: 1 SkillEffectID, 2 AniType,
3 StartEvent, 26 SndBegin, 27 SndEnd (SkillAudio reads SndBegin's index off the header). The
loader files a row under its skill at +0xbc + AniType*4 (`SETOE.m_byAniType <
MAX_SKILL_EFF_TABLE`, 10), then by StartEvent. AniType names, the table at 0xec7158: **READY 0,
WAIT 1, SHOT 2, ACT_OS 3, ACT_OL 4, ACT_OE 5, ACT_S 6, ACT_L 7, DEACT 8, S_RETURN 9**.

- `IDecoSkill::FUN_00a4fe70` plays a triggered row's +0x98 and +0x9c paths through the sound
  manager's play-a-file slot (+0x30) at the caster, volume 1.0. That they are SndBegin/SndEnd is
  INFERRED (the last two dwords of the 0xa0-byte row filled in column order). A row whose ushort
  +0x10 is non-zero is queued on a moving-object list instead (READ; its column not read; played
  at once here, OURS).
- Path = `prim\snd\` + SndBegin: MEASURED, all 179 distinct values exist under Data.pk2
  `Prim\Snd\`.
- A skill's rows: SkillEffectID = its Basic_Group for 249 of 287 `SKILL_CH_` ids, its Basic_Code
  for 4 (the `_BASE_01` attacks), the rest outside the six tables read (MEASURED); looked up by
  group, then code, after one Basic_Original step (`FUN_00a95dc0`).
- 6,268 rows with a named AniType; SndBegin on 991 (MEASURED): SHOT 402 (StartEvent 0: 88, 1: 269, 2+: 45), ACT_S 310,
  READY 190, ACT_L 59, DEACT 23, S_RETURN 13, WAIT 12, ACT_OS 8, ACT_OL 6.
- `FUN_00a53850` (the activation) triggers the rows of AniType 3+s and 4+s, s = 3 (ACT_S/ACT_L)
  or 0 (ACT_OS/ACT_OL), then `snd_activate` (READ).

**When this client fires a phase** (INFERRED / OURS: retail runs them off the server's
skill-action messages and the clip's events, which srrevamp does not have):

| Moment | Rows |
|---|---|
| the cast starts (clip starts, OpUseSkill sent) | READY; SHOT with StartEvent 0 |
| the blow lands | SHOT with StartEvent 1 |
| the server accepts the cast (same moment) | `snd_activate`, ACT_S, ACT_L (the s = 3 path; ACT_S/ACT_L are 1,418 of 1,452 rows of the four types) |
| never (OPEN) | WAIT, SHOT StartEvent >= 2 (no China skill has one), ACT_OS/OL/OE, DEACT, S_RETURN, every SndEnd |

A cast logs the rows it leaves out once (`AUDIO cast: skill <id> rows this client does not fire`).

### The API for the animation-fired sounds

`snd_swing_s1/2` and `voc_shout1/2` key by the object's **current** skill (vslot_009 with skill 0
uses `FUN_009ce0d0`, READ). World3D records it; the `.bsr` track handlers read it:

```
SkillAudio.set_current(obj: Object, skill_id: int)      # World3D: at a cast's start, and a plain swing's base attack
SkillAudio.current_skill(obj: Object) -> int             # 0 = none
SkillAudio.context_for(skill_id: int) -> {"id", "code", "group"}   # "-" when unknown, as retail's L"-"
SkillAudio.context_of(obj: Object) -> the same for the current skill
CombatAudio.weapon_token(type_id4, has_weapon) / CombatAudio.base_attack_skill(type_id4)
```

Monsters have no current skill here (the server names none), so their context is `-`.

**Pairing a cast with its result** (OURS, a limit): OpAttackResult names no skill, so a cast is
paired with the first result after its OpUseSkill -- the rule the skill hit effect already used.
A plain swing's result already in flight (or a server keep-up swing) arriving first takes the
cast's keys; the round-614 live run shows it once.

Log lines (the box's live run, round 614; `docs/RE_COMPLETION.md` has the run):

```
AUDIO skills: 23936 skill rows, 991 SndBegin rows under 632 effect ids (291 ms)
AUDIO hit: PLAYER:snd_dmg:SKILL_CH_SWORD_BASE:-:-:- at (78, 41, -220) (plain swing (skill 2) on monster 15, 2 damage)
AUDIO crit: PLAYER:snd_cridmg:-:-:-:- at (78, 41, -220) (plain swing (skill 2) on monster 15, 9 damage)
AUDIO hit: none of [MOB_YEOHA:snd_dmg:-:-:-:-] in the table -- silent (monster 15 (MOB_YEOHA) counter on the player, from the result)
AUDIO cast READY/-1: prim\snd\skill\csk_heal_ready.wav for skill 143 SKILL_CH_WATER_SELFHEAL_A (cast start)
AUDIO cast ACT_S/-1: prim\snd\skill\csk_heal_nega.wav for skill 143 SKILL_CH_WATER_SELFHEAL_A (skill 143 on monster 12, 0 damage)
AUDIO hit: PLAYER:snd_dmg:SKILL_CH_SWORD_SMASH_A:-:-:- at (208, 41, -220) (skill 3 on monster 15, 36 damage)
```

and from the code: `AUDIO block: PLAYER:snd_blocking:-:-:<NORMAL|CRITYCAL>:- at ...`, `AUDIO
activate: ...`, `AUDIO cast: skill <id> rows this client does not fire: ...`. A tag repeated
within a second is held and counted on its next line (`(+N more since the last line)`).
