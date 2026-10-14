# Environment/lighting preset table (JMXVENVI, `environment.ifo`)

`environment.ifo` is the real per-preset environment/lighting table `.m`'s per-block
`EnvironmentID` field (see [MAPM_FORMAT.md](MAPM_FORMAT.md)) references.

## Corrected 2026-08-23: this file was never absent — wrong archive, again

An earlier pass (same day) declared this file "entirely absent" after checking `Data.pk2`'s pk2
root and its `navmesh\` folder, the two real locations `object.ifo`/`tile2d.ifo`/etc. turned out to
live at. That conclusion was wrong for the same reason the real ground textures were wrongly
declared absent (see [TILE2D_FORMAT.md](TILE2D_FORMAT.md)'s "Corrected 2026-08-23" section): this
file actually lives in **`Map.pk2`'s root** (76,000 bytes in the one real client install checked),
an archive that search never checked. Re-verified directly via `server/cmd/pk2list` against a real
`Map.pk2`.

## Source

No public documentation for this specific file's internal structure was found (a GitHub code
search across [`JellyBitz/srodevs-docs`](https://github.com/JellyBitz/srodevs-docs) for
"environment.ifo" only turned up an unrelated mention of the `EnvironmentID` field name itself, in
that repo's `.m` spec). The real structure below was reverse-engineered from scratch against a real
`sro_client.exe`, on RE infrastructure this project controls, following `docs/LEGAL.md`'s
clean-room policy: decompiler output was used only to derive the plain-English facts recorded
here, never pasted into this repo, and the implementation (`client/scripts/environment/
environment_reader.gd`, `server/internal/environment/environment.go`) is original code written
independently against those facts.

**Method**: found the real string reference to `"environment.ifo"` in `sro_client.exe`, traced it
to the real function that opens it (part of a larger combined loader also responsible for
`object.ifo`/`objext.ifo`/`objectstring.ifo`/`tile2d.ifo` — see [MAPO_FORMAT.md](MAPO_FORMAT.md)),
found the real per-record reader function it calls once per record, and decompiled that function's
two real vector-append helpers to confirm their element sizes (a 4-float push vs. a 2-float push).
Cross-checked the resulting hypothesis against a real 76,000-byte sample using an automated
byte-level parser until it reached a byte-exact, zero-leftover result across all 74 real records —
the same rigor bar this project holds every other format to (see `.m`/`.t`/`.nvm`'s own accounts).

This took real, substantial trial and error: several plausible-looking manual byte interpretations
turned out to have subtle bugs (a wrong element size, an extra/missing fixed field) that produced
sane-looking small numbers for the first few blocks of the very first record before diverging later
— exactly the kind of error this project's users have previously caught in earlier sessions.
Getting a **complete, automated, zero-leftover parse of all 74 real records** (not just "the first
record looks plausible") is what makes this a confirmed structure rather than a guess.

## Real structure

```
12   string  Signature              // "JMXVENVI1003" (magic + version, no separator)
4    uint    RecordCount
2    ?       Reserved               // real, fixed; 0 in the one real sample checked; purpose unconfirmed
foreach(RecordCount): Record
```

Each real `Record`:

```
1    byte    Key                    // real single-byte ID -- .m's per-block EnvironmentID references this
1    byte    Pad                    // real, always 0 in the one real sample checked
4    uint    Name1Length
Name1Length  string  Name1          // real preset name, e.g. "Env7", "Env8" -- reused across many records
4    uint    Name2Length
Name2Length  string  Name2          // real secondary name field; empty in every record of the one sample checked
4    ?       Reserved2              // real, fixed; 0 in the one real sample checked; purpose unconfirmed
foreach(16 real Channels, in this fixed order): Channel
```

Each real `Channel` (the *i*-th channel's group size is fixed by its position, not stored per-file):

```
4    uint    GroupCount
foreach(GroupCount): float[N]       // N = 4 for channels 0-6, 9, 13-14; N = 2 for channels 7-8, 10-12, 15
```

The real per-channel group-float-count sequence, in real file order, confirmed via the decompiled
reader's two real vector-append helpers (one pushes 4-float groups, the other 2-float groups) and
independently confirmed by successfully parsing all 74 real records with zero leftover bytes:

```
[4, 4, 4, 4, 4, 4, 4, 2, 2, 4, 2, 2, 2, 4, 4, 2]
```

(10 real 4-float channels, 6 real 2-float channels — a version-gated field count in the decompiled
reader implies older format versions ("1000"/"1001"/"1002") have fewer real channels than "1003",
but only a "1003" sample has been checked, so the shorter variants aren't confirmed here.)

## Channel names: found via public documentation (2026-08-31)

A public wiki, [`DummkopfOfHachtenduden/SilkroadDoc`](https://github.com/DummkopfOfHachtenduden/SilkroadDoc/wiki/JMXVENVI)
(fair game per `docs/LEGAL.md` point 3 — public, long-published community documentation, not
decompiled from a binary in this repo's own history), documents this exact format under the same
`JMXVENVI1003` magic and gives each channel a real name, in file order:

```
0  SunColor              (4-float ColorGraph: RGB + time)
1  SkyTopColor           (4-float ColorGraph)
2  DiffuseColor          (4-float ColorGraph)
3  ObjectAmbientColor    (4-float ColorGraph)
4  (unnamed -- "Graph4" in the public doc)
5  TerrainAmbientColor   (4-float ColorGraph)
6  TerrainShadowColor    (4-float ColorGraph, added v1003)
7  "FogNearPlane" per the public doc -- WRONG for this client, see below (2-float FloatGraph)
8  "FogFarPlane"  per the public doc -- WRONG for this client, see below (2-float FloatGraph)
9  FogColor              (4-float ColorGraph)
10 FOG NEAR PLANE, as a fraction of the view distance (read from the client, below)
11 FOG FAR PLANE,  as a fraction of the view distance (read from the client, below)
12 (unnamed -- "Graph12", added v1001)
13 SkyBottomColor        (4-float ColorGraph, added v1002)
14 WaterColor            (4-float ColorGraph, added v1002)  -- READ round 627: the water texture factor, see below
15 (unnamed -- "Graph15", added v1002)
```

## The fog planes are channels 10 and 11, times the view distance (read 2026-09-19, round 229)

The public naming above puts the fog planes at 7 and 8. The client's own environment
update says otherwise. `Map::FUN_00a1baf0` (`sro_client.exe`, `0xa1baf0`) evaluates the
six FloatGraphs of the current record through `FUN_004e5770` in file order -- the graph
objects sit at record `+0x25c, +0x288, +0x2e8, +0x314, +0x340, +0x36c` (stride 0x2c; the
ColorGraphs are 0x34 apart), i.e. channels 7, 8, 10, 11, 12, 15 -- and treats them as:

| call | record offset | channel | transform | stored at |
|---|---|---|---|---|
| 1 | `+0x25c` | 7 | `(v + 1.0) * 0.5` (doubles at `0xe1b7f0`, `0xe1b7d0`) | world `+0x689b` |
| 2 | `+0x288` | 8 | clamp to [-1, 1] (`0xe1b878`), then `2.0 - (v + 1.0)` (`0xe1b898`) | world `+0x689f` |
| 3 | `+0x2e8` | **10** | **`v * viewDistance`** (`fmul DWORD PTR ds:0xec54b0`) | world `+0x68af` -- **fog near** |
| 4 | `+0x314` | **11** | **`v * viewDistance`** | world `+0x68b3` -- **fog far** |
| 5 | `+0x340` | 12 | `(v + 1.0) * 0.5` | world `+0x68c7` |
| 6 | `+0x36c` | 15 | raw | |

The no-record fallback names the roles: it sets the same two slots to `-0.2 * viewDistance`
(the double at `0xde4d00`) and `1.0 * viewDistance` -- a linear fog whose near plane sits a
fifth of the view distance behind the camera and whose far plane is the view distance. The
view distance is the `.data` float at `0xec54b0`, **2500.0** in the image (a setting may
change it at runtime). The values are eased toward per frame (the `(new - old) * f + old`
lines that follow), then applied as the fog range.

The real files agree, which is the second, independent half (`client/tools/
dump_environment_floats.gd`, all 74 records): channel 10 ranges over **[-0.147, 0.813]** and
channel 11 over **[0.467, 1.0]** -- a near fraction that may dip slightly behind the camera
and a far fraction at or inside the view distance -- while 7, 8, 12 and 15 range over
[-1, 1], the shape the `(v + 1) / 2` and `1 - v` transforms expect. Jangan's `Env7`
(record 7): near 0.5, far 0.9 -> 1250 and 2250 world units at the default view distance.

What 7, 8, 12 and 15 mean is not named here: the world fields they land in (`+0x689b`,
`+0x689f`, `+0x68c7`) were not followed to their shader constants in this pass.

`EnvironmentReader.CHANNEL_FOG_NEAR_PLANE/FAR_PLANE` are 10 and 11 accordingly, and
`VIEW_DISTANCE_DEFAULT` is 2500. Since round 702 the client draws them: `WorldFog` is the
original's linear fog in view depth between the two planes (times the Background Sight Range's
view distance), as `Map::FUN_00a26f60` sets it up (FOGENABLE, FOGCOLOR, RANGEFOGENABLE 0, table
or vertex fog LINEAR); Godot's exponential fog draws nothing.

**This matches this project's own independently-confirmed real per-channel group-float-count
sequence exactly** (`[4,4,4,4,4,4,4,2,2,4,2,2,2,4,4,2]`, derived from decompiling the real reader's
vector-append helpers, see above) — the same channel count, in the same order, with 4-float
channels landing exactly where the public doc names a `ColorGraph` and 2-float channels landing
exactly where it names a `FloatGraph`. That structural agreement, arrived at independently and only
compared afterward, is strong corroborating evidence this public source is accurate for this
project's own real files, not just plausible.

Also confirms the public wiki's broader scene-command list includes `S_SetWorldTime` — a real,
separate confirmation that a genuine dynamic time-of-day system exists in the original client, not
just a per-zone static "look."

The "Real values" section below (written before this public source was found) already independently
guessed at several of these same semantics purely from the data's shape (e.g. calling channel 1 a
real day-color sky track) — kept as-is below since it shows the pattern-matching held up, not
rewritten to pretend the names were known from the start.

## Real values, and what they probably mean

In the one real sample checked (74 records), channel values are overwhelmingly `0.0`/`1.0`, with
some records showing small non-0/1 fractional values (e.g. `0.58`, `0.1`, `0.9`, `0.5`) in specific
channels. This is consistent with real RGB-plus-weight or scalar-plus-time lighting/fog/sky
blend-keyframe data (the kind of thing an "environment" preset in this genre of client typically
holds), but **no per-channel semantic meaning is confirmed** (e.g. "channel 0 is ambient light
color") — this project does not assign channel names or wire this data into rendering, to avoid
overclaiming a specific interpretation this project can't verify.

### Update 2026-08-31: strong evidence this is a real day/night color-keyframe cycle

Checked the real records the two zones this project actually renders reference (via each zone's
real `.m` per-block `EnvironmentID`, cross-referenced against `environment.ifo`'s real `Key` field):
Jangan (`89/182`, all 36 blocks) uses `Key=15` (`Name1="Env7"`); Dunhuang (`98/157`, all 36 blocks)
uses `Key=1` (`Name1="Env1"`) — **confirming different zones really do reference different real
records**, i.e. this genuinely is per-zone (not a single global constant), settling
`TILE2D_FORMAT.md`'s and this file's own earlier "per-block/per-zone lighting, unconfirmed whether
it's used" question.

Within each of those two real records, the pattern across the 4-float channels (0-6, 9, 13-14) is
unmistakable, not a coincidence:

- Every group's 4th value is a real, monotonically increasing number from `0.0` to `1.0` (Jangan's
  channel 0: `0, 0.25, 0.50, 0.667, 0.75, 0.88, 1.0`) — consistent with a normalized time-of-day
  axis, not an arbitrary index.
- The first 3 values at each of those points trace a real, recognizable daily color arc: dark
  blue/near-black at `t=0` (night) → a warm, saturated tint around `t=0.25` (sunrise) → white/bright
  around `t=0.5` (midday) → warm again around `t=0.75` (sunset) → back to the same dark value at
  `t=1` (a real seamless loop back to night — the `t=0` and `t=1` groups are identical in every
  channel checked).
- The two zones' actual RGB values differ in exactly the way two different real biomes would (Jangan
  channel 4 peaks near pure white at midday; Dunhuang's equivalent peaks warmer/dustier, consistent
  with a desert zone), while sharing the identical structural shape (same keyframe count, same `t`
  progression) — real per-zone *palette*, shared *mechanism*.

This is strong enough to call it a real day/night lighting-cycle table with real per-zone color
palettes. **Superseded by the public-documentation channel names found later the same day** (see
"Channel names" above) — channel 1 really is `SkyTopColor`, channel 9 really is `FogColor`, channel
13 really is `SkyBottomColor`, each independently matching the day-arc shape this section already
described before the names were known. The 2-float channels 7/8 are `FogNearPlane`/`FogFarPlane`
per the public doc, though their real values (e.g. channel 7's `[-1..-0.3]` range) don't read like
literal world-space distances at face value — possibly a normalized or otherwise-transformed
parameter; not re-verified further this round.

## Unparsed trailer: a real "Root(Environment)" tree

The real per-record data (74 records) ends at byte offset 73,484 of the one real 76,000-byte sample
checked, leaving a real 2,516-byte trailer that is **not** more record data — it contains real,
readable text including the literal string `"Root(Environment)"` followed by real length-prefixed
Korean-language (CP949/EUC-KR-shaped byte sequences) child-node labels. This looks like a real
environment-preset **organizational tree for the original level editor's UI** (grouping presets
into named folders), not runtime-consumed per-region lighting data. `ParsedFile.trailer_offset`
(GDScript) / `ParsedFile.TrailerOffset` (Go) marks exactly where this trailer starts, for any future
work that wants to parse it further — not attempted here, since it's very likely tooling metadata,
not gameplay-relevant, and this project's real per-record structure (the actual `.m`
`EnvironmentID` lookup target) is already fully solved.

## Implementation

`client/scripts/environment/environment_reader.gd` (`EnvironmentReader`) and
`server/internal/environment/environment.go` both parse the real structure above, deterministically
(every count is real and self-describing). Both have test coverage against a real byte-exact
synthetic fixture; the GDScript reader is additionally live-verified against the real 76,000-byte
sample (all 74 records parse, `trailer_offset` lands exactly at the real
`"Root(Environment)"` boundary).

**Update 2026-08-31**: the real per-channel semantic meaning is now confirmed (see "Channel names"
above) via public documentation whose structure independently matches this project's own
decompiled channel-size sequence exactly. Renderer wiring using `SkyTopColor`/`SkyBottomColor`/
`FogColor` is now real, justified work (not a guess) — see `docs/WORLD_ISSUES.md`'s next round for
whether/how it was implemented.

## WaterColor is the water's tint (read 2026-09-28, round 627)

The record reader `Map::FUN_00a1b650` reads the ColorGraphs for channels 13 and 14 into
record+0x1f4 and record+0x228. It reads them after channel 12, and only for version >= 1002. Its
channel order is 0-6 at +0x88..+0x1c0; 7 and 8 at +0x25c and +0x288; 9 at +0x2b4; 10-12 at
+0x2e8..+0x340; 13 and 14 at +0x1f4 and +0x228; 15 at +0x36c.

`Map::FUN_00a1baf0` evaluates +0x228 into world+0x688f..0x6897 and clamps it to [0, 1].
`Map::FUN_00a220b0` then sets that colour, times 255, as the D3D texture factor's RGB. The alpha
byte is 0xB4. The water's frame texture is modulated by it. MEASURED values at the reference time:
- environment 1 (the 98/159 lake): (0.64, 0.56, 0.38);
- environment 15 (Jangan): (0.36, 0.69, 0.62).

## Channels 4 and 12 are the cloud layer's (read 2026-09-28, round 628 review follow-up)

The cloud layer (`Map::FUN_00a3f570`) draws `cloud1.ddj` modulated by a texture factor.
- Its RGB is the sky object's +0x18c..+0x194. `FUN_00a3eb40` copies that from its sixth argument,
  world+0x685f, which `Map::FUN_00a1baf0` evaluates from record+0x158: **channel 4**.
- Its alpha is world+0x68c7 x 255, and world+0x68c7 = **(channel 12 + 1) / 2**.

MEASURED at the reference time 0.5:
- environment 15 (Jangan): colour (1.00, 1.00, 1.00), alpha 0.755;
- environment 1: colour (0.91, 0.99, 0.99), alpha 0.743.


## The fog colour is the square root of channel 9 (read 2026-09-28, rounds 623-628 integration review)

`Map::FUN_00a1baf0` clamps channel 9 (record+0x2b4) into world+0x68a3..0x68ab, each to [0, 1]. It
then stores the square root of each (`FUN_00b42de0` is the CRT `sqrt`, with `fsqrt` at 0xb42e1c;
the calls are at 0xa1d164, 0xa1d17b and 0xa1d192) into world+0x68b7, 0x68bb and 0x68bf.
`Map::FUN_00a26f60` packs those × 255 into world+0x67e6 and sets it as `D3DRS_FOGCOLOR` (0x22)
before the landscape draws. So a channel value of 0.25 fogs to 0.5
(`EnvironmentReader.render_fog_color`). The unrooted channel also goes into world+0x67e2, whose
use was not followed.

MEASURED, Jangan (environment 15) at the reference time 0.5: channel 9 is (0.357, 0.580, 0.677)
and the rendered fog is (0.598, 0.762, 0.823).

## The day phase, the spline, and the sun and moon (read 2026-10-13, round 786)

The "reference time 0.5" above is midday. **The world is not drawn at a fixed 0.5**: the game
clock sets SWorld's phase every frame (`CPSMission::vslot_012` -> `FUN_0084ac90` -> SWorld vtable
+0x50; [game_clock.md](game_clock.md) has the chain and the clock-hour -> phase map, and the
correction of round 226). How the phase becomes the picture, READ from `sro_client.exe`:

**Which record.** `Map::FUN_00a1baf0` takes the record of the first block of its drawn-block list
(`**(world+0x2783) + 4`), the camera's own block (MapmWater.environment_at has the chain): one
record for the whole world, which changes as the camera crosses blocks.

**The graphs' interpolation.** `FUN_004e55e0` (ColorGraph, 16-byte keys, time at +0xc) and
`FUN_004e5770` (FloatGraph, 8-byte keys, time at +4) find the first key whose time is >= the
phase; none: the last key's value; the first: its value; otherwise, with p the key before it,
`frac = (t - time[p]) / (time[p+1] - time[p])` (0 for a gap <= 0.0001, the float at 0xe1b880) and
the graph's interpolator through key[p-1] (key[0] when p = 0), key[p], key[p+1], key[p+2]
(key[p+1] when p+1 is the last). The interpolator is the function pointer at graph +0x10, set by
the record's graph constructors to `FUN_004e0920` (colour, `mov [esi+0x10],0x4e0920` at
0xa1ba6c) and `0x4df7d0` (float, 0xa1bacc): both the **uniform Catmull-Rom spline**
`0.5 (2 P1 + (P2 - P0) f + (2 P0 - 5 P1 + 4 P2 - P3) f^2 + (-P0 + 3 P1 - 3 P2 + P3) f^3)` (2.0,
5.0, 4.0, 3.0, 0.5 at 0xe1b898, 0xd81950, 0xe1b860, 0xe1b808, 0xe1b7d0); the pre-step at +0xc is
cleared (0x4e62dc). Before round 786 `EnvironmentReader` interpolated linearly, which agreed only
at the keys; the spline may overshoot between keys.

**Channel -> world field** (the evaluation order in `FUN_00a1baf0`, `lea ecx,[record+N]` before
each `call 0x4e55e0`, 0xa1bb8a..0xa1bd3a): 0 (+0x88) -> +0x682f, 1 (+0xbc) -> +0x683b, 2 (+0xf0)
-> +0x6847, 3 (+0x124) -> +0x6853, 4 (+0x158) -> +0x685f, 5 (+0x18c) -> +0x686b, 6 (+0x1c0) ->
+0x6883, 9 (+0x2b4) -> +0x68a3, 13 (+0x1f4) -> +0x6877, 14 (+0x228) -> +0x688f; the float graphs
as the table above.

**Easing.** With world +0x2f38 set (the constructor sets `param_1[0xbce] = 1`) and the snap flag
+0x238c clear, every field moves toward its new value by `f = dt x 0.5` (0xe1b7d0), f at most 1
(0xa1c1d5..): `field += (new - field) x f`, about a 2 s time constant. With +0x238c set (the
constructor sets it; it is cleared after one frame) the fields take the new values at once. Then
**every colour field and +0x68c7 is clamped to [0, 1]**.

**The sun.** `SWorld::vslot_004` (0xa2d1cb..0xa2d241) places it at `(cos a, sin a, 0) x 20000`
(0xde4d88), `a = (phase - 0.25) x 2 pi` (0xd83070, 0xd81930; `0xb44a10` is cos -- `fcos` at
0xb44a7d -- and `0xb44b40` sin, `fsin` at 0xb44bad): it rises at +x at 06:00, stands overhead at
noon, sets at -x at 18:00. Night is the shifted phase (phase - 0.25, + 0.75 below 0.25) above
0.5 (0xa2d1ae; the flag goes to 0x1112fb0 +0x1a8).

**The sun disc.** `Map::FUN_00a207a0` (called from the sky step `Map::FUN_00a26f60` at 0xa2727d,
outside a dungeon, `FUN_009fb1f0`) for `0.25 <= phase <= 0.875` (0xd9a2b8, 0xde4d90): a quad of
half-size 666.67 (0xde4d70) facing the eye at the sun's place (the corner table at 0xec554c
turned by the angle), FVF 0x102 (3D), alpha-blended (SRCALPHA / INVSRCALPHA), Z off. **Its colour
is the texture factor = channel 0, SunColor, x 255 (COLOROP SELECTARG1 TFACTOR, 0xa20953..
0xa209fa); its alpha `Sun\lens2.ddj`'s** (ALPHAOP SELECTARG1 TEXTURE; world +0x297f, the second
`sun\lens%d.ddj` of `Map::FUN_00a0d1b0`).

**The moon.** `Map::FUN_00a20d60` (0xa27284, after the disc): drawn while SWorld's day +0x6778 is
below 29 and phase < 0.5 or > 0.75 (0xe1b7e0, 0xdd8eec), at angle `((frac(phase - 0.75) - 0.25) x
1.2 + 0.25) x 2 pi` (0xda34b0, 0xe1b7f0, 0xde4d98), 20000 away, half-size 1000 (0xd83268), the
texture `sun\moon%02d.ddj` of day + 1 (world +0x299b, 30 loaded) in its own colour and alpha.
Then the clouds (`FUN_00a19330` -> `FUN_00a3f570`, 0xa2737c) over both. The day comes from the
clock and is never wrapped (game_clock.md), so retail shows no moon after day 28 of the server's
uptime (INFERRED from the two reads; not watched).

**The flare.** With the Lens Flare row on (world +0x2e84), `Map::FUN_00a21280` (from
SWorld::vslot_005, 0xa2dbb1) draws twelve screen-space elements while the sun is at least 700
above the horizon (0xdd81c4) and projects inside [-1.1, 1.1] (0xde4d80, 0xde4d78): textures
`sun\lens%d.ddj` of 1 + the bytes at 0xec587c (6, 5, 2, 6, 5, 6, 3, 6, 5, 6, 4, 5), sizes the
floats at 0xec58a0 (30, 40, 150, 30, 40, 50, 300, 40, 30, 50, 0, 30); element 2, the sun's glow,
is `Sun\lens3.ddj` at the sun itself, +-300 pixels (2 x 150, XYZRHW), alpha-blended in the
texture's own colour; the rest are added (SRCALPHA / ONE) with alpha 10 / 20 / 19. A visibility
of 0.3 + 4 x 0.175 from five screen tests around the sun, eased at 10 a second, scales them and
hides them below 0.1. LensFlare's header separates what is READ there from what is INFERRED.

**SkyBox\glow.ddj is never drawn.** `Map::FUN_00a0d1b0` loads it into world +0x27db; the image's
only other references are the release (0x9f66b3) and the constructor's zeroing (0xa2f90c).
MEASURED: every texel is (R 252, G 58, B 4) with an alpha falloff -- **the red sun OpenSRO drew
until round 786**, as a sprite tinted by SunColor in the light's direction. `Sun\lens2.ddj` is
white with an alpha disc (255 to radius 36/64, 0 at 56/64); `Sun\lens3.ddj` is a white core
fading to pale yellow (R 250, G 241, B 180 at radius 96/128; alpha-weighted mean 252, 248, 220).

MEASURED, Jangan (environment 15), channel 0: (1, 1, 1) at 0.5012, (0.992, 0.973, 0.757) at the
dawn key 0.2488 and (0.976, 0.988, 0.765) at 0.8811 -- a white disc at noon, yellow at dawn and
dusk; never red.

**Night lights (READ, not drawn here -- OPEN).** The night flag (0x1112fb0 +0x1a8, getter
0xbc0fd0) is read by `CObjRendererVS` (0xbf0fa0, 0xc42aef, 0xc6c7a5: a material with flag 0x8 is
drawn with D3DRS_LIGHTING 0x89 off at night) and `CRTModParticle` (0xc814a1: an emitter with
+0x91 bit 0 runs only at night). The light direction world +0x209a (the sun's place by day, the
opposite at night: phase 0.225..0.775 against the rest, 0xde4f80 / 0xde4f78) goes to 0x1112fb0
+0x17c (0xbbdaa0); its readers were not followed. The objects' and the terrain's own light
direction stays the fixed `normalize(-1, -1, 0)` (DAT_01109510, ObjectLight).

**What OpenSRO draws (round 786).** `DayCycle` (scripts/world/day_cycle.gd) is the record at the
phase, the spline, the easing, the clamps, the sun's and moon's places; World3D samples the
graphs ten times a second and eases every frame (OURS rate split), and writes the sky, the
directional light and the objects' light (channels 2, 3), the terrain (`TerrainLight`: N.L and
the raw lightmap baked per region, channels 2, 5, 6 as global uniforms), the water (14), the fog
(9, 10, 11), the clouds (4, 12), the sun disc and the moon (`sky_body.gdshader`, before the
clouds, which include both in their Forward+ blend) and the flare (`LensFlare`). The record
follows the camera's block. The procedural sky's own sun disc is off (`GammaSkyMaterial.
procedural_sun`).
