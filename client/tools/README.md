# Dev tools

None of these tools bundle or commit any game data; you point them at your own files. All need a
real (even if software/offscreen) GL context — run them under `xvfb-run` with
`LIBGL_ALWAYS_SOFTWARE=1` on a machine without a display, or drop `xvfb-run` if you're already on
a machine with a display. See each script's header comment for full usage.

`qa_shot.sh` — **the way to look at the world.** Runs the client against real pk2 archives, puts
the player at a given region-local spot, frames the camera, and collects the rendered frames. It
drives the QA hooks documented at the top of `client/scripts/World3D.gd` (`SRREVAMP_QA_*`), which
also cover walking a heading, hiding meshes by name, reporting what the camera is pointing at,
sweeping a region for spots where a player would stand under the geometry, and firing rays through
a wall to see which arches are actually open.

Two things about it are worth knowing before you wait on a run:

**It uses the GPU when there is one.** Godot's Linux GL backend draws through GLX on X11 and Xvfb
has no DRI, so without help every frame is rasterised on the CPU and a screenshot costs minutes.
When `vglrun` and a readable `/dev/dri/renderD128` are both present the script routes GLX through
EGL on the render node instead, and says which path it took on stderr. If a log ever says
"falling back to software GL", something about the render node changed — that is worth fixing
before waiting on anything else.

**It draws with the renderer players run.** From round 693 that is Forward+ (Vulkan):
`project.godot` says `rendering_method="forward_plus"`, and `qa_shot.sh` and `perf_gate.sh` read
that line from the client copy they run, unless `RENDERER=gl_compatibility` (qa_shot) or
`--renderer` / `--ab-renderer` (the gate) says otherwise. Forward+ cannot present to Xvfb, so it
runs through `xwl_run.sh`, a private headless weston with Xwayland that RADV presents to directly
(docs/RENDER_BOX.md, "Vulkan (Forward+)"). Compatibility runs as before, through VirtualGL on Xvfb.
Each run repeats Godot's own banner on stderr: `qa_shot: ran Vulkan API ... - Forward+ - Using
Vulkan Device #0: AMD - AMD Radeon RX 7600 (RADV NAVI33)`. **`llvmpipe` there means the CPU** --
which is what a Forward+ run under plain Xvfb silently gets. From round 581 to 692 every box render
and every release was Compatibility. Before round 581, releases ran Forward+ while the box drew
Compatibility. Keep that in mind when reading an older round's picture against a tester's.
`scripts/project_settings_test.gd` fails if the setting stops applying.

`QA_SHOT_REAP=0` skips qa_shot's start-up kill of every Godot, Xvfb and weston on the box. Use it
with your own `GODOT_LOCK` in a lane, so another lane's runs survive. `frame_ab.py a.png b.png
[--box x,y,w,h]` (numpy + ImageMagick, on the box) prints how two frames differ: mean colour, luma
percentiles, the fraction of pixels off by more than 8 and 32, and white and black fractions. It is
the A/B measurement of round 693's renderer table.

`measure_alpha_cards.gd` (round 695) asks whether real cut-out textures keep their holes under the
renderer it runs on: each named `.ddj` is built through `DdjReader` as the game builds it, drawn
1:1 with the client's alpha test over magenta, and the magenta pixels counted against the CPU
decode's count (`ALPHA <file> dxt1|game ... expected cut <x> rendered cut <y> MATCH|DIFFERS`;
`dxt1` forces the pre-695 DXT1 upload). Run it windowed through `xwl_run.sh` (Forward+) or
VirtualGL (Compatibility); its header has the lines. `SRREVAMP_QA_DXT1_KEEP=1` makes a whole run
keep DXT1 the old way, for a before picture; `SRREVAMP_QA_UI_SCALE=<f>` runs the world at a UI
scale (a QA run starts past Boot, so at 1.0 otherwise), and `ViewportPixels:` lines in the log say
what each 3D preview renders at.

**Startup dominates, so batch the pictures.** Loading the region grid costs roughly 65 seconds
against 0.33 seconds a frame, so six pictures taken as six runs pays that cost six times. Use
`--shots` to visit several viewpoints in one boot, and `--radius` to load fewer regions when the
check only looks at one:

```
qa_shot.sh --out /var/tmp/tour --frames 220 --region '97\168.m' --radius 1 \
  --shots "square@1002,1020:0,-25,700;gate@1062,1560:0,2,45;shops@300,1100:270,-8,60"
```

Each viewpoint prints `QA SHOT <name> frame <n>` in the log; pull that numbered frame from the
output directory. Six viewpoints this way took 116 seconds against about nine and a half minutes
as six separate runs. Beside each, a `QA GRID <name> frame <n> at <x/y> local <lx>,<lz>: cells=..
queued=.. npc_regions=.. nav_graphs=.. navmesh=.. heightmaps=.. collisions=.. object_templates=..
objects=.. orphans=.. static_mem=..` line (round 563) names the region the player is standing in
and reads the region grid's bookkeeping (`RegionGridState`) and the process's object and memory
counts at that moment. A viewpoint's `x,z` are local to the region
under the player, so a spot just past its edge hops one region over -- `w@-30,1020` lands 30
units into the region to the west, `e@1950,1020` into the one to the east -- which is how a
boundary-crossing tour is taken in 28 ticks a hop instead of a 38-second walk: round 563's
`w1..w3@-30,1020;e1..e3@1950,1020` at `--radius 1` unloads 97/168 at the third hop and streams
it back in at the fifth, and its `region x/y unloaded` / `region x/y forgotten` / `NPC(s) placed
in x/y` lines are the measurement. `qa_shot.sh` runs no import, so a script that names a new
`class_name` needs one `remote_godot.sh check` (or `tests`) shipped first, or `World3D.gd` fails
to parse with `Identifier "..." not declared` (round 563 lost one run to it).

**A reconnect is a run, not a hand test.** `--reconnect <tick|drain>` leaves the world and
re-enters it in the same process -- the tester's "disconnect and reconnect without closing the
client", after which the ground came back white (round 558). Direct by default (World3D ->
World3D; until round 560 the route that isolated `World3D.gd`'s `static var` caches, which are
instance state since); `--reconnect-via-login` takes the
tester's route through Login and CharacterSelect, which sign back in with the QA account. Every
hook re-arms on the second entry, so `--shots` names each viewpoint once per entry, and each
entry prints a `QA ENTRY <n> loaded ...` line (renderer texture/buffer/video memory, object and
orphan counts, the world's ground/water/environment caches, its scenery template and texture
caches, the viewport's `debug_draw`, the fog and baked-light inputs)
and one `QA TEXPROBE <n> surface <i> ...` line per surface material of the centre cell's
terrain; a zone change's drain prints the same lines tagged `zone` (`QA ENTRY <n> zone loaded`),
so a count of `QA ENTRY <n> loaded` stays one per entry. What a second entry pays to decode its
own textures is on its `ground textures for <region> -- N ids, N resolved, D decoded now in M ms`
lines and its `water animation -- 30 of 30 frames decoded in M ms` line (round 560).
Measure, do not look: the lower 40% of the two `QA SHOT` frames from the same camera
(`convert f<n>.png -gravity south -crop 100%x40%+0+0 -format "%[fx:mean.r] %[fx:mean.g]
%[fx:mean.b]" info:`), pass 2 against pass 1's own mean, with >= 0.9 the "white" bound; the
`QA ENTRY` numbers of pass 2 against pass 1's; and `grep -c 'SCRIPT ERROR\|previously freed'`
split at the `QA RECONNECT` line. `--reconnect drain` fires while the entry's loading screen is
still up (the drop that lands on a tester mid-load); it needs the loading-screen drain, which
`--reconnect` exports (`SRREVAMP_QA_FORCE_LOADING=1`), and hides the HUD (`SRREVAMP_QA_NOUI=1`)
because the HUD sits in the measured band:

```
qa_shot.sh --out /var/tmp/reconnect --server --region '97\168.m' --radius 1 --frames 400 \
  --reconnect 200 --shots "square@1002,1020:0,-25,700"
```

**A town teleport is a run too** (round 578). `--teleport <id>` with `SRREVAMP_QA_CLICK=gate`
exported clicks the nearest Dimensional Gate, chooses its 'Select teleport area' line through the
talk box's own handler, and clicks the talk box's destination line for teleportdata id `<id>` (2 is
Donwhang from Jangan; round 603 -- the client lists destinations in the talk box, there is no
board), printing the talk box's lines as drawn (`QA TELEPORT: talk line: 1. ...`) and
`QA TELEPORT: requested <gate> -> <id>`. The server needs the teleport tables
(`SRREVAMP_TELEPORT_DIR`, or `$PK2_DIR/teleport`; `qa_shot.sh` passes `-teleport-dir` when the
CSVs are there). Measure from the log: `World3D: teleport accepted -- ... waiver <w>: <receipt>`,
a second `region grid loaded`, `World3D: teleport arrival in RealTerrain_<x>_<y> at local (x, z)`,
and the server's `msg=teleport ... fee=<f> waiver=<w> gm=<b>`. A GM run exports
`SRREVAMP_GM_ACCOUNTS=qa` and `SRREVAMP_QA_COMMANDS="/level 30"` (the QA character is level 1, so
it is waived by level before the GM rule is reached); `SRREVAMP_QA_FORCE_LOADING=1` shows the zone
change's loading screen (`LoadingScreen: up at frame ...`). The QA account cannot pay: only a GM
can raise its level, and a GM is never charged -- the charge and the short-purse refusal are
`server/internal/session/teleport_test.go`'s.

```
SRREVAMP_QA_CLICK=gate qa_shot.sh --out /var/tmp/teleport --server --region '97\168.m' --radius 1 \
  --at 1230,1380 --frames 1100 --size 640x360 --teleport 2
```

