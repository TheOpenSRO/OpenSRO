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
7  FogNearPlane          (2-float FloatGraph: value + time)
8  FogFarPlane           (2-float FloatGraph)
9  FogColor              (4-float ColorGraph)
10 (unnamed -- "Graph10")
11 (unnamed -- "Graph11")
12 (unnamed -- "Graph12", added v1001)
13 SkyBottomColor        (4-float ColorGraph, added v1002)
14 WaterColor            (4-float ColorGraph, added v1002)
15 (unnamed -- "Graph15", added v1002)
```

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
