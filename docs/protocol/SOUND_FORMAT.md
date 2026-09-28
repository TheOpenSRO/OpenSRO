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