**A hotbar key is a run too** (round 598). `SRREVAMP_QA_HOTKEY="<tick>:<key>,..."` pushes
real key presses through the viewport at those ticks, so a number key reaches the underbar the way
a player's does; it prints `QA HOTKEY`, then `QA QUICKSLOT <index> (<label>): skill <id>, target
<monster>`, `QA CAST: use_skill ...`, and each attack result's `QA BERSERK: gauge <g> ... <n> of 5
orbs lit` as drawn (or `QA ATTACK RESULT: refused (...)`). The QA character knows no skill, so a
run learns one first: `SRREVAMP_GM_ACCOUNTS=qa`, `SRREVAMP_QA_COMMANDS="/level 20;/sp 100000"`
(tick 60), `SRREVAMP_QA_LEARN="257x5;3"` (tick 90: raise Bicheon five times, learn skill 3, each
reply printed as `QA LEARN`), then `SRREVAMP_QA_HOTBAR=<tick>` assigns it through the same path a
window click takes. `SRREVAMP_QA_HOTBAR_SKILLS="3,143"` (round 614) assigns those skill ids
instead, in order, with the Basic_Code their skilldata row names -- e.g. Smash and the water
self-heal (`SRREVAMP_QA_LEARN="257x5;276x5;3;143"`), whose cast sounds then print as `AUDIO cast
READY/...` and `AUDIO cast ACT_S/...` (docs/protocol/SOUND_FORMAT.md, "Combat and skill sounds").

```
SRREVAMP_GM_ACCOUNTS=qa SRREVAMP_QA_COMMANDS="/level 20;/sp 100000" SRREVAMP_QA_LEARN="257x5;3" \
  SRREVAMP_QA_HOTBAR=200 SRREVAMP_QA_HOTKEY="300:1,420:1,540:1" SRREVAMP_QA_ATTACK_FAST=1 \
  SRREVAMP_QA_ATTACK_GOTO=1 qa_shot.sh --server --attack --frames 620 --out /var/tmp/hotbar
```

**The title screen is a run too** (round 678). `qa_shot.sh --scene res://scenes/Login.tscn` (or a
lane-safe xvfb run of it) with `SRREVAMP_QA_TITLE_SEEK=0,12,26,40` stands the intro's camera at those
times, waits for the region window, and logs `QA TITLE SHOT t=<t> frame <n> target (...) pitch ..
yaw .. dist ..`, then fades the login window in and logs `QA LOGIN SHOT frame <n>`;
`SRREVAMP_QA_TITLE_HOUR=0..3` pins the random hour and `SRREVAMP_LOGIN_INTRO=<name>` picks the intro.
Three tools measure it instead of looking: `check_intro_scripts.gd -- --media=<Media.pk2>` checks
every intro in an archive (keyframes, length, the path through each keyframe, the clamp, the regions),
`measure_login_ready.tscn` (run as the main scene) clicks at the screen's first frame and prints how
long the login takes to become interactable and fully faded in, and its longest frame, and
`dump_title_layout.gd -- --media=<Media.pk2>` prints pstitle.txt's Title and Login controls as the
frame reads them.

**Sounds are logged, not heard** (round 613). The box's Godot runs the dummy audio driver, so every
animation-fired sound prints one `AUDIO <effect key> t=<key ms> clip <type>:<group> <body> at
<x,y,z>` line (at most one per key per second, the swallowed count appended), and a silent one
`AUDIO skip <event> (<why>)`. `SRREVAMP_QA_AUDIO_TRACE=1` adds an `AUDIO clip` line each time a
body starts a clip, saying which entry it is and whether it has a sound set. Footsteps on several
materials: `SRREVAMP_QA_WALK=180 qa_shot.sh --server --region '97\168.m' --radius 1 --at 1002,1020
--frames 1200`; swings, moans and deaths: the attack loop with `SRREVAMP_GM_ACCOUNTS=qa
SRREVAMP_QA_COMMANDS="/level 60" SRREVAMP_QA_ATTACK_FAST=1 SRREVAMP_QA_ATTACK_GOTO=1`.

**So is a player's input** (round 605). `SRREVAMP_QA_INPUT="<tick>:<action>;..."` plays clicks
(`click:x,y`, `rclick:x,y`, `node:<control name>`, `drag:x,y,x2,y2`), keys (`key:i`, `key:shift+q`,
`type:hello`, with the keycode, physical keycode, label and character an OS key carries), hovers
(`hover:x,y`), `talk` (the NPC talk box) and `census` (every visible focusable control that is not
a button) into the viewport, one per tick. The tick after each prints `QA INPUT <n> <action>:
open=[...] focus=<control> world_keys=[...]`: the windows on screen, who holds the keyboard, and
the keys that got past every HUD handler to `World3D._unhandled_input`. A panel key that toggled
its window is not in `world_keys` (HudPanels consumed it); an unbound one like `j` is, unless a
text line has the keyboard. Round 605's runs (a line of chat, then the bar's buttons, then keys)
are this, at 1280x720; `node:` finds a control by name, so it survives a layout that moves.

Round 608 added `key:ctrl+1` (Ctrl held), `down:<key>` / `up:<key>` (hold V, Z or Space across
ticks) and `whisper_from:<name>` (a whisper arrives, for R's reply), and a `keymap=[...]` field:
what the key table ran (`KEYMAP <key> -> <action> <arg>: <result>`, also printed as it happens).
With held V the log prints `QA KEYS: V held -- <n> of <m> monster bodies drawn; the nearest ...
hovers as '<kind>'`. `SRREVAMP_QA_BERSERK=tab` presses Tab through the viewport once the gauge is
full, instead of sending the request itself.

```
SRREVAMP_QA_INPUT="300:click:220,647;310:type:hello;320:key:enter;330:click:946,689;340:key:k" \
  qa_shot.sh --server --region '97\168.m' --at 1002,1020 --radius 1 --frames 700 --out /var/tmp/input
```

### Sound

The client plays the retail sounds from the player's own archives (round 611;
`docs/protocol/SOUND_FORMAT.md` is the contract): effects and ambient from `Data.pk2`
(`SRREVAMP_PK2_PATH`), the tables from `Media.pk2` (`SRREVAMP_MEDIA_PK2_PATH`), and the music from
**`Music.pk2`, which `qa_shot.sh` exports as `SRREVAMP_MUSIC_PK2_PATH="$PK2_DIR/Music.pk2"`**
(a downloaded build finds it in the `pk2` folder like the others). A missing archive, file or key
is silent, with one line each:

```
AUDIO: Music.pk2 not found (SRREVAMP_MUSIC_PK2_PATH or the pk2 folder) -- its sounds are silent
AUDIO: no prim\snd\env\kk_day.wav in Data.pk2 -- that sound is silent
AUDIO: no effect row for PLAYER:snd_walk1:-:-:-:- -- silent
AUDIO: effect table 6004 rows under 5428 keys
AUDIO options: BGM 30, Effect 50, Env 50
```

The music and ambient (round 612) log one line per change -- `AUDIO bgm: title ->
maintheme_cut.ogg`, `AUDIO bgm: Jangan -> Jangan_Town.ogg (start)`, `AUDIO bgm: Jangan_Field ->
Jangan_Field.ogg (fade out Jangan_Town.ogg over 2.5 s, then start)`, `AUDIO bgm: loading (zone
change) -- ... the loading screen is silent`, `AUDIO ambient: Jangan day: beds [...], 6 one-shots`
-- and one `AUDIO bgm: <file> playing=true at 0.98 s of <length> s` a second after each start. A
`--write-movie` run (every `qa_shot.sh` run) also writes the mix as `f.wav` beside the frames;
its level per quarter second is a measurement of what played. The full list is in
`docs/protocol/SOUND_FORMAT.md`.

The box's Godot mixes through the dummy driver, so a run is measured, not heard: players report
`playing` and advance their playback position (the `audio_*_test.gd` suites check that), and the
log lines above say what was loaded. `probe_audio.gd` measures the code against the real archives
-- rows and keys parsed, characterInfo codes, and the format and length of sample sounds (one of
each 8-, 16- and 24-bit kind, and two music files):

```
client/tools/remote_godot.sh sync
ssh root@192.168.10.78 'su - ghidra -c "cd /opt/srrevamp-client && P=/opt/sro-files/client; \
  SRREVAMP_PK2_PATH=\$P/Data.pk2 SRREVAMP_MEDIA_PK2_PATH=\$P/Media.pk2 SRREVAMP_MUSIC_PK2_PATH=\$P/Music.pk2 \
  /opt/godot-bin/Godot_v4.2.2-stable_linux.x86_64 --headless --path . --script res://tools/probe_audio.gd"'
```

### Scenery materials: the foliage census

`foliage_census.gd` (round 625) reads models the way `ObjectLoader` does. For each mesh piece it
prints:

- the vertex and triangle counts;
- the skin;
- the layer and its flag word, with `[test=.. two=..]` from the client's rule
  (`ObjectLoader.layer_draw_rule`);
- any env-map mod;
- the texture's fourCC, and its alpha below 250 and below 128, over the whole texture and under the
  mesh's own UV triangles (`uv_alpha<128`: what the alpha test would really cut).

It ends with a `CLASS` count of each failure kind. By default it covers the tree and foliage models
of Map.pk2's `object.ifo`. `--under=res/item --all` covers everything under a Data.pk2 directory,
and `--near=97/168:x,z,r` lists a region's placements around a spot, with their models:

```
client/tools/remote_godot.sh script res://tools/foliage_census.gd -- \
  --pk2=/opt/sro-files/client/Data.pk2 --map=/opt/sro-files/client/Map.pk2 [--under=res/item --all]
```

### Map objects: are they placed, and do they draw? (round 643)

