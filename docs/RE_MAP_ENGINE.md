# Reverse-engineering notes: the client's map/terrain engine

Working notes on `sro_client.exe`'s own map engine, recovered with Ghidra on the RE box.
Everything here is read from the real binary; anything inferred is marked as such.

These exist because terrain fidelity kept stalling on constants that could only be guessed
at from file layout. Two of them are now recovered, and one guess turned out to be the
cause of a real rendering artifact (see [WORLD_ISSUES.md](WORLD_ISSUES.md)'s sixty-ninth
round).

## How to reach it

GhidraMCP's own tool wrapper currently errors on every call, but the plugin's HTTP server
works, so drive it directly from the RE box:

```
curl -s "http://127.0.0.1:8080/strings?filter=<text>&limit=20"
curl -s "http://127.0.0.1:8080/xrefs_to?address=<addr>&limit=30"
curl -s "http://127.0.0.1:8080/decompile_function?address=<addr>"
curl -s "http://127.0.0.1:8080/methods?limit=20"
```

The server only serves a program while a CodeBrowser tool has one **open** — if every
endpoint answers `No context found for request`, the plugin has lost its program and
Ghidra needs restarting and `sro_client.exe` reopening (a double-click; single clicks
only select).

Two traps worth knowing:

- **Format magics are compared as integers, never stored as text.** No binary contains
  the string `JMXVMAPM`; the loader does `local_137c = (int *)0x56584d4a`, which is
  `"JMXV"` little-endian. String-searching for a magic will always fail.
- **Float constants in `.rdata` are often doubles.** A 4-byte read shows `00000000`
  because the low dword is zero. Always read 8 bytes:
  `objdump -s --start-address=0xADDR --stop-address=$((0xADDR+8)) sro_client.exe`.

## The module

Source paths survive in assert strings (`FUN_0049e490(line, file, expression)`), which is
what identifies these functions:

| source file | notes |
|---|---|
| `Silkroad\Client\Landscape\MapEngine\Map.cpp` | the map engine proper; asserts seen up to line 6258 |
| `Silkroad\Client\Landscape\MapEngine\BufRender.cpp` | vertex/index buffer wrapper (`m_blRendering`, `m_blOldRendring`) |
| `Silkroad\Client\Landscape\MapEngine\MapCallBack.cpp` | — |
| `Silkroad\Client\Landscape\MapEngine\DynamicShadow.cpp` | — |
| `JMX_Library\navmesh\MapLoader.cpp` | `CMapLoader`, loads `tile2d.ifo` / `mapinfo.mfo` |

Known functions:

