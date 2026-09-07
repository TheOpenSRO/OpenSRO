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

## The shader system (recovered 2026-09-07)

**Correction to an earlier note here.** This document previously cautioned that the
`Shader\` tree might be tooling source rather than the runtime path, because no binary
referenced any of its filenames. That was based on searching only for `.psh`/`.vsh` names.
The client *does* load from `Shader\`, just not those: `FUN_00bf67c0` references
**`"shader\vss0.c"`** and **`"shader\vss2.c"`** directly.

`FUN_00bf67c0` is a **runtime shader generator**. It loads one of those `.c` templates,
prepends generated `#define`s, and assembles the result with the statically-linked D3DX9
assembler (its error strings are in the binary). Shaders are cached by a generated id, not
by filename — `m_VShaders.find(dwShaderID) == m_VShaders.end()`. The switches it emits are:

| group | values |
|---|---|
| skinning | `SKIN0`, `SKIN2` |
| lighting | `DIRECT`, `PLIGHT`, `NOLIGHT` |
| texture | `TEXTURE0`, `MULTITEX`, `TEXANI0`, `TEXANI1`, `TEXANI1R` |
| **fog** | **`LINEAR`, `LINEAR+HEIGHT`, `EXP+HEIGHT`** |
| version | `VS_VER_1_1`, `VS_VER_2_SW` |

So the `Shader\*.c` files are real, live shader source. (Whether the `terrain*.psh` files
are loaded the same way is still unconfirmed — they are the only pixel shaders shipped, and
they pair with the terrain vertex shader below.)

## Fog, exactly as the client computes it

From `Shader\vss0.c`, which is one of the two templates the generator actually loads.

**Linear** — plain D3D linear fog in world units:

```
add r0.x, -r5.z, c[VSC_FOG].y     ; (fogEnd - viewZ)
mul r0.x, r0.x, c[VSC_FOG].z      ; * 1/(fogEnd - fogStart)
max/min -> clamp to [0,1]
```

**Exponential** — EXP2, i.e. `1 / exp((viewZ * density)^2)`:

```
mul r0.x, r5.z, c[VSC_FOG].w      ; viewZ * density
mul r0.y, r0.x, r0.x              ; squared
exp r0.z, r0.y
rcp r0.x, r0.z
```

**Height fog** adds a second term from `c[VSC_HEIGHTFOG]` — distance of the vertex's world
Y from a centre Y (`.x`), offset by `.y`, scaled by `.w` and `.z` — and the two are combined
with `min`, so the denser of distance fog and height fog wins.

Constant layout: `VSC_FOG.y` = fog end, `.z` = `1/(end-start)`, `.w` = density.
`VSC_HEIGHTFOG.x` = centre Y.

**This settles a long-standing open question.** Fog near/far are ordinary world-space
distances feeding standard linear fog — there is no `[-1,+1]`-to-distance mapping to
recover. What this project has *not* implemented is height fog, which the real client
combines with distance fog on terrain.

## Terrain vertex shader

`Shader\vertexshader0splatting.c` is the terrain splatting vertex shader:

```
dcl_position v0;
dcl_normal   v3;
dcl_texcoord0 v4;
...
dp3 r1.x, v3, c[VSC_DLIGHT_DIRECTION]     ; N.L
max r1.x, r1.x, 0
mov r6, c[VSC_DLIGHT_AMBIENT]
mad oD0, r1.x, c[VSC_DLIGHT_DIFFUSE], r6  ; vertex colour = N.L * diffuse + ambient
mov oT0.xy, v4.xy
mov oT1.xy, v4.zw
```

Three facts follow, all of which matter for rendering terrain faithfully:

1. **A terrain vertex carries one 4-component texcoord holding *two* UV sets** — `v4.xy`
   feeds texture stage 0 and `v4.zw` feeds stage 1. Pairing that with the terrain pixel
   shaders (`t0` = normal/horizon map, `t1` = terrain colour) means one set is region-wide
   and the other is the tiled ground texture. This project already uses two sets — UV for
   the tile texture and UV2 for the `.t` lightmap — so the structure matches.
2. **Terrain lighting is per-vertex**, a single directional `N·L` into the diffuse colour,
   not per-pixel.
3. Fog on terrain is `min(EXP2 distance fog, height fog)`.