Two halves, both over every region. **Placement**, in Go on the box (5 s): `mapobjcensus` builds
the set of objects the retail loader builds (every region `.o2`'s lists 1 and 2, skip bit clear,
one per key -- docs/protocol/MAPO2_FORMAT.md, "Round 643") and says which of them the client's
placement rule draws. Without `-ownerframe` it reproduces the rule before round 643 (the `.o`,
`.o2` list 2, the height filter); `-ownerframe` is the rule since. `-grep bridge` or
`-region 92/135` lists the undrawn keys (and the placements it counts as moved into their
owner's frame); `-media <Media.pk2>` adds `force_addobject.txt`'s rows, the second object source
(round 643's review); `-key 97/168#43009` lists every record of one key, skip-bit ones included;
`-dumpmodels <file>` writes every model with its key count for the second half:

```
cd server && go run ./cmd/mapobjcensus -map /opt/sro-files/client/Map.pk2 \
  -media /opt/sro-files/client/Media.pk2 [-ownerframe] [-grep stab] [-region 91/135] [-key 97/168#43009] \
  [-dumpmodels /var/tmp/<lane>/models.tsv]
```

**Loading**, in GDScript (2 minutes for 2,567 models): `map_object_census.gd` prepares each model
of that list through `ObjectLoader.prepare_object` and classes it `LOAD_FAILED` (with the reason:
file absent, reader refused, `.bms` version), `MESH_LESS`, `PIECE_MISSING`, `ZERO_TRIS`,
`NO_MATERIAL`, `NO_TEXTURE`, `HEADER_SCAN` (the forward scan read it) or `CUT_AWAY` (the alpha test
keeps under 1 % of the texels), weighted by the keys behind it:

```
client/tools/remote_godot.sh script res://tools/map_object_census.gd -- \
  --pk2=/opt/sro-files/client/Data.pk2 --models=/var/tmp/<lane>/models.tsv [--verbose] [--match=bridge]
```

In the world, `SRREVAMP_QA_OBJECTS=<fragment>,...` prints at every `--shots` viewpoint one
`QA OBJECT <shot> <node> key <owner>#<uid> held by <region> (listed by N) at world (..)
region-local (..) of <region>: P piece(s), T triangle(s), visible <b>, in frustum <b>, <d> from
the camera` per placed object whose node name holds a fragment, or `<fragment>: none placed` --
the triangles are the drawn surfaces' own index counts.

### Map objects that move: the animation census and its cost

`mapanim_census.gd` (round 645) classes every model of Map.pk2's `object.ifo` by what could animate
it: `skeletal`, `skel_only`, `texani`, `dy` (cloth) and `motion`. It adds `animates` for what this
client plays: the model is built with `ObjectLoader.load_object` and has its player (round 645
review). A named clip that fails to build is `clip_fails`, with a `CLIPFAIL` line saying why. Each
model's placements are counted over every region's
`.o` and `.o2` list 2. It prints one `MODEL` line per classed model, with its clips (Duration,
IsCyclic, bones), its `default` group entries and its object.ifo flag, then `CLASS` totals.
`--regions` adds per-region counts, `--region=100/134 --all` lists everything a region places, and
`--where=edimmu` prints the placements of matching models. It takes about 60 seconds for the whole
map.

```
client/tools/remote_godot.sh script res://tools/mapanim_census.gd -- \
  --pk2=/opt/sro-files/client/Data.pk2 --map=/opt/sro-files/client/Map.pk2 [--regions]
```

`mapanim_bench.gd` places `--count` copies of each `--models` path and times uncapped frames with
every clip running, every clip paused and none placed. Low-processor sleep and vsync are off; the
default headless loop sleeps 6.9 ms a frame, which swamps the measurement. It can also run with the
GL renderer, under `xvfb-run` and `vglrun` without `--headless`. `--noskin` and `--nomesh` strip
the copies' skins or meshes, to split the cost. In the world,
`SRREVAMP_QA_MAPANIM=n` prints the driver's counts and the process time every n frames;
`SRREVAMP_NO_MAP_ANIM=1` is the A/B.


### Particle effects: the `.efp` census

`EfpReader.decode` (and its Go twin `efp.Decode`) reads the typed tree of every particle
effect (round 619; `docs/protocol/EFP_FORMAT.md` is the contract). The census measures
what fraction of the player's own `Particles.pk2` it reads: headers parsed, trees decoded
to the exact byte, failures by reason, and the files using each feature. It prints only
counts and paths. There are three ways to run it, and all should agree (round 619:
4,170 files, 4,103 decoded, 4,096 to the exact byte, 95,801 nodes):

```
# Go, on the box (0.8 s): the full report, with the feature table
cd server && go run ./cmd/efpcensus -pk2 /opt/sro-files/client/Particles.pk2
# one file's decoded tree
go run ./cmd/efpcensus -pk2 /opt/sro-files/client/Particles.pk2 -show 'battle\deco_charge_light_a.efp'
# the same census as a Go test; it is skipped where the variable is unset, which includes CI
SRREVAMP_PARTICLES_PK2=/opt/sro-files/client/Particles.pk2 go test -count=1 -run TestRetailCensus -v ./internal/efp
# GDScript twin (22 s), after a sync
client/tools/remote_godot.sh script res://tools/efp_census.gd -- --pk2=/opt/sro-files/client/Particles.pk2
# the two readers value for value: one md5 of a canonical dump per file, diffed (prints IDENTICAL)
RENDER_DIR=... GODOT_LOCK=... client/tools/efp_dump_diff.sh
```

`TestRetailCensus` fails if any of the measured results regresses: decoded files, exact decodes,
HeadLen matches or Frame* key counts.

**Building every file into an effect** (round 620). `--build` also builds each decoded file into
an `EfpEffect` with its real meshes and textures, and runs 40 frames (2 s) of its simulation. It
then reports:
- how many files build;
- how many draw every node they mean to draw;
- how many draw at least one node;
- the skip reasons, bucketed. These are render modes not drawn yet, assets that did not load, and
  commands no rule covers.

It takes 86 s:

```
client/tools/remote_godot.sh script res://tools/efp_census.gd -- --pk2=/opt/sro-files/client/Particles.pk2 --build
```

**Seeing effects play** (round 620). There are two hooks. The frames show what the renderer did;
they prove nothing about retail.
- `SRREVAMP_QA_EFFECT="<efp>[;<efp>...]"` plays those files on the player at tick 20, looping.
  They are spaced `SRREVAMP_QA_EFFECT_SPACING` native units apart (default 40). Each file prints
  `QA EFFECT <path> at x <x>: <n> node(s) drawn, skipped [...]`.
- `SRREVAMP_QA_CAST="<skill id>[,...]"` runs each skill's effect phases on the player in turn,
  every `SRREVAMP_QA_CAST_PERIOD` ticks (default 160):
  - `SkillEffects.cast` at +0: READY now, then WAIT and SHOT by the skill's timing columns;
  - `shot` and `hit` (SHOT/1) at +30;
  - `act` (ACT_S) at +40;
  - the ACT_L aura (token 1) from +41 until the next skill starts.

  Each step prints a `QA CAST tick <t> ...` line, and each effect an `EFFECTS skill ...` line
  giving its ActType, bone and nodes drawn.

```
SRREVAMP_QA_NOUI=1 SRREVAMP_QA_CAST=90,113,114,149,3 qa_shot.sh --out /var/tmp/cast --region '97\168.m' \
  --radius 1 --at 1002,1020 --yaw 30 --pitch -12 --dist 70 --frames 860
```

### Performance gate

`perf_gate.sh` is the before/after every world round runs (AGENTS.md, "Performance: every world
round runs the gate"). It ships the working tree and its base (`git merge-base HEAD origin/dev`,
or `--base`/`--head` revisions) to `/opt/srrevamp-client-perf-<lane>-{base,head}` on the box,
boots each at fixed views, interleaved base/head, and reads four numbers from the client's log:

| number | from | SLOWER when (OURS) |
|---|---|---|
| frame ms | the mean of the last 30 `--print-fps` samples after the first 5, standing still | +max(0.5 ms, 5 %) |
| entry ms | `region grid loaded in N ms`, the real loading drain (`SRREVAMP_QA_FORCE_LOADING=1`) | +max(1 s, 10 %) |
| freeze ms | the largest `longest work frame W ms` of the run's LoadTimings summaries | +max(100 ms, 25 %) |
| hitches | the summaries' `H over 100 ms`, summed | +2 |

A verdict also needs the ranges apart (no head run better than a base run), so a noisy run cannot
fail it alone. Views: `jangan` (97/168 at 1002,1020), `reeds` (98/157 at 900,900), `cross` (97/168
from 120,1020 walking west into 97/167: the load benchmark's crossing (b) below), `hotan`, and
`ferry` (90/143 at 464,879 looking west: the Donwhang-region ferry landing, its reeds and the river;
round 648). A site may carry its own frame count (the fifth field of `view`); the ferry's 2.6 ms
frames need 12,000 frames for the 30 once-a-second samples, which 3,000 frames did not give.

```
client/tools/perf_gate.sh                                   # all three default views, 3 runs each
client/tools/perf_gate.sh --sites jangan --runs 3           # ~6 minutes
client/tools/perf_gate.sh --base 8658370 --head c306c51 --sites jangan   # the proof: SLOWER (+3.0)
```

**The renderer (round 693).** Each side runs the renderer its own `project.godot` names, so a
gate across round 693 compares Compatibility (base) with Forward+ (head). `--renderer R` puts both
sides on R. `--ab-renderer R` compares one build with itself, its base side on R (no base cache, no
native library), which is how round 693 measured Forward+ against Compatibility:

```
client/tools/perf_gate.sh --ab-renderer gl_compatibility --sites jangan,mobs
```

Every run's renderer is read back from Godot's banner. A run on the wrong renderer, or on llvmpipe,
fails the gate. Cached Forward+ bases are kept apart (`..._fp.vals`).

The first 5 once-a-second samples are dropped (round 693, found by round 694's review). The
first second carries the first cell's build (8-1000 ms), and seconds 2-5 are still raised (8 / 16 /
12 / 9.8 ms under GL, 55 / 3.35 / 5.05 / 4.06 under Forward+). A 3,000-frame GL run gives about
27 samples, so its "last 30" took the start-up in and could read SLOWER.

Forward+ at the Jangan spawn draws in about 3 ms (round 693). 3,000 frames is then about 9 s,
under the 15 samples (10 after the 5 dropped) the frame figure needs, and the gate stops with "missing
numbers". Give such a gate `--frames 12000`. The two renderers also reach the screen differently on
the box: Compatibility through VirtualGL's read-back, Forward+ through Xwayland directly. Measured
once at the spawn, Compatibility drew 8.2 ms through Xwayland against 10.5 through VirtualGL. So
the gate's Compatibility frame carries about 2 ms that a player's machine does not pay.

Each run waits until no other lane's Godot is running and is repeated if one overlaps it: the CPU
is what lanes share (one render uses about 3.3 of the box's 10 cores; six at once put it at 89 %
busy and ran 2.8x slower a frame, while the GPU averaged 37 %; 2026-09-30, `amdgpu_top` and
`vmstat`). Gates queue on `/var/tmp/perf-gate.lock`. The logs stay in `/var/tmp/perf-<lane>/`.

**A base is measured once (2026-09-30).** The base revision's numbers are cached per (revision,
view, frames) in `/var/tmp/perf-cache/` on the box, and its client copy is shared as
`/opt/srrevamp-client-perf-base-<rev12>` (shipped and imported once, under a per-revision lock). A
later gate runs one fresh base run first and keeps the cache only if that run is within the gate's
own SLOWER threshold of the cached median; otherwise the box has drifted and the base is measured
again in full. Measured at Jangan with 2 runs a side: 216 s without either, 180 s with the cached
numbers, 170 s with the shared copy too; with the default 3 runs a gate boots 4 times instead of 6.

The proof, 2026-09-30, three runs each (ms per frame 11.49/11.05/11.04 against 14.43/13.91/14.06):

```
jangan  frame ms   base 11.05  head 14.06  (+3.0)  SLOWER
jangan  entry ms   base 14310  head 13946  (-364.0)  SAME
jangan  freeze ms  base 4893  head 4733  (-160.0)  SAME
jangan  hitches    base 5  head 5  (+0.0)  SAME
```

It also shows what a player waits through at every Jangan entry: about 14 s, with a single frame
of about 4.9 s and five over 100 ms.

### Release checks (round 668)

- `check_native_library.sh <lib> windows|linux`: the built library stands alone. On Windows that
  means system DLLs only; on Linux, base libraries only and glibc at or below 2.28. It must also
  export `gdext_rust_init` and be stripped.
- `check_release_zip.sh <zip> windows|linux [--run]`: the zip carries the exe, the `.pck`, the
  library next to the exe and `THIRD_PARTY_NOTICES.txt`. `--run` (Linux) starts the exported game
  headless twice, as shipped (`native readers ON`, no extension error) and with the library
  renamed to `.off` (`native readers OFF`).
- `run_gd_tests.sh`: every `*_test.gd`, one at a time, with the `godot` on PATH. This is CI's
  loop. On the box, use `remote_godot.sh tests` instead.

release.yml runs the first two; native/README.md, "CI".

### Native readers A/B (round 667)

The pk2 reader and the `.ddj` per-pixel decodes have a native (Rust, GDExtension) twin, set out in
native/README.md. One build compares both ways. `SRREVAMP_NATIVE=0` forces the GDScript path even
when the library loaded, and the client logs which path it took once:
`NativeAssets: native readers ON|OFF (...)`.

```
native/build.sh                                                       # client/native_bin/libsrrevamp_native.so
PERF_LANE=native667 client/tools/perf_gate.sh --ab-env SRREVAMP_NATIVE=0 --sites jangan,mobs          # warm
PERF_LANE=native667 client/tools/perf_gate.sh --ab-env SRREVAMP_NATIVE=0 --sites jangan,mobs --cold   # cold
```

- `--ab-env "VAR=value ..."` runs the base side on the head's own copy with those variables, so
  "base" here means the same build on the GDScript path. No base revision is shipped, and the base
  cache is neither read nor written.
- `--cold` evicts every `*.pk2` from the page cache before each run, with
  `posix_fadvise(DONTNEED)`, because the box's container cannot write `/proc/sys/vm/drop_caches`.
  `fincore` records what stayed resident in `<log>.cold`. This is the storage-bound case. Godot
  and the project stay cached.
- **Both sides carry the same library state, and the gate checks it** (round 667's review, M1).
  Each run's log line `NativeAssets: native readers ON|OFF` is read back:
  - **The ordinary base/head gate ships the library to NEITHER side**, nor the `.gdextension`, so
    both sides read in GDScript. A world round's gate then measures that round and never the
    native speed-up. Before this rule, a working tree with `client/native_bin` built got the
    library on the head only. A run whose log says ON fails the gate.
  - **`--ab-env` ships one copy with the working tree's library.** It refuses `--head REV` (a
    revision carries no library), and refuses a tree without
    `client/native_bin/libsrrevamp_native.so`. Every head run must log ON and every base run must
    not, or the gate fails with
    `FAIL native readers <state>, this side must be <ON|not ON>`.
  - The self-test is `PERF_SELFTEST_DROP_LIB=1 client/tools/perf_gate.sh --ab-env SRREVAMP_NATIVE=0
    --sites jangan --runs 1`. It ships the copy without its library and must fail on the first
    head run.

Per function, `SRREVAMP_PARSE_PROFILE=1` makes the client print `PARSEPROF` lines
(`client/scripts/pk2/parse_profile.gd`): a table of every reader's time on the main thread and on
the workers, once after the boot tables and once with the entry's LoadTimings summary. Round 667
ranked the port by these lines.

`client/tools/native_parity.gd` holds the two paths to each other on the real archives, and
`client/tools/native_parity_models.gd` does the same for every `.bms`, `.ban` and `.bsk` (round 669).
`client/scripts/pk2/native_assets_test.gd` does the same on synthetic input, and checks the
fallback when the library is absent (`NO_NATIVE=1 client/tools/remote_godot.sh tests`).

The text tables (round 671) have their own pair: `table_parity.gd` runs every ported reader both
ways on every `.txt` of every archive (about 70 s; `--max-fails=N` prints more FAIL lines), and
`client/scripts/npc/native_tables_test.gd` on synthetic tables. `probe_table_cost.gd` prints, per
boot and entry table, what the GDScript decode, line split and tab split cost and what each reader
costs both ways:

```
client/tools/remote_godot.sh script res://tools/table_parity.gd -- --pk2-dir=/opt/sro-files/client
client/tools/remote_godot.sh script res://tools/probe_table_cost.gd -- --pk2-dir=/opt/sro-files/client
```

### Skinned map objects: where the vertices go (round 648)

`probe_map_anim_pose.gd` builds one map object the way the world does (ObjectLoader, then
MapAnimation) and CPU-skins every skinned piece at the given clip times, printing each piece's
box still against posed, and each bone's `.bsk` rest against the clip's first key. The reeds'
streaks were one line of it: `posed size (3.7e24, ...)` against `still size (154, 22, 104)`.
`census_bsk_bind.gd` walks every `.bsk` in Data.pk2 and prints the skeletons whose composed rest
disagrees with the world binds the file stores, and whose root local is unset.

```
remote_godot.sh script res://tools/probe_map_anim_pose.gd -- --pk2=$PK2/Data.pk2 \
  '--file=res/nature/china/dunhuang/reed/fw_cd_reeds_l.bsr' --seconds=0,0.5
remote_godot.sh script res://tools/census_bsk_bind.gd -- --pk2=$PK2/Data.pk2
```

`SRREVAMP_QA_NOWATER=1` builds no block water, for a pixel diff that measures what the water draws
(round 648's water-on/off diff). A lane that must not stop other lanes' renders runs its client with
`xvfb-run -a ... --write-movie` under its own lock instead of `qa_shot.sh`, whose start-up reap
kills every Godot on the box.

### Character appearance: the 52 bodies, Height and Volume (round 683)

`measure_create_cycles.gd` (round 685) builds a piece of the customize screen, lets it run, frees
it and prints the engine's object count and static memory after each cycle -- `--mode=screen` (the
whole scene), `backdrop`, `appearance`, `preview` -- so growth per cycle is pinned to the piece that
leaks it; `--mode=swaps` prints the preview's swap times over every Figure, weapon and set, cold
then cached. Run it headless on the box with the archive variables set
(`res://tools/measure_create_cycles.gd -- --mode=backdrop --cycles=4 --race=china`).

`appearance_probe.gd` checks `CharCatalog` against charselect.md (52 Figures, 5 + 9 weapons, a
shield per race, 3 armour sets per race and sex, 104 ids), builds every Figure with a kit through
`CharacterAppearance` (cold and warm build times), measures the head bone at Height 0/2/4 and the
CPU-skinned girth at Volume 0/2/4, and with `--out` renders the 52 at each Height and Volume plus
one body per race and sex side by side. A failed check prints `PARITY FAIL`. It needs a GL context
for `--out`, so a lane runs it under its own lock with `xvfb-run -a -s "-screen 0 1600x1200x24"
vglrun -d egl0 ... --rendering-driver opengl3 --resolution 1600x1200 --script
res://tools/appearance_probe.gd -- --pk2=$PK2/Data.pk2 --media=$PK2/Media.pk2 --out=/var/tmp/<lane>/shots`.
Without `--out` it runs headless through `remote_godot.sh script`.

`--showthrough=1` (GL context) measures how much of each worn armour set the body's own pieces cover,
front and back, in flat colours (`--showthrough=all` for every Figure). `--stdir=<dir>` saves the
frames, `--shrink=<f>` scales every body piece towards its bones first, `--bind` skips the idle pose,
and `--norender` skips the lineups. `probe_body_armour.gd --body=<.bsr> --items=<a.bsr,b.bsr>` counts
an item's vertices that sit on a body vertex (headless; pass paths with `/`, which survive the ssh).

### Bodies in the world: clips, T-poses and feet (round 689)

`body_anim_probe.gd` (headless, `remote_godot.sh script`) builds every one of the 52 Figures and,
for each core action (stand, walk, run, the four plain-attack types, hit, die, sit down, sit, stand
up) in `default` and every weapon group the race can hold, resolves the clip and checks it plays
(the file is there, parses and drives the skeleton's bones). `--lookup=world` is BodyAnimations
(the client's READ rule); `--lookup=old` the lookup World3D used before round 689, for the
before/after. A clip that does not play prints `TPOSE ...` and `PARITY FAIL`; `FIGURE` lines give
each body's lowest skinned point at bind and at its stand clip's first frame (`feet`).

In the world, `SRREVAMP_QA_LINEUP` (scripts/world/qa_lineup.gd) spawns the Figures through the
other-player path and prints a `LINEUP` line per body per phase (`posed yes|TPOSE`, `feet` against
the walkable surface) and a `LINEUP SUMMARY`; `SRREVAMP_QA_LINEUP_SHOTS=<dir>` saves the screen.
It needs a GL context; the lane runs it under its own lock, in real time and without the movie
writer, e.g. `/var/tmp/world689/gl.sh <out> <env file>` with `SRREVAMP_MAPM_PATH=97\168.m`,
`SRREVAMP_QA_AT=1002,1100`, `SRREVAMP_QA_LINEUP=all`, `SRREVAMP_QA_LINEUP_WEAPONS=each`,
`SRREVAMP_QA_LINEUP_ACTIONS=stand,run,sit,attack`, `SRREVAMP_QA_LINEUP_QUIT=1`. With
`SRREVAMP_QA_LINEUP=none` and `SRREVAMP_QA_SERVER` it measures the player and the server's other
players instead (`SRREVAMP_QA_CREATE=ref:scale:chest:legs:feet:weapon` makes the character; the
live pair is `/var/tmp/world689/live.sh`). The world needs `SRREVAMP_MAPM_PATH` offline: without it
the grid builds no cells and the lineup never finds ground.

### Load benchmark

Every map and loading change is measured on the two runs below, before and after, and on nothing
else. The numbers are log lines from `World3D.gd`'s `LoadTimings`
(`client/scripts/world/load_timings.gd`, round 561), never a frame.

**The metric is main-thread work time per frame, not `delta`.** `qa_shot.sh` always passes
`--write-movie`, and Godot's movie writer forces `--fixed-fps`, which "disables real-time
synchronization" (Godot 4.2, command line reference); `editor/movie_writer/fps` is 60 and the
project does not override it, so `_process`/`_physics_process` receive `delta` = 1/60 s on every
frame however long the frame took -- a hitch metric built on `delta` reads 16.7 ms for ever. The
wall clock is no better, because every movie frame pays the writer's readback and PNG (the 0.33 s
a frame above). So `World3D._physics_process` times its own step with `Time.get_ticks_usec()`,
each cell's build is timed around `_load_region_cell` (and the centre cell in
`_load_region_neighborhood`), and the two are summed per drawn frame. Nothing else counts as
work: the loading screen's own build (`LoadingScreen: up ... built in N ms`, 672-711 ms across
round 562's three runs) and the HUD's (`_try_initialize_pk2_ui`) run in `_ready` between physics
steps, so neither reaches `longest work frame` -- they are part of `D` below, and the screen's
cost is read from its own line. Three lines carry it:

- `World3D: cell 97/167 built in N ms at frame f (terrain T [...], objects O [...], npcs P
  [tables])` -- one per cell as it is built. The three group totals are
  the stopwatches around the phases (the same numbers the `region grid loaded` split has summed
  since round 156) and are **main-thread time only**; the bracketed sub-phases are laps inside
  them, and need not add up to the group. Since round 565 a region's terrain is a job built on the
  main thread (`_terrain_job`: the one-time tables and a snapshot of the caches), a *prepare*
  (`_terrain_prepare`: plain data) and a *commit* (`_terrain_commit`: everything that owns an RID
  or touches the tree), and the terrain list has two shapes:
  - a cell built on the main thread -- the grid's centre, always, and every cell under
    `SRREVAMP_SYNC_LOAD=1` -- lists all three halves in order: `terrain T [tiletable, objindex,
    snapshot, read, parse, env, lightmap, textures, mesh, heights, navmesh, walls, navgraph,
    images, upload, setup, collision, wallshape, water, graph]` (`env` the centre's alone;
    `tiletable` and `objindex` are cached after the first call, so only the centre's are
    non-zero);
  - a streamed neighbour (the default) lists the commit alone as its terrain and the prepare after
    the groups, off the main thread: `terrain T [images, upload, setup, collision, wallshape,
    water, graph], objects O [...], npcs P [...]; off the main thread: terrain P [read, parse,
    lightmap, textures, mesh, heights, navmesh, walls, navgraph]`. The off-thread figure is the
    task's own time and is **never** in `built in`, in a frame's work or in the `terrain` group
    totals. A streamed cell's job snapshots -- `_terrain_job`'s and, since round 566,
    `_objects_job`'s (`ObjectTemplateCache.held_keys()`, `ObjectLoader.snapshot_textures`, each
    O(entries)) -- are built at dispatch, between cells, so they are on no cell line (their
    `snapshot` laps are dropped: no cell is open). In play the dispatch runs inside the physics
    step (`_process_stream_queue`), so it counts in that frame's work; under the loading screen
    the drain's coroutine dispatches outside any physics step, so it counts in no frame's work and
    lands in `D`. Neither is measured on its own (round 565's and 566's reviews).

  Since round 566 the objects are split the same way -- `_objects_job` (main thread: the object
  index and a snapshot of the templates held, the textures uploaded and the heightmaps parsed),
  `_objects_prepare` (plain data: `ObjectLoader.prepare_object` per model) and `_objects_commit`
  -- and prepare on the same task, after the terrain (`_cell_prepare`). The objects list has the
  same two shapes: on the main thread `objects O [snapshot, parse, own, models, textures,
  templates, place]`; streamed, `objects O [textures, templates, place]` with `; off the main
  thread: terrain P [...], objects Q [parse, own, models]` after the groups (a lap with nothing to
  do is left out: a cell whose models the world already holds has no `templates`, one with no
  `.o2` stops after `parse`). The objects line of a streamed cell (`World3D: loaded N/M real map
  objects from ...`) ends `-- prepared off the main thread, dispatched at frame f; K template(s)
  built unprepared`: K counts the templates the commit had to build whole on the main thread
  (one released or evicted between the dispatch and the commit), and is 0 when the prepare
  covered them all.

  What the laps are: `read`/`parse` the `.m`; `lightmap` the `.t` decoded to an Image; `textures`
  the ground tiles this world does not hold yet decoded to Images; `mesh` the surfaces as arrays;
  `heights` the collision's data: the region's 97x97 height grid (`TerrainCollision.heights_from_region`,
  round 567), or under `SRREVAMP_TERRAIN_TRIMESH=1` the trimesh's face list
  (`MapmTerrainBuilder.surface_faces`, what `create_trimesh_shape()` used to read back out of the
  mesh; the lap was `faces` in rounds 565-566); `navmesh` the `.nvm` read and
  parsed; `walls` the wall triangles; `navgraph` the object navigation meshes and
  `NavGraph.build`; then `images` the ImageTexture uploads; `upload` the ArrayMesh and its
  materials; `setup` the group, the untextured material, the placement and the nodes (round 564's
  lap); `collision` the shape alone -- since round 567 the `HeightMapShape3D` (`TerrainCollision.make_shape`),
  until then and under `SRREVAMP_TERRAIN_TRIMESH=1` the `ConcavePolygonShape3D.set_faces` (round
  156's bottleneck, before round 160's archive fix); `wallshape` the walls' shape and body; `water`; `graph` the walkable
  graph's registration. The objects': `snapshot` the job's; `parse` the `.o2` read and parsed,
  and its lists 1 and 2 taken one object per key in the owner's frame (`World3D.region_placements`,
  round 643; the `.o` and `.o2` merged until then); `own` the region's own heightmap, read and
  parsed under Pk2Reader's lock when the grid does not hold it (until round 643 the
  placement-ownership test by height, over the eight neighbours' heightmaps too); `models`
  `ObjectLoader.prepare_object` for every model the world holds no template for (the `.bsr`,
  `.bms`, `.bmt` parsed, the mesh arrays and trimesh faces built, the textures decoded to Images
  and their alpha classified on them); then `textures` the ImageTexture uploads; `templates`
  `ObjectLoader.commit_object` (the ArrayMeshes, materials, shapes and nodes of each new
  template, or a whole unprepared build); `place` the container, and each placement's duplicate,
  transform and add. Every stopwatch is a lap (round 564's rule, held by `load_timings_test.gd`
  for both groups), so the laps cover each group less each lap's whole-ms truncation; outside
  them are only the path check before the job, the log lines the commit prints first, and its
  closing print, unmeasured.