| address | what it is |
|---|---|
| `FUN_00a361b0` | **region loader** — builds `"%d\%d.m"` / `"%d\%d.o2"`, checks the `JMXV` magic, places the region |
| `FUN_00a291a0` | asset loader — reads `environment.ifo` (same `JMXV` magic, then a `uint16` count) |
| `FUN_00a27880` | tile-texture loader (`tile2d\` + filename into a texture array) **and** grass scatter (`rand() % 100` against `tile2d.ifo`'s trailing `{a,b}` field) |
| `FUN_00a232a0` | releases tile textures; asserts from `Map.cpp` |
| `FUN_00a1b390` | map engine teardown — names its members: `m_BlockCache`, `m_RegionCache`, `m_Dungeon`, `m_Object` |
| `FUN_00427cc0` | `CMapLoader` — loads `navmesh\tile2d.ifo` |
| `DAT_01108268` | tile texture array, indexed by tile ID |

## Recovered constants

**Region size.** `FUN_00a361b0` places a region at
`regionByte * _DAT_00e1b908 * _DAT_00d99a68`:

| address | bytes | value |
|---|---|---|
| `00e1b908` | `00 00 00 00 00 00 74 40` | **320.0** |
| `00d99a68` | `00 00 00 00 00 00 18 40` | **6.0** |

A region is `320 × 6` = **1920** units, expressed by the client as **6 blocks of 320**,
so each block's 16 tiles are **20 units**. This confirms `World3D.REGION_SPAN = 1920.0`
and `MapmTerrainBuilder.TILE_SIZE = 20.0` from client code, where before they rested on
mesh footprints and heightmap edges matching.

**Tile ID packing.** `FUN_00a232a0` masks a `.m` vertex's `TextureInfo` with `& 0x3ff`,
confirming the tile ID is the **low 10 bits** — this project's existing reading. (A
different site, `FUN_00a27880`, derives an ID as `(raw >> 6) & 0x3ff`, but that operates
on a different structure; tested against real data, the low-10-bit reading is the one
that yields thematically correct textures.)

Other constants seen while reading: `_DAT_00e1b7d0` = `0.5`, `_DAT_00e1b8d8` = `0.0174532925`
(π/180).

## Still open

- **How a terrain vertex's texture coordinates are filled.** The real terrain vertex
  shader takes them straight from the vertex buffer (`mov oT0.xy, v1` in
  `Shader\scattervsdetail10.vsh`; the world-position projection alternative,
  `mad oT0.xy, VPOSITION.xz, c[CV_BASE_TEX_PROJECTION]…`, is commented out). So the
  repeat rate is client code. Not yet located — `Map.cpp`'s block/vertex construction is
  the place to look, reachable from `m_BlockCache`.
- **The `.m` per-vertex `Scale` field's real meaning.** Currently unused, after this
  project's own `2 ^ (scale >> 3)` reading was found to cause a visible lattice.
- **Fog / scattering.** `environment.ifo` is loaded by `FUN_00a291a0` into a list, but
  the code that turns its `FogNearPlane`/`FogFarPlane` into real distances, and that sets
  the Rayleigh/Mie coefficients, is elsewhere.

## A caution about the shader source

`Data.pk2`'s `Shader\` folder holds readable `.psh`/`.vsh` source and is genuinely useful
for structure. But **no shipped binary references any of those filenames**, and the
archive also ships a `shader_maptool\` duplicate of the same files, so it may be tooling
source rather than what the shipped client loads. Treat it as evidence about the intended
design, not proof of the runtime path.

## Terrain appearance: what the real client composes, and what we do not

The real terrain pixel shader (`Shader\terrainps14.psh`, and `terrainpsn10.psh`) states the
whole equation in its own comment:

```
Surf_color  = (N.L) * terrain_tex * cloud_covering * self_shadow_term
Final_color = Surf_color * extinction + inscattering
```

with three sampled textures: `TEX_NORMAL_HORIZON_MAP` (RGB unpacked `_bx2`, i.e. a normal
map; its **alpha** carries a horizon angle used as the self-shadow term),
`TEX_TERRAIN_COLOR`, and `TEX_CLOUD_LAYER`.

Against that, this project currently composes: the tile texture, Godot's own lighting from
mesh normals, the `.t` lightmap as ambient occlusion, and Godot fog. So four things in the
real equation have no equivalent here:

1. a **normal + horizon map** — the real client lights terrain per *texel* and gets
   self-shadowing from a stored horizon angle, not from mesh normals;
2. a **cloud shadow layer** multiplied over the surface;
3. **extinction / inscattering** — real aerial perspective, computed per vertex in
   `scattervs10.vsh` from Rayleigh/Mie coefficients, rather than a distance fog;
4. the `.t` texture is used here as ambient occlusion, which is *not* the role the real
   equation gives any of its three textures.

`.t` cannot be the normal/horizon map: it is DXT1 (no alpha, so no horizon term) and
measures a mean saturation of 0.014, i.e. genuinely greyscale. Where the real normal/horizon
map comes from is not yet known — most likely generated at load from the heightmap.

This is the most likely remaining reason real ground does not look like the real game, now
that tile identity, tiling rate and UV layout are all confirmed correct.

## A correction about the UV change

The 2026-09-06 "continuous UVs" change is worth stating precisely, because it was described
at the time as fixing the ground squares and it was not.

Old UVs ran `(0,0)…(1,1)` within each quad; new ones run `(c,r)…(c+1,r+1)` across the
region. **With REPEAT wrapping these sample identically** — `frac(c … c+1) = 0 … 1`. The
change therefore removed only the hash-driven per-quad rotation/mirror, which was an
invented technique, and altered nothing else about how a texture lands on the ground.

The artifact actually reported was caused by the `Scale` field reading (sixty-ninth round),
which multiplied the repeat rate by four in the regions that carry `scale = 16`.