- `World3D: region grid loaded in N ms (terrain T, objects O, npcs P) at frame f -- C cells S ms,
  D ms outside the cells over A awaited frames` -- the drain's total against the cells' own sum.
  **The check is `S <= N`, not equality**: under the loading screen (`SRREVAMP_QA_FORCE_LOADING=1`)
  `_ready` puts the screen up and awaits the frame that draws it before the centre cell (round
  562; the drain built it after the centre cell until then), the HUD is built between the centre
  cell and the drain, and the drain awaits a frame after every batch -- all of that is `D`, and
  `A` counts the screen's frame with the drain's own (`_ready` hands it on); on the synchronous
  QA path `D` is small. A sum above the total is a bug in the clock and the line says so. Since
  round 565 the line ends `; terrain X ms prepared off the main thread` when cells prepared on
  tasks -- not in the split or in `S`, which are the main thread's. Cells a frame under the
  screen: threaded (the default), the drain is the only pump while it runs and commits at most
  `LOADING_CELLS_PER_FRAME` = 2 prepared cells a frame, as many as have finished preparing
  (`TERRAIN_JOBS_IN_FLIGHT` = 2 prepare at once). Under `SRREVAMP_SYNC_LOAD=1` it is the
  pre-round-565 schedule: a batch is `LOADING_CELLS_PER_FRAME` = 2, but the frame builds three --
  the same frame's physics step runs `_process_stream_queue`, which pops `STREAM_CELLS_PER_FRAME`
  = 1 more from the same `_load_queue` -- the baseline's three `built in` lines a frame at frames
  14-21. Read the cells a frame from the log, not from the constants.
- `World3D: longest work frame W ms at frame f (cell x/y) over F frames since the last summary;
  p95 Q ms; H over 100 ms; longest wall gap G ms at frame f; run longest ...; grid C cells terrain T
  objects O npcs P ms` -- at the end of each drain, every 600 physics ticks (`_qa_step` runs for
  every player, so a real player's log carries it too) and when the world leaves the tree. A
  summary covers the window since the previous one, so the drain's summary is the
  entry and the tick-600 summary is the play after it (a crossing). 100 ms is a reporting bucket,
  not a game value. The wall gap carries the movie writer's floor: compare on the work column.
- `LoadingScreen: up at frame f (media reused|opened|none, N ms; backdrop decoded|missing, N ms;
  built in N ms)` -- the frame the "NOW LOADING" screen joined the tree in (drawn from the next
  one on), whether it read its backdrop through the Media.pk2 the world already held (`reused`,
  every login and teleport since round 562) or opened a reader of its own (`opened`, what every
  screen did before), what that open and the backdrop's decode cost, and the screen's whole
  build. Its place in the log is the entry's first check: it comes before the centre cell's
  `ground textures for` and `built in` lines, or the player watched a black window for the
  centre cell. `SRREVAMP_QA_NOUI=1` hides `$UI/Control`, which the screen is a child of, so a
  benchmark run's frames never show it; the log order is the measurement, and a run without
  `NOUI` shows the art from the first drawn frame after the line.

The two runs, verbatim, so before/after numbers come from identical commands. Both hide the HUD
and take the real awaiting drain (the QA path would build the whole grid in `_ready`, one frame);
both sign in to a server, so the entry is the player-shaped one. While the box lock is held by
round 558's orphaned run (2026-09-25), export `GODOT_LOCK=/var/tmp/<lane>/lock` first.

(a) Entry -- the 5x5 grid a player waits for:

```
SRREVAMP_QA_FORCE_LOADING=1 SRREVAMP_QA_NOUI=1 qa_shot.sh --out /var/tmp/loadbench --server \
  --region '97\168.m' --radius 2 --frames 200
```

(b) Crossing -- a walk west out of 97/168 into 97/167, so in-play streaming is measured too:

```
SRREVAMP_QA_FORCE_LOADING=1 SRREVAMP_QA_NOUI=1 qa_shot.sh --out /var/tmp/loadcross --server \
  --region '97\168.m' --radius 2 --at 120,1020 --walk 270 --frames 600
```

The start (120, 1020) was picked with `walk_probe.gd` (`--region=97/168 --from=120,1020
--heading=270 --steps=400`, round 561): open terrain at y 0.0 all the way past local x = 0 with no
wall contact, where (150, 1020) stands on `cj_armo` and meets a wall at x = 138. World heading 270
is local -x; at the character table's 50 units a second (`World3D.gd`, `_move_speed`) the edge is
2.4 s, 144 movie frames, in, so the new column streams well inside 600. Read the first
`NAV <tick>: footing settled on terrain at local x, z` line and the `QA 60 local x, y, z` line to
see where the walk really began (the roof-escape can move a start near a building; in the
baseline run tick 60 stood at local 71, 0, 1020 -- fifty units west of the start, as 50 a second
says), and take the crossing's longest frame from the tick-600 summary, not the drain's -- or from
the exit summary if no tick-600 summary printed: `_qa_tick` counts physics steps from `_ready` on,
less the frames `--at` waits for its region (`_qa_step`), so with `--frames 600` the tick-600
summary lands on the run's last frame or two (in the baseline, 576 frames after the drain's at
frame 23), and a run where it lands after `--quit-after` leaves the same window to `_exit_tree`'s
summary. To read a run:
`grep -E 'LoadingScreen: up|built in|region grid loaded|longest work frame|footing settled|^QA +[0-9]+ local' <run>.log`.
The BEFORE for the whole map/loading epic (round 561, 2026-09-25, hardware GL, the commands
above; the full lines and the per-phase sums are in `docs/RE_COMPLETION.md`, round 561):

```
(a) cell 97/168 built in 5373 ms at frame 13 (terrain 1609 [.. tiletable 944, navgraph 212 ..],
        objects 2093 [.. own 319, templates 1670 ..], npcs 1671 [tables 925])   -- the centre
    24 neighbours 231..1120 ms, mean 417, three a frame at frames 14-21 (2 drain + 1 stream)
    region grid loaded in 22752 ms (terrain 7996, objects 5037, npcs 2355) at frame 22
        -- 25 cells 15388 ms, 7364 ms outside the cells over 9 awaited frames
    longest work frame 5374 ms at frame 13 (cell 97/168); p95 2844 ms; 9 over 100 ms
    in play (exit summary, 177 frames): longest work frame 6 ms; p95 6 ms; wall gap 368 ms
        standing at the server's spawn: QA 60 local 960, -32, 960 on object cj_jang_gate at -32.6
(b) longest work frame 328 ms at frame 162 (cell 98/165) over 576 frames; p95 5 ms;
        5 over 100 ms; longest wall gap 723 ms   -- the tick-600 summary; the column
        95..99/165 streamed one cell a frame at frames 160-164, 270..323 ms each
```

AFTER round 562 (the screen before the centre cell, on the archive the world already holds; the
same command, the same box, 2026-09-25; `docs/RE_COMPLETION.md`, round 562, has the full lines and
the frame measurements of a run with the HUD shown):

```
(a) LoadingScreen: up at frame 13 (media reused, 0 ms; backdrop decoded, 674 ms; built in 676 ms)
    cell 97/168 built in 5200 ms at frame 14 (terrain 1575 [.. tiletable 937, navgraph 195 ..],
        objects 1951 [.. own 323, templates 1532 ..], npcs 1673 [tables 939])   -- the centre,
        the frame after the screen's
    24 neighbours three a frame at frames 15-22 (2 drain + 1 stream)
    region grid loaded in 22884 ms (terrain 8004, objects 5015, npcs 2347) at frame 23
        -- 25 cells 15365 ms, 7519 ms outside the cells over 10 awaited frames
    longest work frame 5259 ms at frame 14 (cell 97/168); p95 2919 ms; 9 over 100 ms
    in play (exit summary, 176 frames): longest work frame 7 ms; p95 6 ms; wall gap 366 ms
(b) not re-run: nothing in play changed.
```

The tenth awaited frame is the one `_drain_initial_load` now draws after the centre cell and
before its first batch (the gauge's first tick, which counts the centre): without it round 562's
first run had the first two neighbours in the centre's frame and the longest work frame read
7,506 ms for a 5,234 ms centre cell. The centre cell is what the next rounds are measured on, so
a change that merges it with a batch would show here as a regression and later as an improvement
without either being one; read the cells a frame from the log when the longest frame moves.

AFTER round 565 (a streamed cell's terrain prepared on a worker thread, committed on the main
thread), against BASE re-measured the same day on the same box -- round 561's BEFORE predates
rounds 562-563 (`docs/RE_COMPLETION.md`, round 565, has the full lines). In this block and the
AFTER blocks below, (b)'s column is listed in the order its cells were committed -- 97, 96, 98,
95, 99/165, the same in every crossing run of rounds 565-567 -- not in region order: the 85 ms of
round 567's BASE is 98/165's, not 97/165's (labelled `95..99/165` until round 568; round 567's
review):

```
(a) BASE   cell 97/168 built in 5202 ms at frame 13; three cells a frame at 14-21
           region grid loaded in 22726 ms (terrain 7961, objects 4890, npcs 2331) at frame 22
               -- 25 cells 15181 ms, 7545 ms outside the cells over 10 awaited frames
           longest work frame 5265 ms at frame 13 (cell 97/168); p95 2841 ms; 9 over 100 ms
    565    cell 97/168 built in 5245 ms at frame 14 (synchronous by design); two a frame at 15-26
           region grid loaded in 19711 ms (terrain 2873, objects 5182, npcs 2375) at frame 27
               -- 25 cells 10430 ms, 9281 ms outside the cells over 14 awaited frames;
               terrain 5809 ms prepared off the main thread
           longest work frame 5306 ms at frame 14 (cell 97/168); p95 1772 ms; 13 over 100 ms
(b) BASE   97,96,98,95,99/165: 304, 304, 328, 271, 291 ms at frames 161-165 (terrain 231-262 each)
           longest work frame 334 ms at frame 163 (cell 98/165) over 575 frames; 5 over 100 ms
    565    97,96,98,95,99/165: 105, 127, 123, 73, 69 ms at frames 162-166 (terrain 39-44 each, and
               202-227 ms prepared off the main thread)
           longest work frame 144 ms at frame 163 (cell 96/165) over 570 frames; 3 over 100 ms
```

With `SRREVAMP_SYNC_LOAD=1` the same crossing command reads the old schedule back -- three cells a
frame under the screen, the column one a frame at 245-308 ms, `longest work frame 314 ms`.

AFTER round 566 (a streamed cell's objects prepared on the same task as its terrain, committed on
the main thread; the SHIPPED code, whose pump commits a finished cell before it dispatches the
next), against BASE (round 565's code) re-measured the same day on the same box
(`docs/RE_COMPLETION.md`, round 566, has the full lines and the per-phase sums). Until round 566's
second review this block held the first write's run, which dispatched first (crossing 112 ms,
entry p95 1025 ms):

```
(a) BASE   cell 97/168 built in 5208 ms at frame 14 (objects 1974 [.. own 308, templates 1573 ..])
           region grid loaded in 19795 ms (terrain 2810, objects 5346, npcs 2361) at frame 27
               -- 25 cells 10517 ms, 9278 ms outside the cells over 14 awaited frames;
               terrain 5795 ms prepared off the main thread
           longest work frame 5269 ms at frame 14 (cell 97/168); p95 1848 ms; 13 over 100 ms
    566    cell 97/168 built in 5073 ms at frame 13 (objects 1796 [.. own 318, models 1322,
               textures 6, templates 55 ..]; synchronous by design)
           region grid loaded in 18078 ms (terrain 2756, objects 2268, npcs 2434) at frame 29
               -- 25 cells 7457 ms, 10621 ms outside the cells over 17 awaited frames;
               terrain 5916 ms prepared off the main thread; objects 2869 ms prepared off the
               main thread
           longest work frame 5134 ms at frame 13 (cell 97/168); p95 990 ms; 8 over 100 ms
(b) BASE   97,96,98,95,99/165: 108, 123, 123, 70, 69 ms at frames 161-165
               (objects 65, 83, 42, 30, 26)
           longest work frame 140 ms at frame 163 (cell 98/165) over 571 frames; 3 over 100 ms
    566    97,96,98,95,99/165: 50, 46, 87, 51, 49 ms at frames 159-163 (objects 11, 7, 11, 10, 5
               on the main thread; 14-91 ms prepared off it)
           longest work frame 118 ms at frame 161 (cell 98/165) over 571 frames; 1 over 100 ms
```

An earlier run of the same shipped order (the review fix's, before the counter was corrected):
crossing `longest work frame 109 ms at frame 164 (cell 98/165)`, entry p95 947 ms, 7 over 100 ms.

The review fix of round 566 (`_pump_cell_jobs` commits a finished cell before it dispatches the
next; the `prepared again` line counts what a task prepared that another commit had cached),
dispatch-first (A, as first written) against finish-first (B), the same instrumented code, one run
each. Re-run by the second review fix with the corrected count (the first counter took textures a
job only NAMED from its snapshot for decoded ones, and the objects' `here` heightmap for one they
read; its A/B totals, 103 -> 66 and 145 -> 84, are withdrawn):

```
(a) A      region grid loaded in 17858 ms (terrain 2846, objects 2303, npcs 2510) at frame 29
               -- 25 cells 7659 ms, 10199 ms outside the cells over 16 awaited frames
           longest work frame 5090 ms at frame 14 (cell 97/168); p95 954 ms; 13 over 100 ms
           prepared again over the 24 streamed cells: 10 tiles, 8 object navmeshes, 2 heightmaps,
               16 models, 31 object textures (67); `decoded now` sum 58
    B      region grid loaded in 18078 ms (terrain 2756, objects 2268, npcs 2434) at frame 29
               -- 25 cells 7457 ms, 10621 ms outside the cells over 17 awaited frames
           longest work frame 5134 ms at frame 13 (cell 97/168); p95 990 ms; 8 over 100 ms
           prepared again: 3 tiles, 4 object navmeshes, 1 heightmap, 7 models, 13 object textures
               (28); `decoded now` sum 51
(b) A      97,96,98,95,99/165: 53, 51, 94, 49, 49 ms; longest work frame 114 ms at frame 164
               (cell 98/165)
               prepared again over 29 streamed cells: 102
    B      97,96,98,95,99/165: 50, 46, 87, 51, 49 ms; longest work frame 118 ms at frame 161
               (cell 98/165)
               prepared again: 32
```

The first pair (same code but the counter) read (b) 111 -> 109 ms and (a) p95 1004 -> 947 ms: at
one run each the order's effect on those frames is inside the run-to-run spread.

Alpha probes in the load path (`SRREVAMP_QA_ALPHA_LOG=1` on command (a); BASE through a throwaway
copy that prints the same line at each of its three `get_image()` probe sites): **0 before and 0
after** -- every layer of every material the 25 cells build is decided by its flag word
(`ObjectLoader.LAYER_FLAG_MASK`), so the readback path was never reached here. Forced with
`SRREVAMP_QA_MATS=1` as a control (every solid textured material then consults its fraction):
690 probes before, all texture readbacks; 690 after, 0 readbacks (449 on decoded Images, 241
statistics measured earlier), the same 341 texture/statistic pairs consulted the same number of
times and the same 52 `QA MAT` lines. 327 pairs read identically; 14 differ by at most 0.0002 of
a fraction, and 6 of those gave two values across the readback's own consults while the Image
gives one -- the readback is the unsteady side (none is near a threshold: 0.05 cuts, 0.20
reports).

AFTER round 567 (a region's terrain collision is a `HeightMapShape3D` over its height grid,
`TerrainCollision`, instead of a `ConcavePolygonShape3D` of the mesh's triangles), against BASE
(round 566's code) re-measured the same day on the same box, and the same code with
`SRREVAMP_TERRAIN_TRIMESH=1` (the old trimesh, for A/B); `docs/RE_COMPLETION.md`, round 567, has
the full lines, the per-phase sums and the ground probes. The streamed-cell sums are over the
cells' own lines (the entry's 24 neighbours, the crossing run's 29 streamed cells). Which code:
BASE ran `git archive f25ab65`; the 567 and TRI runs ran round 567's code before
`SRREVAMP_QA_GROUND_RAYS` was changed to wait for the grid -- a QA-only hook neither run enables
(round 567 says so; its ray runs, `rays3_*`, ran the committed code). The entry's p95 950 -> 914
ms is inside run-to-run spread (TRI, the old collision on the same code, read 957); the frames over
100 ms (9 -> 5, TRI 9) and the per-cell `collision` lap are the numbers that moved (round 567's
review). A crossing's own entry drain (its `region grid loaded` line) is (a)'s command plus
`--at 120,1020`, so it is compared with (b)'s drain below, not (a)'s: round 572 compared its
crossing's 17754 ms with (a)'s 17299, and the review caught it. (b)'s drains were read off
`/var/tmp/r567/{base,after,tri}_cross.log` in round 574; no record had quoted them:

```
(a) BASE   cell 97/168 built in 5035 ms at frame 14 (terrain 1563 [.. faces 7 .. collision 27 ..])
           region grid loaded in 18042 ms (terrain 2753, objects 2248, npcs 2448) at frame 30
               -- 25 cells 7449 ms, 10593 ms outside the cells over 17 awaited frames
           longest work frame 5095 ms at frame 14 (cell 97/168); p95 950 ms; 9 over 100 ms
           24 streamed cells: built in 2399 ms; terrain commit 1177, collision 657 (23-37 each)
    567    cell 97/168 built in 5011 ms at frame 13 (terrain 1528 [.. heights 3 .. collision 0 ..])
           region grid loaded in 17299 ms (terrain 2054, objects 2283, npcs 2421) at frame 29
               -- 25 cells 6757 ms, 10542 ms outside the cells over 17 awaited frames
           longest work frame 5074 ms at frame 13 (cell 97/168); p95 914 ms; 5 over 100 ms
           24 streamed cells: built in 1735 ms; terrain commit 513, collision 0 (every cell)
    TRI    region grid loaded in 18048 ms (terrain 2739, ...); p95 957 ms; 9 over 100 ms
           24 streamed cells: built in 2345 ms; terrain commit 1160, collision 656
(b) BASE   97,96,98,95,99/165: 50, 45, 85, 49, 49 ms at frames 161-165
               (collision 24, 24, 25, 26, 27)
           longest work frame 106 ms at frame 163 (cell 98/165) over 569 frames; 1 over 100 ms
           29 streamed cells: built in 2617 ms; terrain commit 1367, collision 791
    567    97,96,98,95,99/165: 29, 21, 60, 23, 22 ms at frames 162-166 (collision 0 each)
           longest work frame 86 ms at frame 164 (cell 98/165) over 569 frames; 0 over 100 ms
           29 streamed cells: built in 1868 ms; terrain commit 584, collision 0
           its own entry drain: region grid loaded in 17395 ms at frame 30; p95 930 ms;
               5 over 100 ms (BASE 18401 ms, p95 954, 8; TRI 18544 ms, p95 967, 8)
    TRI    97,96,98,95,99/165: 49, 45, 85, 48, 49 ms (collision 24-27); longest work frame 113 ms at
               frame 163 (cell 98/165); 1 over 100 ms
```

The `heights` lap is the prepare's (off the main thread for a streamed cell: 86 ms over the
entry's 24 against `faces`' 193). The heightfield's `collision` lap reads 0 on every cell line --
whole-ms truncation, so under 1 ms a cell. `SRREVAMP_QA_GROUND_RAYS=n` (World3D.gd's QA header)
is the regression probe for the ground itself: on an n x n lattice of every loaded region it fires
vertical and slanted rays at the terrain collision and holds each hit to the drawn mesh's own
triangle, sweeps the camera arm's sphere down (`cast_motion`, the camera spring's query) and moves
the player's own body down (`body_test_motion`, move_and_slide's), printing `QA GROUND` lines to
diff between a run and a `SRREVAMP_TERRAIN_TRIMESH=1` run.

Rules the off-thread loading items are held to, kept beside the benchmark so the two travel
together. Round 565 (terrain) implements them, and round 566 (objects) holds to them too.

1. **The prepare-thread rule.** A prepare constructs NO Node and NO RID-owning Resource --
   no `MeshInstance3D`, `StaticBody3D`, `ArrayMesh`, `Material`, `ImageTexture` or `Shape3D`;
   Images, packed arrays, Arrays, Dictionaries and the readers' RefCounted structs only -- touches
   neither the scene tree nor the RenderingServer nor the PhysicsServer, and prints none of its
   own lines (they go in the job; the commit prints them in order) -- though a reader it calls
   may still `push_error` from the task on a malformed file (`DdjReader.to_image`'s "failed to
   build Image", `MapmTerrainBuilder`'s "region has N blocks", the `MapmReader` / `NvmReader` and
   object readers' parse errors; worded "prints nothing" until round 568, round 565's review). A
   main-thread commit builds the objects.
   World3D's `_terrain_prepare` is static, so it cannot reach the node's state;
   `terrain_prepare_test.gd` walks a prepared job and fails on any Node or Resource in it other
   than an Image. Round 566: `_objects_prepare` and `_cell_prepare` are static too, and
   `ObjectLoader.prepare_object` writes nothing static (what `_missing` would report and the QA
   lines go in its result, for `commit_object` to report); `objects_prepare_test.gd` and
   `object_loader_test.gd` walk the same way. No texture is read back to decide a material's
   alpha: the probes measure the Image the texture is uploaded from (`ObjectLoader._alpha_stat`),
   and `SRREVAMP_QA_ALPHA_LOG=1` prints one `QA ALPHA:` line per probe consulted -- the count of
   alpha probes in the load path, each saying it came from the decoded Image or from a statistic
   measured earlier.
2. **Reads and caches.** The scene tree is not thread-safe, and `Pk2Reader` was not until round
   565: one handle shares one `FileAccess` (a read is a seek then a get_buffer) and one directory
   cache, and it now takes a per-handle lock around both (`pk2_reader_test.gd` runs 4 tasks x 200
   concurrent reads). Every World3D cache a prepare consults is snapshotted into its job on the
   main thread before dispatch (`_terrain_job`: ground tiles by filename and a decoded flag, never
   the texture; the region's cached navmesh; a copy of the object navigation meshes;
   `_objects_job`, round 566: the template paths held, the uploaded textures by key, fourCC and
   measured alpha statistics, never the texture, and the heightmaps the grid holds), and the
   commit merges what the prepare read back into the caches, keeping an entry another commit
   cached first. `_pump_cell_jobs` commits a finished cell BEFORE it dispatches the next (round
   566's review; it dispatched first until then), so the next snapshot holds what that commit
   cached. Each committed streamed cell prints `World3D: cell x/y prepared again what an earlier
   commit had cached -- N ground tile(s), N navmesh(es), N object navigation mesh(es), N
   heightmap(s) the objects read, N model(s), N object texture(s) decoded` (`_prepared_again`,
   counted before its commit merges anything): what its task read or built that a commit landing
   after its snapshot had already cached, so it was thrown away -- a texture only if the task
   decoded it (one its snapshot held is named, not decoded, and not counted -- unless
   `_alpha_stat` decoded it again for a statistic the snapshot lacked and a commit since has
   carried that statistic in, which counts from round 568), a heightmap only if
   the objects read it (not the region's own, taken from the terrain prepare's parse). It can stay
   above zero: a job cannot see what the job preparing beside it will commit (the entry's 24
   cells: 28 finish-first, 67 when the pump dispatched first; `docs/RE_COMPLETION.md`, round
   566). The placement-ownership test's
   neighbour heightmaps are READ ON THE TASK, under the lock, not pre-parsed on the main thread:
   their parse is most of the `own` lap, which pre-parsing would put back in the frame.
3. **The QA-drain contract.** A QA run (`SRREVAMP_MAPM_PATH` set, no `SRREVAMP_QA_FORCE_LOADING`)
   must still have every cell committed before its first shot, so `_drain_initial_load`'s QA branch
   dispatches, waits for each task (`WorkerThreadPool.wait_for_task_completion`) and commits
   before it returns -- `--shots`, `--radius` and the movie writer keep their contract.
4. **Stale jobs.** A prepared cell is committed only if it is still wanted (not loaded meanwhile,
   still inside the player's window -- else `cell x/y prepared but not committed -- <why>`), and
   a zone change, a new grid and the world leaving the tree wait for every task still running
   and drop it (`N cell(s) still preparing dropped (<why>) -- waited M ms`), so a reconnect cannot
   commit into a freed world. `objects_prepare_test.gd` holds the guard and the drop headless
   since round 568 (no box log of rounds 565-567 carries a `prepared but not committed` line).

`SRREVAMP_SYNC_LOAD=1` is the escape hatch for one release after round 565: every cell's terrain
and (round 566) objects are prepared and committed on the main thread on the pre-round-565
schedule (above), for a tester to fall back to or compare against. It restores the SCHEDULE
only, not the old code: the terrain still runs `_terrain_prepare` then `_terrain_commit` with
the collision round 567 gives it (the heightfield; the faces `MapmTerrainBuilder.surface_faces`
builds under `SRREVAMP_TERRAIN_TRIMESH=1`), and the objects `_objects_prepare` then
`_objects_commit`, through the split `ObjectLoader` (`prepare_object` then `commit_object`) and
the trimesh faces `ObjectLoader._piece_faces` builds -- back to back on the main thread. The
grid's centre is built on the main thread either way -- its height anchors every neighbour and
its environment lights them.

`dump_ddj.gd` — writes any real `.ddj` texture out as a PNG, and reports its fourCC, the format it
decompresses to, and how many texels are opaque, transparent or partial. Written to settle which
spelling of the region minimap filename was real (`<y>x<x>.ddj`), and useful whenever a texture
renders wrong and the question is whether its alpha survived decoding.

`check_object_yaw.gd` — measures which yaw convention places map objects where a region's own
`.nvm` says they are: every navmesh object's navigation mesh is placed under eight candidate
conventions and scored against the cells that list it and the object-to-object linked edges, with
`--scan` to sample regions across the map and `--list` to name the objects whose yaw can tell the
conventions apart. Written for round 506, where it confirmed (with the client binary's own matrix)
that the game's turn is the negated yaw.

`probe_monster_front.gd` — measures which way each roster monster's body faces in the space its
skeleton is placed in: the mean toe-minus-foot bone vector and the head-minus-pelvis offset, at the
bind pose and at the walk clip's first frame, with the player's body (`CHAR_CH_MAN_FIGHTER`, local
-Z) as the control -- the run counts only if its last line says the control reads -Z. It resolves
each species the way World3D does (by code, then by display name) and prints one `MODEL <bsr>
<front>` line per model; those are `MonsterMotion.FRONT_BY_MODEL`. Headless, renders nothing; ship
the working copy first (`script` does not sync):
`client/tools/remote_godot.sh sync && client/tools/remote_godot.sh script res://tools/probe_monster_front.gd -- --pk2=/opt/sro-files/client/Data.pk2 --media=/opt/sro-files/client/Media.pk2`.
Written for round 533, where all seven roster models read -Z. `--all=1` (round 673) measures every
model a `MOB_` row draws (155) instead of the roster and ends with a `TALLY` line: 117 read -Z, 36
name no axis, 2 (the event Jinn pets) read +Z on one weak reading, none +-X -- the evidence for
`MonsterMotion.MODEL_FRONT`, which since round 673 turns every drawn model (the table is gone).

`plate_pixels.py` (round 673) counts a name plate's own pixels in a movie frame where the client
says it projects: a run with `SRREVAMP_QA_SHOTS` and `SRREVAMP_QA_PLATES=1` prints one `QA PLATE`
line per monster at each shot (its distance from the camera and from the player, its screen point),
and the tool counts cream-beside-black pixels in a 140 x 22 box there. Pure Python (the box has no
PIL); run it on the box against the run's directory: `python3 plate_pixels.py <dir>` (add `--white`
for the round's retail monster look -- white glyphs on a translucent box, no outline -- which
counts pixels >= 235 in every channel instead). Round 673's
before/after: the same monster 73 from the player had 97 plate pixels at camera distance 87 and none
at 103 (looking straight down) before, and its name at every shot after.

`probe_seasonal.gd` counts what round 583's seasonal filter leaves out of real regions. It runs
World3D's own `_objects_job` and `_objects_prepare` over each region (Jangan's nine by default,
`--region=<y>/<x>` for others) and prints the hidden count per set. It also counts the seasonal
object records in each region's `.nvm`. `--seasonal=<list>` stands in for `SRREVAMP_SEASONAL`,
which the remote runner does not pass through. `--full=1` runs the prepare to the end, reading
every model, and counts the seasonal pieces still among the placements (`DRAWN`). It is headless
and takes seconds. Ship the working copy first:
`client/tools/remote_godot.sh sync && client/tools/remote_godot.sh script res://tools/probe_seasonal.gd -- --map=/opt/sro-files/client/Map.pk2 --data=/opt/sro-files/client/Data.pk2`.

`render_asset.gd` — loads a real mesh + real texture from a real pk2 archive through this
project's own readers (`Pk2Reader`, `BmsReader`, `DdjReader`) and renders a screenshot to disk.

`render_skeleton.gd` — loads a real `.bsk` skeleton file (not necessarily from a pk2 — real
samples so far have only been found as loose files, see `docs/protocol/BSK_FORMAT.md`) through
`BskReader` and renders its bone hierarchy (a line segment per bone-to-parent connection, a small
sphere at each joint) to disk.

`render_skeleton_animated.gd` — loads a real `.bsk` skeleton and a real `.ban` animation, applies
the animation's rotation (relative to its own first keyframe) to one named bone and all of its
descendants via simple forward kinematics, and renders two screenshots (bind pose vs. animated
pose) so the movement is visible as a before/after comparison. The `.ban` and `.bsk` files don't
need to be from the same character/skeleton — this demonstrates the playback mechanism against
any real keyframe data landing on a matching bone name, not a claim that a specific animation
belongs to a specific skeleton.

`render_skeleton3d_animated.gd` — the real-engine counterpart to `render_skeleton_animated.gd`:
loads a real `.bsk` skeleton and a real `.ban` animation, builds an actual Godot `Skeleton3D` via
`Skeleton3DBuilder`, and applies the animation's rotation via `Skeleton3D`'s own pose-rotation
propagation (not manual per-bone math) — every descendant bone moves correctly through the
engine's real hierarchy. Renders the same bind-pose/animated-pose before/after comparison.

`render_character.gd` — loads a real `.bsk` skeleton and a directory of real body-part `.bms`
meshes (loose files — see `docs/protocol/BSK_FORMAT.md`), assembles them rigidly via
`CharacterAssembler`, and renders a screenshot. Rigid, because it predates the finding that
`.bms` carries per-vertex skinning after all (`docs/protocol/BMS_FORMAT.md`); the game itself
assembles a character through `SkinnedBsrAssembler` from its `.bsr`.

`check_item_requirements.gd` — characterises the item table's equipment rows against a real
archive: that column 52's worn model exists in Data.pk2 for every row (7,264 of 7,264), that the
code name's race/gender/piece letters agree with `Country`/`ReqGender`/`TypeID4`, and which
requirement types occur (1, and the six European mastery ids). The measurements behind
`docs/protocol/ITEM_FORMAT.md`.

`extract_pk2_file.gd` — copies one file out of a pk2 archive to disk, for picking a format apart
offline against several files at once (how the `.bsr` animation-group layout was settled). What
comes out is game data: keep it in a scratch directory, never in the repo.

`dump_text_table.gd` — prints any `server_dep\silkroad\textdata\*.txt` table with every column
numbered, so a column index can be read off rather than counted; several of those tables carry
their own header row naming the columns. `dump_ddj_sizes.gd` prints the pixel size and
compression of named `.ddj` textures — a frame's insets, a name plate's cap width — so those
numbers are measured rather than eyeballed. Both take forward slashes in archive paths, because
backslashes do not survive ssh and su to the render box.

`check_2dt_files.gd` — reads every `res_ui\*.2dt` window file in a real `Media.pk2` with
`TwoDtReader` and checks each the way the client's loader takes it: the size is exactly
`4 + count * 976`, one root at record 0, every (parent, grandparent) link resolves, the string
fields are ASCII, and every texture piece `TwoDtBuilder` derives exists in the archive. It also
measures the tile-before-content draw order the builder relies on. `docs/protocol/2DT_FORMAT.md`
is the format.

`render_map_objects.gd` — loads a real `.o` (`Map.pk2` object-placement) file through
`MapoReader` and renders a top-down scatter of every placed object's real world position, colored
by type ID, to disk. Doesn't resolve type IDs to real `.bsr` models — no mapping from a `.mapo`
type ID to a resource path has been found anywhere in this project's data (see
`docs/protocol/MAPO_FORMAT.md`), so this renders simple colored markers, not the actual scenery.

## Godot runs on the render box, never here

AGENTS.md's hard rule. `remote_godot.sh` ships the working copy to
`192.168.10.78` and runs the command there, so following it is one line:

```
client/tools/remote_godot.sh check     # every script and scene compiles
client/tools/remote_godot.sh tests     # every *_test.gd (discovered, not listed)
client/tools/remote_godot.sh script '--script res://tools/dump_layout.gd -- --pk2=... --file=ifinventory'
client/tools/remote_godot.sh sync      # ship the working copy, run nothing
```

`check` and `tests` run the import first, because `check_scripts.gd` cannot
tell a broken script from an unregistered `class_name` on a cold cache.

`tests` marks a suite failed on a `FAIL` line, a `Parse Error`, or a
`SCRIPT ERROR` -- Godot's line for a GDScript runtime error (a call on a
freed instance, a script that failed to compile). Such an error aborts only
the function it happened in and lets the suite go on to `ALL PASS`, so
until round 556 a suite could pass while a script errored (round 522 saw
`hud_window_test.gd` do it on every run; round 551's freed-panel negative
printed the error and `ALL PASS` in one output). The `at:` line under the
error is printed with it. `ERROR:` does not fail a suite: readers
`push_error` on the bad input their negative cases feed them (20 of 85
suites in round 556's audit), and the dummy renderer reports leaked RIDs
at exit (3 more: `character_assembler`, `monster_assembler`, `hud_window`).
A suite that errors in `_init` before its `quit()` does not fail;
it hangs, because the run never ends -- put the checks in a callee, or
reach a method through `has_method`/`call` so a missing one FAILS instead.

