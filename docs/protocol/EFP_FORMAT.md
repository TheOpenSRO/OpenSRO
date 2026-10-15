# EFP particle effect format (JMXVEFF)

`.efp` is the particle-effect format of `Particles.pk2` (4,170 files in the retail archive). It is
a self-describing tree: nodes (emitters) that carry named **controllers**, typed **commands** and a
fixed body, nested to any depth.

**Status (round 619).** The layout below was read from the client's own loader in
`sro_client.exe`. Two readers implement it: `server/internal/efp` (`Decode`, Go) and
`client/scripts/efp/efp_reader.gd` (`EfpReader.decode`). The two produce identical counts over
the retail archive:
- 4,103 of 4,170 files decode (98.4 %);
- 4,096 of those consume every byte;
- 95,801 nodes.

Every layout claim here is **READ**, from the function named with it, unless it is labelled
otherwise:
- **MEASURED**: counted over the retail archive with the census (see "Census" below).
- **INFERRED**: a conclusion from READ or MEASURED facts, with the reasoning given.
- **OPEN**: not established.

Addresses are virtual addresses in `sro_client.exe` (dump `/var/tmp/decomp_client` on the RE
box). No game data is stored in this repo; the tests use synthetic buffers.

## Primitives

- Integers and floats are little-endian; `f32` is IEEE single.
- **String**: `u32 length` + that many bytes, with no terminator and any byte values
  (`Map::FUN_00a09210`). Retail names include `11111`, `-…`, names with spaces, and EUC-KR
  Korean (the root of `system\system_levelup.efp` and its three copies). The readers consume the
  whole length but cut the value at the first NUL, as the client's `c_str()` users see it, and
  keep each byte above 0x7f as the code point of the same value (Latin-1), so Go and GDScript
  produce identical strings; EUC-KR is not decoded (OURS).
- **Vec3**: 3 × f32.
- **Mat4**: 16 × f32, 64 bytes, as stored. INFERRED: row-major in D3D's row-vector convention.
  The readers do not transpose.

## File

`FUN_00cb8d70` loads a file. `FUN_00cb9120` is the editor's save path, which writes version `0013`.

| field | bytes | notes |
|---|---|---|
| magic | 12 | `"JMXVEFF "` + a 4-character version. The client checks bytes 4-7 = `"EFF "`, then compares the version **as a big-endian number**. The readers check all 8 bytes `"JMXVEFF "` (OURS, stricter) |
| header f32 | 4 | present when version ≥ `"0012"`; stored at client +0x264. Meaning OPEN (MEASURED 0.4 … 1.0) |
| header u32 × 3 | 12 | present when version ≥ `"0013"`; stored at +0x268, +0x26c, +0x270. Meaning OPEN |
| root node | … | see Node |
| (trailing) | … | never read. 6 retail files are zero-padded to a 4 KiB multiple, and `water_resurrection_effect_d.efp` has 3,923 non-zero bytes after its root (MEASURED) |

What each version adds before the root node:

| version | extra bytes | files (MEASURED) |
|---|---|---|
| `0010` | 0 | 1 |
| `0011` | 0 | 2,091 |
| `0012` | 4 | 621 |
| `0013` | 16 | 1,390 |

This corrects two earlier readings.
- The "unconfirmed u32" that the old notes placed before the effect name in `0011`/`0013` is the
  root node's **HeadLen** (see Node).
- The `0013` "f32 + 12 reserved + u32" is the header f32, the three header u32s, and then the root
  node's HeadLen.

Files that do not decode (MEASURED):
- **58 `F8FILE` containers**, all `system\arksolid_*`. They do not begin with `JMXVEFF`; the bytes
  after `F8FILE\x01\x00` look encrypted or compressed. OPEN.
- **7 files with version `0000`**, all `skill\china\*ganggi*` plus `etc_mirage_sword_normal`.
  - The client would read them as `0011`. They are not in the node format: a run of small bytes
    precedes the name, and the first u32 read as a string length is 5,385 or more.
  - No `skilleffect.txt` row names any of them.
  - The readers reject them. What wrote them is OPEN.
- **2 empty files**: `cos\pet_gryphon_eyes.efp.efp` and `dun\petra_flame_yellow_glow.efp`.

## Node (`FUN_00cc3a40`)

| field | notes |
|---|---|
| u32 HeadLen | the byte length of the node's name (with its length prefix) and its whole controller block: everything up to the body. MEASURED: equal in 95,801 of 95,801 retail nodes (the census checks it). The loader's cache mode (`DAT_01119eac == 0`) seeks past that span instead of reading it; files are read in the normal mode. Round 619 first misread it as a node id; the field is now `Node.HeadLen` / `EfpNode.head_len` |
| string name | the node's name: `counterattack`, `NONAME`, `EFFECT`, author labels |
| u32 controller count | the client shows an error box above 1000 |
| controllers | each is a string key followed by that controller's data (`FUN_00cc2f30` → the controller's vtable slot 3). See Controllers |
| body | `FUN_00cc3500` (vtable slot 7 of `CEFStoredEffect`). See Body |
| u32 child count | |
| children | nodes, recursively |

### Body (`FUN_00cc3500`, save twin `FUN_00cc2510`)

In file order:

| # | field | reader | what it holds (MEASURED over all 95,801 nodes) |
|---|---|---|---|
| 1 | program | `CEEProgram::FUN_00ca85f0` | `u32 N` (the program length in **frames**; the client's program +4), `u32 count`, then per variable: a string naming a value type, and that type's value. Only `BlendScaleGraph`, `BlendDiffuseGraph` and `BSAnimation` occur |
| 2 | command list | `FUN_00ca7280` | always empty |
| 3 | command list | `FUN_00ca7280` | `StaticEmit` (the emitter) |
| 4 | command list | `FUN_00ca7280` | always empty |
| 5 | one command | `FUN_00ca57e0` | `NormalTimeExtinct` (95,139 nodes), `NormalTimeLoop` (263) or `NeverExtinct` (190) |
| 6 | command list | `FUN_00ca7280` | `ProgramUpdate` |
| 7 | 20-byte block | inline | u8, u8, u32, u32, u32, u8, u32, u8, stored at node +0x154..+0x16c (READ, `FUN_00cc3500`): b0 keep old rotation, b1 keep old position, u2/u3/u4 orbit/rotation/velocity follow levels, b5 apply rotation velocity, u6 translation follow level, b7 apply shape velocity. See "Follow levels" |
| 8 | one command | `FUN_00ca57e0` | the **view mode**: `ViewNone`, `ViewBillboard`, `ViewYBillboard` or `ViewVBillboard` |
| 9 | render block | `FUN_00cc3400` | a 36-byte RenderState, then `u32 n` and n × (string mesh, `u32 m`, m × string texture) (`FUN_00cc32b0`). The mesh is `""` for a plate. The loader rewrites cull 2 to 3 |
| 10 | one command | `FUN_00ca57e0` | the **render mode**: `RenderNone`, `RenderPlate`, `RenderMesh`, `RenderLinkPipe`, `RenderLinkDPipe` or `RenderLinkObj` |
| 11 | command list | `FUN_00ca7280` | always empty |
| 12 | command list | `FUN_00ca7280` | the **per-particle program**: every `Set*`, `Force`, `Attraction`, `TextureSlide` and graph command. It is the compiled copy of the Program controller's list, with the same counts, command for command |

## Controllers

Controllers are the editor's source blocks. The registry is `CGame::FUN_00ca0500` → `FUN_00ca0180`,
which pairs each key with its class. A controller's vtable slot 6 compiles it into the body; for
example, `CEFCNormalTimeLife::vslot_006` emits the `NormalTimeExtinct` command, and
`CEFCStaticEmit::vslot_006` copies its 20 bytes into the body's StaticEmit parameter. **A renderer
reads the body, not the controllers.**

| key | class, reader (vtable slot 3) | data |
|---|---|---|
| `NormalTimeLife` | CEFCNormalTimeLife, `0x00cb9d80` | none (the reader is `ret 4`) |
| `NormalTimeLoopLife` | CEFCNormalTimeLoopLife, `0x00cb9d80` | none |
| `StaticEmit` | CEFCStaticEmit, `0x00cbb0b0` | 20 bytes (SEFStaticEmit) |
| `Program` | CEFCProgram, `0x00cb9560` | command list |
| `LinkMode` | CEFCLinkMode, `0x00cbb0f0` | 4 × u32; meaning OPEN |
| `BAN` | CEFCBAN, `0x00cc0b70` | `u32 n` + n strings. The key is spelled `BAN` in files (`DAT_00e0f45c`) |
| `ViewMode` | CEFCViewMode, `0x00cbe290` | one string |
| `Shape` | CEFCShape, `0x00cc1760` | string render name, 36-byte RenderState, then the mesh list as in body item 9 |
| `ScaleGraph` | CEFCScaleGraph, `0x00cc00b0` | 3 × graph (`FUN_00cbf880`: f32 a, f32 b, `u32 n`, n × (f32 time, f32 value)), then u32, f32. INFERRED: one graph per axis |
| `DiffuseGraph` | CEFCDiffuseGraph, `0x00cc0140` | a graph (`FUN_00cbf970`: f32 a, f32 b, `u32 n`, n × (f32 time, u8 value)), then a BlendDiffuseGraph. INFERRED: alpha, then colour |

Graph times, and a and b, are floats in [0, 1] and ascending (MEASURED: 245,108 of 245,571 scale
graphs have a and b in range). INFERRED: normalised life.

## Command (`FUN_00ca5460`)

| field | notes |
|---|---|
| u8 present | 0 = an empty slot: nothing more follows |
| string name | looked up in the command registry (`FUN_00ca4180`) |
| u8 space | command +0x1c. MEASURED 0-7: SetPosition 7, SetRotation 2, SetSpherePos 1, … INFERRED: a coordinate-space or link selector. OPEN |
| u8 time flags | command +8, see Timing |
| f32 start, f32 step, f32 end | command +0xc, +0x10, +0x14 |
| parameter | present only when the registry gives the command a type: that type's value (vtable slot 5 of the parameter object) |

For a command with no parameter, the retail editor left the five header fields uninitialised.
MEASURED: stack garbage such as `0x0012eba8` and `0xcdcdcdcd`.

An unknown command name makes the client skip the parameter, which would desynchronise the rest of
the file. Both readers fail instead, and no retail file contains one.

### Timing (`FUN_00ca0f40`)

The command's frame range is computed over the owning program's N frames.
- The float-to-int conversions are the client's `_ftol` (`FUN_00b42d10`): truncation, and the
  x87 "integer indefinite" `0x80000000` for NaN or anything outside int32. Products and sums are
  32-bit. This matters because the header floats of commands without a parameter are
  uninitialised stack bytes.
- The float arithmetic is single precision. INFERRED: Direct3D 9 puts the x87 in single-precision
  mode unless the device is created with FPU_PRESERVE. The counts below confirm it. Round 619's
  first reader used double precision and read end mode 3 with +100, and its key counts disagreed
  with the stored values in 25 of 129,438 commands. With single precision and −100, only 2 do, and those 2 are the data's own (see below).

The rules:
- **Start.** Flag bit 0 clear: `start = ftol(Start)`. Bit 0 set: `start = ftol(Start/100) × N`.
- **Step.** Flag bit 1 clear: `step = Step`. Bit 1 set: `step = N × Step / 100`.
- **End**, chosen by `(flags >> 2) % 5`:
  - 0: `ftol(End)`;
  - 1: `ftol(End/100) × N`;
  - 2: `start + ftol(End)`;
  - 3: `start − ftol(End/−100) × N`, which is `start + int(End/100) × N`. The divisor is the
    double **−100.0** at `0x00db9a38` (READ). Retail uses this mode (MEASURED): the Force commands
    of 9 `skill_cast_foot_*.efp`, 12 SetShapeRot in `dun\bagh_masin_bronze_light.efp`, and 1,803
    StaticEmit command headers;
  - 4: `start + ftol(End × step)`. The command is skipped when End < 1 (a NaN End is not skipped:
    the x87 compare is unordered).
- **Checks.** End is clamped to N − 1. The command runs only when `end ≤ N`, `start ≤ end` and
  `step ≥ 1e-6`.
- **Keys.** The function returns `ftol((end − start)/step) + 1`, the number of keys in the range.
  A negative (overflowed) count is reported as 0 by the readers (OURS).

MEASURED:
- SetGraphScale and SetGraphDiffuse use flags 4 or 5 with Step 1 and End 100, which is every
  frame of the life.
- A Frame* parameter (FrameScale, FrameDiffuse, FrameTextureSlide, FrameBANPosition,
  FrameBANRotation) holds **exactly Keys values in 132,666 of 132,668 retail per-particle commands**.
  The two exceptions are the TextureSlide commands of `map\euro_constan_center.efp`: End 63 % of
  40 frames gives 1 key, but 26 values are stored. INFERRED: stale values the editor kept
  after End changed. The census gate allows those 2 and fails on any more.
- So these are **baked per-key values**: value i belongs to frame `start + i × step`.
- This measurement is also the check that the timing rules above were read correctly. In the
  readers, `Command.Keys(n)` (Go) and `frame_range(n)["keys"]` (GDScript) give the count.

**A frame is 50 ms** (READ, round 620). See "Playback" below.

### Command registry

The registry is `CGame::FUN_00ca0500` → `FUN_00ca8140`: 37 commands, each with its parameter type.

| command | parameter | | command | parameter |
|---|---|---|---|---|
| NeverExtinct | — | | SetSpherePos | Vector |
| NormalTimeExtinct | — | | SetVelocity | Vector |
| NormalTimeLoop | — | | SetConeVel | AngleVector1 |
| StaticEmit | SEFStaticEmit | | Force | Vector |
| ProgramUpdate | — | | ConeForce | AngleVector1 |
| SetRotationMat | Matrix | | Attraction | float |
| SetRVelocityMat | Matrix | | TextureSlide | FrameTextureSlide |
| SetRotation | RotVector | | SetGraphScale | FrameScale |
| SetBANRot | FrameBANRotation | | SetGraphRandomScale | BlendScaleGraphPointer |
| SetRVelocity | RotVector | | SetGraphDiffuse | FrameDiffuse |
| SetRotationAxis | AxisVector4 | | SetShapeRot | AxisVector4 |
| SetRVelocityAxis | AxisVector4 | | SetShapeRotVel | AxisVector4 |
| SetPosition | Vector | | View{None,Billboard,YBillboard,VBillboard} | — |
| SetConePos | AngleVector1 | | Render{None,Plate,Mesh,LinkDPipe,LinkPipe,LinkObj} | — |
| SetBANPos | FrameBANPosition | | | |

## The 16 value types

The registry pairs each type name with a factory (`FUN_00ca8080`). Each factory sets a vtable
whose **slot 5 (+0x14)** reads the value and whose slot 4 writes it. The class names come from the
binary's own RTTI.

| type | factory | vtable | reader | layout | bytes |
|---|---|---|---|---|---|
| float | `0x00c91f30` | `0xe0ed3c` | `0x00c92350` | f32 | 4 |
| Vector | `0x00c91f50` | `0xe0ed58` | `0x00c90960` | Vec3 | 12 |
| Matrix | `0x00c93090` | `0xe0ee98` | `0x00c923b0` | Mat4 | 64 |
| SEFStaticEmit | `0x00c90800` | `0xe0ecb0` | `0x00c923d0` | u32 delay, u32 duration, u32 interval, u32 max live, f32 per trigger (see Emission) | 20 |
| AxisVector4 | `0x00c930d0` | `0xe0eeb4` | `0x00c92510` | 4 × f32, then Mat4. INFERRED: axis and angle, plus the matrix baked from them | 80 |
| RotVector | `0x00c93120` | `0xe0eed0` | `0x00c92650` | Vec3, then Mat4 | 76 |
| AngleVector1 | `0x00c920f0` | `0xe0ed74` | `0x00c90ab0` | Vec3 a, Vec3 b; which is the axis is OPEN | 24 |
| FrameScale | `0x00c9bbf0` | `0xe0f000` | `0x00c9ad90` → `FUN_00c9aba0` | `u32 n` + n × Vec3 (one per frame) | 4+12n |
| BlendScaleGraph | `0x00c9f9c0` | `0xe0f0b8` | `0x00c9f540` → `FUN_00c9f420` | f32 a, f32 b, `u32 n`, n × (f32 time, Vec3) | 12+16n |
| BlendScaleGraphPointer | `0x00c90890` | `0xe0ece4` | `0x00c926a0` | u32. INFERRED: an index into a scale graph. OPEN | 4 |
| FrameDiffuse | `0x00c9bc60` | `0xe0f01c` | `0x00c9b050` → `FUN_00c9af90` | `u32 n` + n × u32 colour (one per frame). INFERRED: D3DCOLOR `0xAARRGGBB` | 4+4n |
| BlendDiffuseGraph | `0x00c9f560` | `0xe0f094` | `0x00c9e3a0` → `FUN_00c9e2b0` | f32 a, f32 b, `u32 n`, n × (f32 time, u32 colour) | 12+8n |
| FrameBANRotation | `0x00c9d180` | `0xe0f054` | `0x00c9d330` → `FUN_00c9c380` | f32 head (loaded with fld/fstp; mostly 0, non-zero in 174 retail commands, e.g. 0.3; meaning OPEN), `u32 n`, n × Mat4 | 8+64n |
| FrameBANPosition | `0x00c9bf60` | `0xe0f038` | `0x00c9b140` → `FUN_00c9aba0` | f32 head (non-zero in 20 retail commands), `u32 n`, n × Vec3 | 8+12n |
| BSAnimation | `0x00c9bcd0` | `0xe0efe4` | `0x00c9c230` → `FUN_00c9b5f0` | `u32 n` + n strings. `FUN_00c9a580` loads each `.ban` by name (`FUN_00cb8810`) | 4+… |
| FrameTextureSlide | `0x00c9d1f0` | `0xe0f070` | `0x00c9d3a0` → `FUN_00c9c610` | Vec3 head, `u32 n`, n × 4 f32 | 16+16n |

FrameTextureSlide's head is three floats. MEASURED, the most common (occurrences, counting
controller copies too): (3, 2, 1) 5,378; (3, 2, 2) 2,646; (3, 3, 0.25) 990; (3, 3, 0.5) 476;
(8, 8, 0.9) 346. INFERRED: an atlas grid (columns, rows) and a rate, with one 4-float rectangle
per key. OPEN: the command's runtime object (vtable `0xe0ef7c`) only stores the value at a
particle offset, and the code that reads it there was not traced.

Graph keys (BlendScaleGraph, BlendDiffuseGraph and the two controller graphs) are inserted with
`map[time] = value` (READ: `FUN_00c9f420`, `FUN_00c9e2b0`, `FUN_00cbf880`, `FUN_00cbf970`). So
the client holds them sorted by time, and a repeated time keeps the value read last. The readers
do the same.

## Emission (`SEFStaticEmit`, READ from `FUN_00c84e70`, and `FUN_00c87a20` for deaths)

The 20 bytes are delay, duration, interval, max_live and per_trigger. Each emitter keeps a float
accumulator at emitter +0x60, which starts at 0. The client runs this each frame, with
`t = age − delay` (age at emitter +0x28 → +0x54):
1. When `t ≥ duration`, the emitter's done flag (+0x10) is set through `CEFGroup::vslot_003(1)` and
   the emitter does nothing this frame; otherwise the flag is cleared (`vslot_003(0)`,
   `0x00c84e9c` / `0x00c84ea5`). The flag is recomputed every frame, not latched: when the owner's
   age goes back below `delay + duration` (a NormalTimeLoop owner wrapping, or a kept effect's
   revived root particle, see "Ending a kept effect"), the emitter emits again, its accumulator
   as it was (round 623).
2. It skips the frame unless `interval > 0` and `t ≥ 0`.
3. If the global `DAT_01114d54 > 1`, the interval is multiplied by it, unless the product reaches
   `duration`.
4. It skips the frame unless `t % interval == 0`.
5. `cap = max_live`. If the global `DAT_01114d58 > 0` and is below `per_trigger`, the cap is
   halved (the float 0.5 at `0xe1b7e0`), with a floor of 1.
6. `acc = min(acc + per_trigger, cap)`, and `ftol(acc_new) − ftol(acc_old)` particles spawn. The
   fractions carry to the next trigger.
7. Each particle that dies subtracts 1.0 from the accumulator (`FUN_00c87a20`, the double 1.0
   at `0xe1b7f0`).

So **max_live caps the live particle count**, and **per_trigger is how many particles a trigger
adds**, fractions included.

The two globals are set together by one routine (`0x005474b1`–`0x005474fc`) from an option string
read with `atoi`:
- option 0 gives (0, 0);
- option 1 gives `DAT_01114d54 = 2`, `DAT_01114d58 = 10`;
- anything else gives 5 and 10.

Both globals are in `.bss`, so they start at 0, which is full quality. The readers default to that
(`DefaultEmitGlobals`; `emit_tick`'s default arguments); which option this is, and its retail
default, are OPEN. Go's `StaticEmit.Tick` and GDScript's `EfpReader.emit_tick` run step by step
exactly this.

MEASURED, the most common emitters:
- (0, 1, 1, 1, 1.0) in 47,594 nodes: one particle at once;
- (0, 30, 3, 10, 1.0): a particle every 3 frames for 30 frames, at most 10 alive.

## Render state and blending (READ, `EFEffect::FUN_00cabda0`)

The client draws each node with Direct3D 9 states taken verbatim from the node's 36-byte
RenderState:

| u32 | state |
|---|---|
| 0 | D3DRS_CULLMODE (0x16). The loader rewrites 2 to 3 |
| 1 | D3DRS_SRCBLEND (0x13) |
| 2 | D3DRS_DESTBLEND (0x14) |
| 3 | D3DTSS_COLORARG1, stage 0 |
| 4 | D3DTSS_COLORARG2 |
| 5 | D3DTSS_COLOROP |
| 6 | D3DTSS_ALPHAARG1 |
| 7 | D3DTSS_ALPHAARG2 |
| 8 | D3DTSS_ALPHAOP |

Before drawing, the same function sets:
- ZWRITEENABLE 0;
- ALPHABLENDENABLE 1;
- SPECULARENABLE 0;
- LIGHTING 0;
- FOGENABLE 0.

It then switches on a render-type value 1-5 at def +0x208 to pick the draw routine. Which mode
each value is was read in round 620 (see "Playback"): 1 Plate `FUN_00c8c210`, 2 Mesh
`FUN_00c8bf50`, 3 LinkDPipe `FUN_00c8de80`, 4 LinkPipe `FUN_00c8e020`, 5 LinkObj `FUN_00c8c3a0`.

**Blending is per node, in this block.** This settles the spec's OPEN question: it is not carried
by the texture name. MEASURED, files using each state among rendered nodes:
- src SRCALPHA (5) / dest ONE (2), **additive**: 3,879 files;
- src SRCALPHA / dest INVSRCALPHA (6), **alpha**: 2,007 files;
- other pairs: 30 files. They include ZERO/INVSRCALPHA (9 files), BOTHSRCALPHA (12) with
  INVSRCALPHA or ONE (6 and 5), and INVSRCCOLOR/SRCCOLOR (4). A renderer that handles only
  additive and alpha blending draws 99 % of files with the right blend.

Colour op MODULATE (4) is the most common, then MODULATE2X (5) and MODULATE4X (6). The arguments
are TEXTURE (2) and DIFFUSE (0).

### Where an effect draws in the frame (READ, round 786)

Every effect is drawn right after the meshes of the body that owns it, depth-tested, writing no
depth:
- **A placed object's effects** draw inside its own batch, `CObjRendererVS::vslot_038` (0xbf5830):
  - first every mesh piece, the MTRL-blended ones in place, with no sort;
  - then the mod manager's effects (0xbf5d5c..0xbf5d66 → `FUN_00c44ff0` → `FUN_00c7b3f0` → each
    mod's slot 3, `CRTModParticle::vslot_003` 0xc76be0 → `FUN_00c81450` → the effect's draw);
  - then the body's leftover one-shots (`FUN_00c2a700`, 0xbf5d71);
  - then the equipment effects (`FUN_00c2bc80`, 0xbf5d7c), the +8 and seal particles a
    `CRTModParticle` keeps in the compound's +0x1a4 map (`CCompChar::FUN_00c30c20`).
- **A character's skill and buff decorations** draw right after its body
  (`GlobalDataManager::FUN_009d20d0`): `FUN_009c4aa0` draws and flushes the body, then each
  decoration's slot 15 (`CIDecoSkill::vslot_015` 0xa4fd30, `CIDecoDamageEffect::vslot_015`
  0xa496e0).
- **The frame** (`Map::FUN_00a24e30`) draws, in order:
  1. the terrain;
  2. the below-water characters and objects;
  3. the map water (`FUN_00a220b0`);
  4. the above-water placed objects, in the sector queue's order (`Map::FUN_00a185f0`; the queue
     is built by `Map::FUN_00a1e530`, which only queues);
  5. the above-water characters.

  The water plane is world+0x26c4 (`Map::FUN_00a2b370`).
- **The depth state.** The effect draw (`EFEffect::FUN_00cabda0`) sets ZWRITEENABLE 0 and does not
  touch ZENABLE; ZFUNC is LESSEQUAL (`SWorld::vslot_023` 0x9f4bb0).
  - An MTRL mod with zwrite off writes no depth either, so a particle inside or behind a waterfall
    sheet or a fountain's stream draws after it, on top of it.
  - The plain map water does write depth: its one ZWRITE write (0xa22c39) follows its draws. So a
    particle under the water plane fails the test.
  - The reflecting water's path (`FUN_00a2df70`) has a `(0xe, 0)`; whether it covers the final
    quad is OPEN.
- **The glow entries** (an ambient entry's +0x50) are the exception: they are queued and drawn
  later, with ZENABLE off (`FUN_00c43100`).

**This client (`EfpEffect.RENDER_PRIORITY`).**
- Every effect material draws at render priority 1: after every object surface (priority 0), the
  water (-3) and the fog pass (-1), and in depth order among the effects. Before this fix (round
  786) effects drew at 0, and Godot's transparent sort by distance mixed them with the objects'
  blended meshes: a sheet or a stream whose centre was nearer the camera than an effect's drew
  over it (INFERRED from the sort; the MEASURED A/B at the round's three sites moved the boxes'
  means by at most 0.2, so it was not what dimmed them -- the display twins were, below).
- OURS:
  - A placed object's effects draw after every object's blended meshes. The original orders
    them before a later-queued object's.
  - Above-water characters' blended meshes draw before the world's effects here.
  - The water writes no depth here, so a particle under the water plane still shows, as it did
    before; OPEN.
- `OPENSRO_QA_FX_PRIORITY=<n>` draws every effect at n, for an A/B (0 is the old order).

### Display-value blending under Forward+ (round 786: `EfpDisplayPass`)

Direct3D 9 blends in the values the screen shows: there is no SRGBWRITE (round 705), and the back
buffer is 8-bit. Compatibility does the same. Forward+ blends in a linear float buffer, so the
placed objects' `ambient` effects get their own pass.

**Why: the twins' screen copy.**
- Rounds 722 and 774 drew each effect node as a display twin that read Godot's screen copy. That
  copy is taken **before the transparent pass** ("Screen-reading shaders"), so it holds the opaque
  scene and not the water or a blended sheet under the particles.
- MEASURED: the effects' share of a box's mean display value, frames 60 to 99:

  | site | twins | Compatibility |
  |---|---|---|
  | Hotan palace waterfall | +0.25 | +2.3 |
  | Jangan dragon | +1.4 | +2.7 |

**The pass: `EfpDisplayPass`**, a CompositorEffect at `EFFECT_CALLBACK_TYPE_POST_TRANSPARENT` on
the world camera:
1. A compute pass turns the colour under the effects' screen rectangle into display values (Godot's
   tone map forward, then sRGB) in an 8-bit buffer, and clears a mask.
2. Every registered plate and mesh node is drawn into that buffer, back to front by its cull box's
   centre:
   - with its RenderState's SRCBLEND/DESTBLEND as the blend factors (`d3d_pair`), including
     BOTHSRCALPHA and BOTHINVSRCALPHA;
   - with its stage ops on display values (`DRAW_FRAGMENT`, as `SHADER_TEMPLATE`);
   - instanced from the MultiMesh's own GPU buffer (`multimesh_get_buffer_rd_rid`);
   - depth-tested in the fragment shader against the scene's depth (Godot's depth is reversed),
     with no depth write; a glow draw has no depth test.
3. A compute pass turns the marked pixels back to linear.

- **Registration:** `EfpEffect.use_display_blend` hands a node to the pass and sets its `layers` to
  0, so Godot does not draw it as well. `EfpEffect.pass_items` builds the frame's draw list on the
  main thread at `frame_pre_draw`, and `call_on_render_thread` hands it over in the
  RenderingServer's command order.
- **Rebuilds:** the list is rebuilt only when an effect redrew, faded, came or went, or the camera
  moved (`_signature`). Otherwise the render thread reuses its resolved draws. The shaders compile
  on the first frame with something to draw.
- **Link nodes** keep their twins.
- **SceneData:** the projection and view come from Godot's SceneData UBO. MEASURED by reading it
  back: the projection, its inverse, then the inverse view and the view as 3x4 rows.

**MTRL passes.** An object's mixing or adding MTRL pass with no depth write (a waterfall's sheet, a
fountain's stream) blended linearly too: the Hotan sheet's box mean was 167, against 126 under
Compatibility, while the rock beside it was 50 against 52. It now blends in display values through
a screen-read tail (`ObjectLoader.display_blend`, `wants_display_blend`), with the fog folded into
the source first. The screen copy holds the opaque scene, which is exact for a single sheet over
rock.

**MEASURED, round 786** (`/var/tmp/sparkle/c1`, `lum.py`): the effects' share against each side's
own effects-off run.

| site | before (twins) | after (pass) | Compatibility | after, linear tone map | Compatibility, linear tone map |
|---|---|---|---|---|---|
| Hotan palace waterfall | +0.25 | +2.3 / +2.7 | +2.3 | +2.3 | +1.7 |
| Jangan dragon | +1.4 | +2.5 / +2.4 | +2.7 | | |
| Alexandria library fountain | +4.9 | +4.2 / +4.0 | +5.1 | +4.4 | +4.6 |
| Qin-Shi tomb lv.1 hall | +1.0 | +1.3 | +1.5 | | |

(The "after" column gives two runs where there were two.) Compatibility is not exact for the
effects' own colour: with no post-process, its scene shader tone-maps it (the filmic curve lifts mid
values). With the tone map linear on both sides, the Alexandria shares agree (+4.4 against +4.6).

The Hotan sheet box (effects off), against Compatibility:

| | filmic tone map | linear tone map |
|---|---|---|
| Forward+ before | 167 | |
| Forward+ after | 115 | 104 |
| Compatibility | 126 | 115 |

OURS and OPEN:
- **Effects draw after every transparent surface**, characters' included. The original orders a
  placed object's effects before a later object's blended meshes.
- **Overlapping sheets.** A second blended MTRL pass over a first, the sheets' back-then-front passes
  among them, blends against the opaque scene, not the first pass. That is the remaining -11 at the
  Hotan sheet.
- **Linear above white.** A pixel the pass draws on comes back clamped to the tone map's white.
- **Mesh culling.** Front faces are INFERRED: clockwise, flipped for a mirroring transform. Among the
  world's 170 ambient effect files only `map\guild\light_gate_blue.efp` (3 nodes) has a culled
  mesh node.
- **Skill and equipment effects** keep Godot's pass, unchanged.
- **QA switches:** `OPENSRO_QA_FX_PASS=off` (the twins), `OPENSRO_QA_MTRL_BLEND=linear`, and
  `OPENSRO_QA_FX_PASS=mask|band|clip|nodepth|dump` (probes).

## Playback (round 620)

How the client plays a decoded tree. `client/scripts/efp/efp_sim.gd` (`EfpSim`) implements it and
`efp_effect.gd` (`EfpEffect`) draws it. Labels are as above; OURS marks this client's choices.

**Who plays them.** Skills, buffs and hits (`SkillEffects`), worn gear (`EquipFx`), and the placed
map objects' `ambient` particle mods: the teleport structures (round 720), the dungeons (round 774)
and, since round 786, every other placed object -- fountains, waterfalls, lanterns, burners
(`WorldAmbientFx`; teleport_effects.md has the READ rules: the object's range, 2020 or 480 by its
`.o2` list, and the sectors in view). The water effects the round's census names
(`map\pajang*.efp`, `pokpopapyun`, `multugu-b`, `pokpomulbangul(-m)`, `multigi`,
`alex_library_01`/`_02`, `dun\dun_waterfall_b1`, ...) all build and draw through this code with no
node skipped (MEASURED, `efp_probe.gd --files=... --keep=1`: every one draws from its first frame,
`draw_mismatch 0 dropped 0`).

### Time (READ)

- **A frame is 50 ms.** The effect clock is `UI_ALCHEMYBOX::FUN_00bc1490`, reached through the thunk
  at `0x00bbda80` from the game loop. It adds the frame's millisecond delta (`DAT_0110f7f8`) to an
  accumulator at +0x168. Once that reaches 50, it stores `ftol(acc / 50.0)` frames at +0x16c (the
  double 50.0 is at `0x00d8f0b0`) and keeps the remainder.
- **The frames reach the particles.** `CRTModParticle::FUN_00c80ff0` passes +0x16c to the effect's
  `CEFEffect::vslot_000`. That stores the value at interface +0x4c, which is effect +0x28c (the
  interface sits at +0x240). The extinct executors (`FUN_00c84d80`, `…dd0`, `…e20`) then add +0x28c
  to every particle's age.
- **The delta is in milliseconds** (INFERRED). The game loop (funcs_017, near `0x00ba4106`) caps it
  at 3000, beside a float twin capped at 3.0.
- At 20 fps or more, each update advances one frame.

### Structure (READ, `FUN_00c86cd0`)

- **A node is a particle system.** Spawning a particle also creates an emitter for each child node.
  That emitter is owned by the new particle, so its age (emitter +0x28 → +0x54) is the particle's
  age.
- The root node's emitter is owned by the effect, whose age `CEFEffect::FUN_00ca9ee0` advances by
  1 per update.

### A particle's life (READ, the extinct executors)

| command | executor | rule |
|---|---|---|
| NormalTimeExtinct | `FUN_00c84e20` | age += frames; at age ≥ N, it is clamped to N − 1 and the particle is killed |
| NormalTimeLoop | `FUN_00c84dd0` | age += frames; age %= N |
| NeverExtinct | `FUN_00c84d80` | `if age != 1: age += frames`, so the age sticks at 1; a node with N = 0 kills the particle |

**A death is queued** (READ, round 623). "Kills" above is the particle's vtable slot 3
(`FUN_00c87ae0`, vtable `0x00e0ebfc`): it sets the dying flag +0x30 and appends the particle to its
node updater's death queue (the list at updater +0x78: count +0x9c, head +0xa0, tail +0xa4,
`FUN_00c87360`). The particle stays in the node's particle list, and the draw walks that list with
no test of +0x30, so it is drawn once more at its clamped last frame. The queue is flushed at the
start of the node's next update (`CEFUpdater::vslot_002`, `0x00c85f28`–`0x00c85f5a`): each
particle's slot 1 (`CEFElement::vslot_001`, `0x00c87a20`) takes 1.0 off its emitter's accumulator,
unlinks it, and kills its child emitters (`CEFGroup::vslot_001`), which then go when their last
particle does. So a particle of N frames is drawn N times, and an emitter can replace it in the
update that removes it.

**The order within a node's update** (READ, `CEFUpdater::vslot_002`): flush the death queue; the
executor lists at node +0x90, then +0xb4 (the emission, `0x00c84e70`, registered at `0x00c93184`),
then +0xd8; each particle's motion and follows; the list at +0x130 (the per-particle program,
`0x00c84f90`, registered at `0x00c92184`); every child node's update; and last the node's lifetime
executor at +0x12c (one of `0x00c84d80` / `…dd0` / `…e20`, registered at `0x00c92124`–`0x00c92164`;
each executor object's slot 4 calls the function at its +0xc with the updater, `0x00c90b80`). So a
child emitter reads its owner's age before the owner's age advances in the same update.

### The per-particle program (READ, `EFEffect::FUN_00c893f0`)

**Scheduling.**
- The executor calls this program with the particle's age. The program runs that age's command
  list (`FUN_00c84f90` indexes a per-frame list by the age).
- Key i runs at frame `ftol(f_i)`, where `f_0 = start`, `f_{i+1} = f32(f_i + step)`, and the loop
  runs while `f_i ≤ end` (READ, the loop at `0x00ca9276`–`0x00ca9354`, truncating under the fldcw at
  `0x00ca92b0`). A Frame* parameter's value i is key i.

**Opcodes.**
- Each command's factory (the `FUN_00ca8140` registrations) stores `opcode = base + space`. That is
  what the `space` byte is. The interpreter switches on the opcode (`0x00`–`0x51`).

| base | command | base | command |
|---|---|---|---|
| 0x00 | SetRotationMat | 0x3a | SetVelocity |
| 0x04 | SetRVelocityMat | 0x3e | SetConeVel |
| 0x05 | SetRotation | 0x42 | Force |
| 0x09 | SetRVelocity | 0x46 | ConeForce |
| 0x0a | SetRotationAxis | 0x4a | Attraction |
| 0x0e | SetRVelocityAxis | 0x4c | TextureSlide |
| 0x0f | SetBANRot | 0x4d | SetGraphScale |
| 0x13 | SetPosition | 0x4e | SetGraphRandomScale |
| 0x1f | SetConePos | 0x4f | SetGraphDiffuse |
| 0x2b | SetBANPos | 0x50 | SetShapeRot |
| 0x37 | SetSpherePos | 0x51 | SetShapeRotVel |

View and render commands are data-only objects that store `space + k`. View: None 0, Billboard 1,
YBillboard 2, VBillboard 3. Render: None 0, Plate 1, Mesh 2, LinkDPipe 3, LinkPipe 4, LinkObj 5.
Every retail view and render command has space 0 (MEASURED).

**What the space selects.**
- **Position commands** (SetPosition, SetConePos, SetBANPos) use 12 variants, `space = r×3 + o`.
  - `o = 0` adds to the current position; 1 starts from the parent particle's position; 2 starts
    from the "link" particle's (+0x34): the previous live particle of the same emitter (round 621,
    see "The link" below).
  - `r` rotates the value by: 0 nothing, 1 the particle's own rotation (+0xb0), 2 the parent's,
    3 the link's (`FUN_00410c30` is `v × M`).
  - MEASURED: SetPosition space 7 in 24,220 commands, i.e. parent position plus the value in the
    parent's frame.
- **SetSpherePos.** A point in the unit ball, from rejection sampling of `(r − 0.5) × 2`. `r` is
  drawn from a 5000-entry table at `0x01114ff0` through `FUN_00c877c0`.
  - Space 1 / 2: the point times the value, plus the parent's / link's position.
  - Space 0 (`0x00c8a4c5`–`0x00c8a5d4`): the point is written straight INTO the position. Then
    `position += value × V`, where V is a stack vector (`[esp+0x14..0x1c]`) that this case never
    sets. V holds what an earlier command of the same frame's run left there: the o = 0 cone
    positions, ConeForce, Attraction or SetSpherePos itself. It is uninitialised when none ran.
    `EfpSim` keeps V per particle run and starts it at zero (OURS for that case; 66 retail commands
    use space 0).
- **SetVelocity / SetConeVel** set the velocity (+0x1bc) to the value. **Force / ConeForce** add it
  to the velocity (READ, the add at `0x00c8aae8`).
  - **ConeForce space 0** (case 0x46) falls through into case 0x47 (READ, `0x00c8ac1d` →
    `0x00c8ac23`), so it adds a second cone rotated by the particle's own rotation.
  - Each rotates by: 0 nothing, 1 own, 2 parent, 3 link.
- **Attraction.** `velocity += normalize(pos − parent pos) × value`, or relative to the link for
  space 1.
- **Cone** (an AngleVector1 value):
  - The vector is `(0, lerp(b.x, b.y, r1), 0)`.
  - It is turned `r2 × b.z` about Z. `IDecoSkill::FUN_00a4d820` builds that rotation from
    `FUN_00b44b40` (fsin) and `FUN_00b44a10` (fcos).
  - It is then turned `r3 × 2π` about Y (`FUN_0043cda0`, the double 2π at `0x00d81930`).
  - b.z equals a.z in radians in every retail value (MEASURED). That the trig takes `b` is
    INFERRED.
- **SetRotation\*, SetBANRot.** The rotation is M (space 0), or M followed by own, parent or link
  (1–3).
- **SetRVelocity\*.** The per-frame rotation.
- **SetShapeRot / SetShapeRotVel.** The shape's rotation (+0x130) and its per-frame step (+0x170).
- **SetGraphScale.** The scale (+0x1c8) is the key's Vector3.
- **SetGraphDiffuse.** The colour (+0x228) is the key's u32.
  - When the effect's alpha byte `DAT_00edbd40` is not 0xFF, it scales the key's alpha.
- **TextureSlide.** The key's 4 floats are the UV rectangle (u0, v0, du, dv) at +0x22c (READ, the
  store at `0x00c8af77`).
  - The draw routines apply that rectangle as `u0 + u × du` (READ).
  - The head is not used; its meaning stays OPEN.
- **SetGraphRandomScale.** The scale is a BlendScaleGraph sampled at a random time
  (`FUN_00c89140`): the first key before `a`, the last after `b`, linear between. Which variable the
  pointer names is INFERRED: the node's first BlendScaleGraph.

### Motion and defaults (READ)

**Each frame** (`CEFUpdater::vslot_002`):
- a particle follows its parent's movement (the translation, and the rotation change);
- then `pos += vel`;
- the rotation is multiplied by the rotation velocity;
- the shape by the shape velocity.

**A new particle** (the EFEffect particle init):
- starts at its parent's position, with the parent's velocity and rotation;
- has identity rotation velocity, shape and shape velocity;
- has scale 1, colour `0xFFFFFFFF`, UV rectangle (0, 0, 1, 1) and age 0.

### Drawing (READ, `EFEffect::FUN_00cabda0` and the draw routines)

- **The world matrix** is the shape rotation, then the view matrix, then the position (row
  vectors).
- **The view matrix**:
  - ViewNone: the particle's rotation.
  - ViewBillboard: the matrix at `0x00edbde8`.
  - ViewYBillboard: the matrix at `0x00edbe28`.
  - `CEFSystem::FUN_00cb0ee0` builds both (READ). Each is the inverse of the view matrix
    (`0x00edbe68`) with its translation row zeroed. YBillboard then has row 1 forced to (0, 1, 0);
    rows 0 and 2 stay as they are, not re-orthogonalised.
  - The inverse view's rows are the camera's right, up and look directions. The client keeps the
    game's coordinates unconverted (a mirrored world; BmsReader reverses the winding), so look is
    Godot's −camera.z. `EfpEffect` builds the billboard as (right, up, −back), a reflection
    (INFERRED from that convention), and billboarded nodes draw both faces (OURS).
  - ViewVBillboard: a basis whose Y is the normalised velocity and whose Z is `velocity × up`
    (the identity when the velocity is 0 or straight up).
- **Plate** (`FUN_00c8c210`). The unit quad at `0x00edb070`: x and y ±0.5, z 0, with UV (0,0) at
  (−0.5, +0.5). It is scaled per axis by the particle's scale and transformed.
  - Every vertex takes the particle's colour.
  - The UV corners come from the UV rectangle.
- **Mesh** (`FUN_00c8bf50`). The `.bms` vertices, scaled and transformed the same way. The
  particle's colour replaces each vertex colour, and the UVs map through the rectangle.

### Ending a kept effect (READ, the IEasyFxEffect vtable at `0x00e0f594`)

**Keeping** (READ, round 623; this corrects round 620's "restarts a finished effect"). Each update,
`CEFEffect::vslot_000` (`0x00caf550`) calls `FUN_00ca9ee0`, which advances the effect's age, runs
the root node's update and returns 0 once every root emitter is done and has no particle. Then:
- On 0, `vslot_000` returns 0 and `CRTModParticle::FUN_00c80ff0` drops the effect. A kept effect
  that finishes is released like any other; nothing restarts it.
- Otherwise, with the keep flag +0x49 set (`0x00caf5ec`–`0x00caf622`), it walks the ROOT node
  updater's death queue (effect +0x254, head +0xa0, next at +0x90), clears each queued particle's
  dying flag (+0x30), sets its age (+0x54) to 0, and empties the queue.

So in a kept effect **the root node's particles never die**: each one that reaches the end of its
life starts it again at age 0, with its position, velocity and colour as they were. Its child
emitters read that age, so they start their cycle again (their done flag is not latched, see
"Emission") while the particles of the last cycle play out. Only the root node's queue is revived;
every other particle dies as usual. The retail auras rely on it: `cold_gigongta_keep_a` and
`lightning_gyeonggong_keep_a` have a 20-frame root that emits once and 20-frame children that emit
for 20 frames, so each child particle is replaced in the update its predecessor is flushed and the
aura never blinks.

**A one-shot that its owner lets go** (READ, round 623's review follow-up).
`CRTModParticle::FUN_00c80f60` asks the effect for its keep flag (slot 5, `CEFEffect::vslot_005`
returns +0x49). A kept effect is released at once through slot 2. A one-shot (keep 0) is handed to
its body's list of leftover effects (`FUN_00c31f80`: the list at +0x198 of the object at
mod +4 → +8) to play out. `CObjRendererVS::FUN_00c2a700` updates that list every frame through
slot 0 and drops an effect only when slot 0 returns 0, that is, when it finishes.
`FUN_00c2a670` releases the whole list, from the body's destructor (`FUN_00c323e0`, reached from
`CCompoundObj::ScalarDeletingDestructor`) and from `CCompChar::FUN_00c33230` / `FUN_00c33430` on
an update whose third argument is 0. What that argument means is OPEN. So in retail a one-shot
that never finishes plays until its body goes. `mad_general_at03`, a SHOT file whose NormalTimeLoop
node re-arms its children every wrap, is one. This client frees an effect with its body (it is
the body's child). It also ends a one-shot after `EfpEffect.ONESHOT_MAX_LIFE` = 30 s (OURS). The
longest one-shot that ends by itself lasts 238 frames (MEASURED over the 883 ACT_S and SHOT
files).

**The particle budget and a kept root** (OURS). Retail has no particle budget (READ, round 761:
the spawn loop `FUN_00c86cd0` takes each particle from the free list `FUN_00c86c30`, which mallocs
another chunk of 8,192 whenever it is empty and never refuses; nothing counts live particles or
effects; `docs/rounds/r761.md`). When this client's
budget refuses a kept effect's root, nothing is left to revive. Such an effect retries its root
every frame until the budget has room, instead of ending.

The owner ends an effect through one of two slots:
- **Slot 2** (`CEFEffect::vslot_002`) frees its particles (`EFEffect::FUN_00c85ea0`) and releases
  it at once.
- **Slot 4 with 0** (`vslot_004`) clears the restart flag (+0x49). It releases the effect when its
  keep count reaches 0.

Slot 4 with 1 sets the flag. That is AT_LOOP alone (round 785: AT_STOP is ActType 0 and is not
kept; see "Where a skill row places its effect"): the effect is kept as above.

**How a skill's decoration ends its effects** (READ, round 785). `IDecoSkill::FUN_00a4db00` calls
slot 4 **with 0** on the effect (the keep flag cleared) and stops the entry's sound; it runs for
every entry of the decoration from `IDecoSkill::FUN_00a4ffe0`, which a buff's end
(`FUN_00a53120`), a cancelled cast ("Skill Auto Cancel", `FUN_00a50a00`) and a cast whose phases
are done (`FUN_00a534d0`, phase index past 2) call. The decoration then goes on updating its
effects (`CIDecoSkill::vslot_014`: an ended decoration, +0xd0 set, with entries left keeps its
per-entry loop -- when its +0x184 callback is unset; one with the callback returns 0 at once, and
which decorations set it (`IDecoSkill::FUN_00a4d370`) is OPEN) and frees each one with slot 2 only
when its slot 0 returns 0, that is, when it has finished. So
a kept aura revives nothing more, its root particles die at the end of their life, its children
play out, and it ends: it fades over its last cycle.
- `EfpEffect.release()` does that (round 785): `SkillEffects.detach_aura` (the buff's end),
  `cancel_cast`, the cast's own loops at SHOT (the moment is the cast sequencer's, INFERRED) and
  the OURS guards. Rounds 620-784 cut them with `stop()`, so a recast's old aura vanished and the
  new one popped in at frame 0.
- `EfpEffect.stop()` is slot 2: every particle at once. It is kept for a teardown (a world
  unload, a body freed). This covers loop and never-extinct particles, which the review found in
  18 files that never end by themselves.

### Colour (MEASURED, round 620 review)

Instance colours are not converted from sRGB. The Compatibility renderer draws in sRGB space. A
white texture under a 0x80 particle colour, and a 0x80 texture under a white particle colour, both
come out 128, the same as an unshaded StandardMaterial3D with albedo 0x80. So the colour matches
D3D's fixed pipeline, and nothing is converted.

### What this client does not do yet (OPEN), and its own choices (OURS)

**Not drawn:**
- a node whose texture or mesh does not load (see "Assets that do not load");
- the flight of AT_MOV_* rows.

BSAnimation needs no drawing. Every one of the 3,230 nodes that carries a BSAnimation variable
(or a BAN controller) is RenderNone (MEASURED). Its motion reaches the particles as the baked
SetBANPos and SetBANRot keys, which are implemented.

**OURS:**
- A particle follows only its parent's translation.
- The order within a frame is: last frame's queued deaths flushed, motion, the particle's commands,
  emission (new particles run their frame-0 commands at once), then ages and new deaths queued (a
  kept effect reviving its root particles). Retail runs this node by node (see "The order within
  a node's update"); the flush and the late aging are READ, the whole-effect passes are OURS.
- ~~The emitters of a dead particle stop.~~ Now READ (round 623): the death kills its child
  emitters (`CEFElement::vslot_001`).
- There is a cap of 300 particles per effect and 2,000 in all. 600 of the 2,000 are reserved for
  the local player's own effects: its casts, hits and level-up.
  - MEASURED round 785 (`efp_probe.gd --census`, every effect the skilleffectset rows name, alone,
    still, 3 s): 76 of 1,359 runs have spawns refused by the 300, among them every Berserk wing
    (`hwanlook*`, 393 wanted), the fireworks (about 1,600-1,800) and a few monster skills; none
    of the China fire or lightning skills. Retail has no cap (round 761); the 300 is kept by the
    user's decision of 2026-10-09 (round 763), so it stays: OPEN for the user.
- **The cull box** (round 785). A draw node culls by `EfpEffect.DRAW_AABB` (±200 native units,
  OURS) grown to hold its particles plus its shape's reach (`_fit_box`), and a Link node by that
  box grown to its strip's own box (`_fit_link_box`); set on the RenderingServer only when it
  changes. Before, the fixed box culled a big effect whole while part of it showed: 46 of the
  1,359 runs reach past it on a still host (MEASURED). A native draw (EquipFx, the dungeons) keeps
  the fixed box.
  - GDScript costs about 7 µs a particle-frame (MEASURED), so the cap bounds a 50 ms frame at
    about 14 ms.
- Decoded templates, textures and meshes are kept by least-recent use: 256, 384 and 256 entries.
- A skill's files decode on a worker thread when the skill is known or put on the hotbar
  (`EfpEffect.preload_paths`).
- The emission globals are at full quality (0, 0).

**The blend mapping to Godot** (`EfpEffect.blend_class`):

| D3D src / dest | Godot | exact? |
|---|---|---|
| SRCALPHA / ONE | BLEND_MODE_ADD | exact |
| ONE / ONE | BLEND_MODE_ADD with alpha 1 | exact |
| SRCALPHA / INVSRCALPHA, BOTHSRCALPHA | BLEND_MODE_MIX | exact |
| ZERO / INVSRCALPHA | MIX with black | exact |
| anything else | MIX | OURS, approximate |

The texture-stage colour and alpha ops (SELECTARG1/2, MODULATE, 2X, 4X, ADD) run in the shader.

## Link render modes (round 621)

`client/scripts/efp/efp_links.gd` (`EfpLinks`) implements the geometry and `EfpEffect` draws it:
one ArrayMesh triangle strip per Link node (every chain stitched in), rebuilt after a simulation
step or a camera move (see "This client's choices" below).

### The link (READ)

- **Every emitter keeps its live particles in an intrusive list.** The emitter constructor
  `FUN_00c88320` sets the list object at emitter +0x30 with the prev offset 0x34 (at +0x38) and
  the next offset 0x38 (at +0x48). The list's count is at emitter +0x54.
- **The list class** (`FUN_00c87360` append, `CEFElement::FUN_00c873a0` remove): +8 prev offset,
  +0x18 next offset, +0x24 count, +0x28 head, +0x2c tail. Append sets the item's prev to the tail
  and its next to 0.
- **The particle init** `FUN_00c88490` (the particle vtable 0x00e0ebfc, slot 4) appends the new
  particle to its emitter's list (the call at 0x00c88769 on emitter +0x30). A death,
  `CEFElement::vslot_001` (`FUN_00c87a20`), unlinks it.
- **So particle +0x34 is the particle the same emitter spawned before this one that is still
  alive**, and +0x38 the one after. The oldest live particle has +0x34 = 0.
- Round 620 took the link to be the parent (OURS). That is corrected: `EfpSim.Particle.link` /
  `next_link`.
- **A variant that names the link does nothing without one.** The interpreter tests +0x34 first in
  every link case. There are 28 (review follow-up: every case of `FUN_00c893f0` that reads
  +0x34, listed from the decompile):

  | command | cases |
  |---|---|
  | SetRotationMat, SetRotation, SetRotationAxis, SetBANRot (space 3) | 0x03, 0x08, 0x0d, 0x12 |
  | SetPosition (origin link, or rotated by the link) | 0x15, 0x18, 0x1b, 0x1c, 0x1d, 0x1e |
  | SetConePos | 0x21, 0x24, 0x27, 0x28, 0x29, 0x2a |
  | SetBANPos | 0x2d, 0x30, 0x33, 0x34, 0x35, 0x36 |
  | SetSpherePos (space 2) | 0x39 |
  | SetVelocity, SetConeVel, Force, ConeForce (space 3) | 0x3d, 0x41, 0x45, 0x49 |
  | Attraction (space 1) | 0x4b |

  For the position commands (space = r·3 + o) these are exactly o = 2 or r = 3.
  `EfpSim.names_link` / `kind_names_link` encode the same set.
- The particle init also copies the owner's rotation and a second matrix (+0x64), and resets both
  to identity when bit 0 of emitter +0x74 is set. That bit's source was not traced (OPEN).

### Follow levels (READ; round 621's review follow-up and its "follow levels" commit)

**The block.** The body's 20-byte block lands at node +0x154..+0x16c (`FUN_00cc3500`): b0 +0x154,
b1 +0x155, u2 +0x158, u3 +0x15c, u4 +0x160, b5 +0x164, u6 +0x168, b7 +0x16c.

**The levels.** The emitter init (`CEFGroup::vslot_004`, emitter vtable 0x00e0ec4c slot 4) turns
each u32 into an ancestor. 0 means none; N ≥ 1 means the emitter's owner, then that owner's own
emitter's owner, N − 1 more times up.

| field | stored at | follow |
|---|---|---|
| u2 | emitter +0x68 | orbit: the position turns with the ancestor |
| u3 | emitter +0x6c | rotation. A negative u3 sets emitter +0x74, and the particle init then resets the inherited rotation to identity |
| u4 | emitter +0x70 | velocity |
| u6 | emitter +0x64 | translation |

**The top.** The effect itself is a particle-like element (`CEFEffect` shares `CEFElement`'s
layout; the particle init is slot 4 of both vtables). It owns the root node's emitter, so for a
node at depth d, level d + 1 is the effect.
- **The levels are signed.** The walk compares `1 < level`, and u3 is tested `< 1` and `< 0`.
  - MEASURED over the 95,801 nodes, read signed: no u2, u3, u4 or u6 is above d + 1.
  - The only negative value is u3 = −1, in 135 nodes of 101 files (for example
    `cos\pet2_hwan_keep_p`, `dun\pha_blue_eye_02`).
  - A negative u3 names no ancestor and resets the inherited rotation. A negative u2, u4 or u6
    would name the owner (none in retail).
  - The reader keeps the raw u32 (its dump matches the Go reader's). `EfpSim.signed32`
    converts it. The review found aa7a800 comparing the raw u32, so u3 = −1 never reset.
- The effect's position and matrix come from its host.
  - `CEFEffect::vslot_008` (position) stores the position divided by the effect's scale and
    flags +0x28b.
  - `vslot_007` (matrix, with its translation moved to the position) does the same and also
    flags +0x60.
  - Whenever either flag is set, the draw (`FUN_00cabda0`) runs the follow pass over the tree
    with the effect's turn, then stores the placement as old.
- The draw's world matrix is only that scale (`FUN_00cabda0`). So **retail simulates in world
  space over the effect's scale**, and only what follows the effect moves with the host.
- **The owner places the effect every frame, before its update** (READ, round 785):
  `CRTModParticle::FUN_00c81450` calls `FUN_00c81190` (vslot_010, then vslot_007), then
  `FUN_00c80ff0` (the update, when the effect clock gave frames), then the draw; a skill's
  decoration `CIDecoSkill::vslot_014` places a following effect through `IDecoSkill::FUN_00a4ddc0`
  (vslot_007) and then updates it. In a frame with an update, the update follows the placement
  and `CEFEffect::vslot_000` then stores the placement as old and clears +0x60 and +0x28b, so
  the draw runs no pass; in a frame without one the draw runs it. **One follow a frame.**

**Dead ancestors** (READ, round 785).
- A particle is reference-counted. Its emitter holds its owner (`CEFGroup::vslot_002` releases
  it), and a particle holds its emitter (`CEFElement::vslot_002`). A death
  (`CEFElement::vslot_001`) unlinks the particle from its node's list and kills its child
  emitters, and frees it only when its count is 0. So while a child emitter still has particles,
  the dead particle stays in memory, out of every list, its state as its last pass left it.
- The emitter init resolved each level to an ancestor **pointer** once (`CEFGroup::vslot_004`),
  and both passes read it with no test of the dying or dead flags (`CEFUpdater::vslot_002`,
  `FUN_00c863a0`: only `ancestor != 0`, and +0x60 for u2/u3/u4).
- So a follower of a dead ancestor keeps adding its frozen move (position − old position) on
  every pass, and its frozen turn while its +0x60 stays set. With one pass a frame, that move is
  the last frame's: a particle that outlives the one it follows goes on at the host's pace
  instead of being dropped where it was.
- Which pass is a dying particle's last: the pass of the frame before the update that flushes it.
  On a frame where the host did not move that pass leaves the particle's old state equal to its
  state and +0x60 clear, so a particle that dies after its host stopped freezes still.
- MEASURED (`efp_probe.gd --census`, 1,359 runs, 3 s at 144 frames a second, host at 50 native
  units a second): 733 runs draw particles that follow a dead ancestor (352,913 particle-frames).
  Their farthest drawn particle from the host: median 62.3 → 29.2 units. The user's
  `lightning_gyeonggong_keep_c` (a 50-frame wind under a 20-frame holder, every node u6 = 1):
  110.6 → 15.2 at 50 units a second, 1,155 → 15.2 at 525 (its still spread is 15.2).

**Each frame, per particle** (`CEFUpdater::vslot_002`):
1. with b0, keep the rotation as the old rotation (+0x64); with b1, keep the position as the old
   position (+0xa4); clear the changed flag (+0x60);
2. u2 ancestor F, **if F changed**: position = (position − F.old position) × F.turn + F.old
   position;
3. u3 ancestor, if changed: rotation = rotation × its turn, and this particle is changed;
4. u4 ancestor, if changed: velocity = velocity × its turn;
5. with b5: rotation = rotation × rotation velocity, and this particle is changed;
6. u6 ancestor A, **every frame**: position += A.position − A.old position;
7. position += velocity; with b7, the shape turns by the shape velocity.

Then the node's commands run; a rotation command also sets changed (every SetRotation* and
SetBANRot case: 0x00–0x03, 0x05–0x08, 0x0a–0x0d, 0x0f–0x12). With b0,
each particle's turn becomes inverse(old rotation) × rotation, the delta at +0x64. Child nodes are
updated after their parent's.

**At the effect.** When the effect changed, the draw (`FUN_00cabda0`) runs the same pass,
`FUN_00c863a0`, over the whole tree with the effect's turn, then stores its placement as old.
`CEFEffect::FUN_00c865a0` shifts every particle's position and old position by one vector: the
scale change `vslot_010` uses it.

**At spawn** (`FUN_00c88490`):
- the position is the owner's;
- the velocity is the owner's minus the u6 ancestor's;
- the rotation is the owner's, or identity with a negative u3;
- the position is also offset by (A.old − A.position) for the pass that follows its spawn.

**MEASURED over the 95,801 retail nodes:**
- **The followed ancestors keep their old state.** An ancestor followed through u2 or u6 has b1 in
  149,167 of 149,233 cases; through u3 or u4 it has b0 in all 77,375.
- **b5 and b7 mark the velocity commands.** b5 is set on exactly the 423 nodes with a
  SetRVelocity command, and b7 on exactly the 31,138 with SetShapeRotVel.
- **Levels:**

  | level | u2 | u6 |
  |---|---|---|
  | 0 (follow nothing) | 22,762 | 12,360 |
  | a particle ancestor | 69,695 | 79,538 |
  | the effect | 3,344 | 3,903 |

**This client** (`EfpSim`, `EfpEffect`):
- all four levels, the ancestor walk to the effect, the changed gate, b0/b1/b5/b7, and the spawn
  rules above (READ);
- **The effect is the sim's root particle.** `EfpSim.set_origin` places it. With `step_due`
  (round 785: `EfpEffect` asks `EfpSim.step_due(delta)`) the step that follows in the same frame
  takes the placement, as retail's update does; otherwise, when it moved or turned the effect (or
  a follower of a moving dead ancestor exists), it runs the draw's follow pass at once. Round 621
  ran the pass and then the step, two follows in a frame with a step.
- **A dead ancestor is followed by its frozen state** (round 785, READ above): the four follows
  test no `alive`. A pass runs on a still frame while a live particle follows a dead ancestor
  that still moves it (`EfpSim._zombie_follow`); otherwise a still frame is noted
  (`_still_pass`) and a particle flushed after it gets the still pass's state. `EfpSim.shift`
  moves a followed dead ancestor too (OURS: retail's shift, for a scale change, walks the live
  particles; this client's re-centre must be invisible). Mirrored in `native/src/core/efp_sim.rs`
  (`EFP_API` 2).
  - Every render frame: each particle keeps its old state, clears changed, and takes u2/u3/u4
    (gated) and u6. There is no velocity, rotation velocity or command in this pass.
  - So the effect's followers move with the host every frame, and during a 50 ms step the effect
    holds still.
- **`EfpEffect` pins itself** (top_level) at an anchor whose basis is the host's scale only, with
  its handedness kept. So space-0 commands point along world axes, and the host's facing arrives
  as the effect's rotation, as `vslot_007` hands it.
  - It re-centres (`EfpSim.shift`, like `FUN_00c865a0`) past 60 native units, and redraws on that
    frame.
  - A jump past 400 in one frame (a teleport, or the world re-based on a zone change) carries the
    whole effect along (OURS both).
  - Without a skeleton, it sits at the host plus its offset.
- So a u6 = 0 particle stays where it was born while the caster moves: the trails.

**OURS:**
- the effect is changed only when the placement moved or turned (retail flags every placement;
  same result);
- no spawn offset: a particle spawned in a step is placed after that frame's effect follow, as
  retail's offset intends;
- particles are processed in spawn order, which finishes every ancestor before its followers as
  retail's node order does;
- ~~a dead ancestor is no longer followed~~ (round 785: READ, followed by its frozen state; this
  OURS rule dropped the children of a part that died in a line behind a moving host -- the
  trails the user reported);
- below 20 frames a second this client steps two or more 50 ms frames in one rendered frame, each
  a full update; retail runs one update with the frames added to every age (round 620), so a
  follower of a dead ancestor moves once per update there and once per step here (OPEN; the
  user plays at 144);
- a synthetic node without the block follows its parent's translation (u6 = 1, b1), round 620's
  behaviour.
- The host's turn reaches the effect as its rotation. Where the placement is READ the effect
  takes it: an object's mode-0 entry (round 720, `follow_bone_full`), an equipment row (round 741,
  `CRTModParticle::FUN_00c81190`: the bone's matrix times the world's;
  `EquipFx.holder_transform`), and a skill row (round 785, below: the bone's turn for a plain
  StartBone, `follow_bone_turn`).

**Where a skill row places its effect** (READ, round 785; the row parser
`GlobalEffectManager::FUN_00a9d0f0`, `IDecoSkill::FUN_00a4a680`, `FUN_00a4ddc0`):
- **ActType** is looked up in the (name, value) table at `0x00ec7280`: AT_STOP 0, AT_ONE_FOLLOW 1,
  AT_LOOP 2, AT_TARGET 3, AT_TARGET_F 4, AT_SOURCE 5, AT_DMG_POS 6, AT_MOV_1TAR 7 ...
  AT_MOV_PIERCE 11. `IDecoSkill::FUN_00a513a0` keeps (slot 4 with 1) ActType 2 alone, places 0
  once when it is made, and gives 1 and 2 the per-frame placement. Rounds 620-784 had AT_STOP at
  2 (kept, following). 35 effect rows are AT_STOP (MEASURED: monster dust and stuns, the
  fireworks).
- **StartBone** sets the placement flags at row +0x44: a plain name 2, `@name` 0, `#name` 6, `*` 3,
  `none` 0 with no bone. `FUN_00a4a680` takes the body's matrix, multiplies the bone's (its
  model scale taken out) onto it, and keeps that rotation only with bit 1 (2); bit 0 adds a
  height; bit 2 names another object's bone. So a plain bone turns the effect with the bone
  (1,603 effect rows, MEASURED), `@` puts it at the bone along the world's axes, `none` at the
  body turned with it.
- **StartOffset** (row +0x48, pointed at from +0x40 by the post-pass at `0x00a95310` when it is not
  zero) is turned by the body's matrix, scaled by the body's scale, and added to the bone's
  position.
- **Rotate** (its own column) is parsed as degrees: 1-360 about Y (`FUN_0043cda0`), 361-720 about
  X by value - 360 (`FUN_009ecc10`), above 720 about Z by value - 720 (`FUN_00a4d820`); the
  constants are the doubles 360.0 at `0x00dde7a8` and 2π at `0x00d81930`. `FUN_00a4ddc0` applies
  it in the effect's frame, `R × placement` (`UI_SILKMALL::FUN_0055ebd0` is `this × m`). 284 effect
  rows carry one (MEASURED), e.g. 450 (90° about X) on the spear's pierce at `Bip01 R Hand`.
- This client: `SkillEffects.attach` sets `EfpEffect.follow_bone_turn` / `follow_world_turn` and
  `follow_basis` (`SkillEffects.rotate_basis`); `*` and `#` stay at the skeleton's origin turned
  with the body (OPEN).
- **A shared simulation drawn turned** (round 741, OURS: `EfpEffect.use_shared_turn`). `EquipFx`
  simulates one effect and draws it at many bones, each turned. A billboard must still face the
  camera and a pipe's side is the camera's, so those nodes build their geometry in the vertex
  shader: a plate's instance carries its scale (basis) and position, its custom data the shape's
  quaternion, and the shader lays it on the camera's right, up (world up for YBillboard) and look;
  a pipe's vertices carry their point, their neighbours and the signed width, and the shader
  projects the neighbours and builds `right·d.y − up·d.x` as `EfpLinks.pipe_ribbon` does. ViewNone,
  ViewVBillboard and LinkObj nodes need nothing: they turn with the holder as they should. A
  billboard node with a TextureSlide keeps the old path (its custom data is the UV rectangle):
  none among the 74 enchant and seal files (MEASURED).

**Link files that make a triangle** (`efp_census.gd --build`, peak of 40 frames, 975 files with a
drawn Link node):

| | files |
|---|---|
| round 621 review follow-up (local space) | 417 |
| follow levels, still host | 781 |
| follow levels, host moving 2 native units a frame (`--moving`, OURS speed) | **924** |

### Which particle draws (READ)

The draw setup `EFEffect::FUN_00cabda0` calls the node's routine for every particle. Each Link
routine returns at once unless +0x34 is 0. So only the oldest live particle of each emitter draws,
and it walks the list through +0x38 to the newest. That makes one strip per emitter, oldest first.
A child node has one emitter per parent particle, so it has one strip per parent particle.

### Points (READ, all three routines)

- A point is (position +0x1b0, colour +0x228, width = scale.x +0x1c8).
- A particle closer than 1e-6 on every axis (the float at `0x00e1b848`) to the last TAKEN
  position is a near-duplicate. What happens to it depends on the routine (review follow-up;
  round 621 had "overwrites" for all three):
  - **LinkDPipe and LinkPipe drop it and keep the older point.** Each writes the particle into
    the next free slot and advances only when it is taken (LinkDPipe 0x00c8df3f–0x00c8dfdd, and
    the same loop in `FUN_00c8e020`), so a near-duplicate is overwritten by the next particle.
  - **LinkObj overwrites the last taken pair with it.** It advances first and writes after
    (0x00c8c433–0x00c8c4c7). The comparison stays against the position that was taken, because
    local_48 changes only when a particle is taken, not against the one that overwrote it.
- **A retail quirk.** LinkPipe's counter starts at 1, so its "first point" test never fires and
  its first particle is compared against local_58 before anything was stored there
  (uninitialised stack). This client always takes the first particle (OURS).

### LinkDPipe (`EFEffect::FUN_00c8de80`, READ)

The taken points as they are, handed to the pipe ribbon. It needs 2 points. MEASURED: the retail
LinkDPipe nodes seen (the lightning files) place each particle with SetSpherePos, so the line is
jagged.

### LinkPipe (`EFEffect::FUN_00c8e020`, READ)

- The taken points P1..Pm get P0 = P1 and P(m+1) = Pm added.
- **A uniform cubic B-spline.** Each segment i = 0..m−2 over P(i)..P(i+3) is sampled 3 times (the
  loop count is literal) at t = 0, 1/3, 2/3. The step is the double 0.3333333432674408 at
  `0x00e0ec60`.
- The weights are (1−t)³/6, (3t³ − 6t² + 4)/6, (−3t³ + 3t² + 3t + 1)/6 and t³/6. The doubles are
  3.0 at `0x00e1b808`, 6.0 at `0x00d99a68`, 4.0 at `0x00e1b860` and 1.0 at `0x00e1b7f0`.
- The colour runs from P(i+1)'s to P(i+2)'s: each byte is lerped by t and rounded (`fistp`, half
  to even under the default control word).
- The width is P(i+1)'s plus k·(P(i+2) − P(i+1))/3 for sample k.
- Pm is appended last. So m points give 3(m − 1) + 1. It needs m ≥ 2.

### The pipe ribbon (`EFEffect::FUN_00c8d0e0`, READ except where marked)

- Each of the N ≥ 2 points is projected by `thunk_FUN_00aa30f0(out, in, NULL, 0x00edbea8,
  0x00edbe68, NULL)`. INFERRED: that is `D3DXVec3Project(out, v, viewport, projection, view,
  world)` from the statically linked D3DX (its CPU dispatch table at `0x00ec7758`), by its
  argument shape. With no viewport, the result is in normalised device coordinates.
- At point i the screen direction is d = C(i−1) − C(i+1). The first point uses C0 − C1, and the
  last uses C(N−2) − C(N−1).
- (d.y, −d.x, 0) is transformed by the matrix at `0x00edbde8` (`FUN_00854e30`, a row-vector
  transform with its translation row) and normalised (`FUN_00410cd0`, which leaves a zero vector
  at zero). That gives a world direction across the line on screen. `0x00edbde8` is the billboard
  matrix, whose rows are the inverse view's right, up and look (READ in round 620's review
  follow-up, `CEFSystem::FUN_00cb0ee0`). So the side is right·d.y − up·d.x.
- The two vertices are P + n·w (v = 0) and P − n·w (v = 1), so the ribbon is 2w wide. Both take
  the point's colour.
- u is 0 at the first point, i/(N−1) between, and 1 at the last. The UV rectangle
  (TextureSlide) is not applied.
- The vertex format is 0x18 bytes: position, colour, u, v. The primitive is
  D3DPT_TRIANGLESTRIP (the 5 pushed at `0x00c8d0c1`). `FUN_00cafbc0` batches it and
  `FUN_00cafa70` flushes it at once, so strips never join.

### LinkObj (`EFEffect::FUN_00c8c3a0`, READ)

- Each taken particle gives two edge points, pos + s·Y and pos − s·Y. Y is the second row of its
  rotation (+0xc0, +0xc4, +0xc8) and s its scale.x. The dedupe is on the position.
- The pairs are A1..Ak, with A0 = A1 and A(k+1) = Ak (the copies at 0x00c8c6e5–0x00c8c735).
- **Segments j = 0..k−3**, k − 2 of them, so Ak is only a control point. Each is sampled while
  t < 1.0 (t = 0, 1/3, 2/3) with the same B-spline, each edge on its own. The colour is A(j+1)'s
  to A(j+2)'s, lerped by byte.
- A(k−1) closes the strip.
- u starts at 1.0 and falls by 2.0 (the double at `0x00e1b898`) over the number of sample
  vertices, so it is 0 at the closing pair. v is 0 on the + edge and 1 on the − edge.
- It needs k ≥ 3 for a triangle; k = 2 gives a 2-vertex strip.
- The width follows the particle's own rotation, not the camera.

### Culling and winding

A Link strip takes its node's cull (render block +0x1a4: 1 none, 3 CCW, as for any node). MEASURED
by the reviewer: 17 LinkObj and 4 LinkPipe nodes have cull 3. Round 621 drew every strip
two-sided; the follow-up honours the cull.

Every strip triangle is emitted with its orientation reversed against D3D's. That is the
convention BmsReader uses for .bms triangles so that Godot's front face is D3D's (INFERRED from
that fix, the same inference the plate and mesh nodes rest on). Not checked against a retail
render.

### Texture (READ, `CEFCShape::FUN_00c883d0`)

A particle's shape (+0x1d4) is its node's first mesh entry, and its texture (+0x1d8) is that
entry's first texture. A RenderNone node has neither. `FUN_00cabda0` binds +0x1d8 with SetTexture
for every render mode, the Link modes included. This settles round 620's OURS "only the first
mesh entry and its first texture": that is what the client does.

### This client's choices (OURS)

- **One strip per node.** All of a node's chains go into one PRIMITIVE_TRIANGLE_STRIP ArrayMesh.
  Consecutive chains are stitched with repeated vertices, so the triangles between them have zero
  area and are never drawn. Each chain starts at an odd position of the joined strip, which gives
  its triangles the reversed orientation above.
- **Packed buffers.** The geometry is built in reused packed arrays (`EfpLinks.Buf`, `Out`): no
  per-point objects and no per-sample arrays.
- **When it rebuilds.** The strips are rebuilt only after a simulation step, or, for a
  screen-space pipe, when the camera, its projection or the effect moved.
- **A budget.** At most `EfpEffect.LINK_TRIS_PER_FRAME` = 20,000 Link triangles are rebuilt per
  rendered frame across all effects. A node past the budget keeps last frame's strips.
- Without a camera (headless tests and the census), the projection is orthographic down −Z of the
  effect's own axes.
- Which side gets v = 0 may be mirrored against retail by the handedness change (not checked).

## Assets that do not load (round 621, MEASURED with `efp_census.gd --build --assets`)

The census lists every texture and mesh that fails, with the reason. It checks Particles.pk2,
Media.pk2 and Data.pk2 beside it, other extensions, and the same basename in any folder of all
three.

**Textures** (75 files skip a node for one):
- **4 load now**: `textures\ques1_monster_paper_q_2..5.ddj`. Their DDS FourCC slot holds the
  bytes 71 00 00 00: D3DFORMAT 113, D3DFMT_A16B16G16R16F.
  - **The runtime loader** is `FUN_00b88420` → `FUN_00b87f20` (READ; its error string is
    "DDJCreateTextureHForMThread Error - %s"). It opens the path it is handed through the archive
    object's vtable +0x2c and reads 12 bytes, checking "JMXV". It then reads the u32 size field
    and the rest, and passes the buffer from file offset 20 to the statically linked
    D3DXGetImageInfoFromFileInMemory and D3DXCreateTextureFromFileInMemoryEx. The size passed is
    the size field minus 8, and the texture is created with the file's own MipLevels.
  - D3DX accepts a numeric D3DFORMAT in the FourCC slot.
  - Round 621 cited `FUN_00b8eb60`. That is a converter path the game does not run; its reading
    happened to agree.
  - **MEASURED:** all four are 128×128 with 8 declared mips.
    - **Only the top level is clean**, with every channel in 0..1.
    - Level 1 of `_q_2` holds 15 non-zero values, down to −512, and every other stored mip of
      all four is zero. Round 621's "every channel in 0..1" held for the top level only.
    - So retail, loading the declared mips, minifies these to black or garbage.
  - **This client takes the top level and lets Godot build clean mips** (OURS, not retail's look
    when minified). It rounds each clamped channel to 8 bits; round 621 truncated, biasing every
    channel by up to −1/255.
  - Each payload is twice the declared chain, and the size field is 256 bytes larger than the
    file (the `shield_90` pattern in DDJ_FORMAT.md).
  - Those 4 files each also name a `-glow` texture that is absent, so no file-level count
    changes.
- **20 texture paths are absent** from all three archives, under any folder or extension:
  `4ur_`, `aur_`, `bur_` and `cur_eplan03_rotation`, `bas_smoke_inver_h`, `beam_r`,
  `crash_glow`, `dark_ourp`, `daro_oura`, `eu_harp_14_l`, `explosion`, `n-light-reo`,
  `n-light01-z`, `oura_0555`, `ques1_monster2..5-glow`, `thunder4x4_02` and `water_80_glow`.
- **4 more are absent at their path**, with the same name elsewhere:
  - `water_offset_01.ddj` exists only in Data.pk2 as `Prim\Mtrl\etc\water_offset_01.ddj`.
    `FUN_00b88420` opens exactly the path it is handed, through the archive object it is given,
    with no rewrite (READ). So the effect's `textures\water_offset_01.ddj` cannot reach a file
    at `Prim\Mtrl\etc\` in another archive. Which archive object the effect loader hands in
    was not traced; that it is Particles.pk2's is INFERRED from every other effect texture
    resolving there.
  - `eu_harp_13`, `eu_shield_13` and `eu_sword_13` exist only as `.bms` meshes.
- **Nodes that name no texture at all**: in 36 files a drawn node has no texture entry, and in 10
  its texture is an empty string.

For both kinds, retail binds a NULL texture and draws (READ: `FUN_00cabda0` does not skip a
particle for it). What Direct3D 9's fixed-function stage returns for D3DTA_TEXTURE with no texture
bound was not established. The D3DTEXTURESTAGESTATETYPE page says only that "the default argument"
is D3DTA_DIFFUSE when no texture is set. **OPEN**: those nodes stay undrawn here rather than
drawn with a guessed colour.

**Meshes** (16 files):
- **`meshes\hwan01.bms` and `hwan02.bms` are `JMXVBMS 0109`, and the retail client refuses them
  too.**
  - Both .bms header checks accept only `0110`: `Prim::FUN_00bc5690` (case 1, "BMS ", assert at
    Prim.cpp line 0xd9) and `PrimGeometry::FUN_00c121f0` (PrimGeometry.cpp line 0x152).
  - A mismatch asserts and clears the success flag, so the load returns 0 (READ).
  - The only `0109` branch in the binary, `ResObject::FUN_00bce3b0`, is the `.bsr` "RES "
    header.
  - So there is no 0109 BMS layout to implement, and those nodes draw nothing in retail either
    (INFERRED: a shape with no geometry draws nothing).
- **4 mesh paths are absent** from all three archives: `cang001-one`, `nachal_size_test`,
  `season_circle` and `tahomet size test`.

## Census (MEASURED, round 619)

The census covers every `.efp` in the retail `Particles.pk2` on the RE box. There are two
implementations:
- `go run ./cmd/efpcensus -pk2 <Particles.pk2>` from `server/`. The same census also runs as
  `TestRetailCensus` when `OPENSRO_PARTICLES_PK2` is set.
- `client/tools/efp_census.gd`, the GDScript twin.

| | files | % |
|---|---|---|
| total | 4,170 | |
| headers parsed | 4,103 | 98.4 |
| tree decoded | 4,103 | 98.4 |
| … to the exact byte | 4,096 | 98.2 |
| … zero padding after the root | 6 | |
| … other bytes after the root | 1 | |
| not decoded: F8FILE / `0000` / empty | 58 / 7 / 2 | |

Every file whose header parses decodes. Every node's HeadLen matches its name and controllers,
and every Frame* parameter but 2 holds exactly its command's Keys.

`TestRetailCensus` **gates** these results, and fails on a regression. It requires:
- at least 4,103 files decoded;
- at least 4,096 of them to the exact byte;
- zero HeadLen mismatches;
- at most the 2 measured Frame* count mismatches.

**The two readers agree value for value.** `client/tools/efp_dump_diff.sh` has each reader write
a canonical dump of every decoded file: `efpcensus -dump` for Go, `tools/efp_dump.gd` for
GDScript. Each dump holds every field, floats as bit patterns, and every command's frame range
and Keys. The script compares one md5 per file. Round 619's review follow-up: all 4,103 dumps
are **identical**.

That run needed one choice to compare at all: a NaN prints as `nan`. GDScript widens floats to
doubles, which quiets the signalling NaNs that some garbage header fields hold.

**The census catches a wrong layout.** As a mutation check, AxisVector4 was read without its
64-byte matrix. Decoded files dropped from 4,103 to 784: exactly the files that use no
AxisVector4.

Feature use (files) among the 4,103 decoded:

| feature | files | feature | files |
|---|---|---|---|
| ViewBillboard | 3,255 | Force | 1,961 |
| RenderPlate | 3,291 | SetGraphRandomScale | 1,189 |
| RenderMesh | 2,575 | RenderLinkPipe | 864 |
| SetPosition | 3,233 | TextureSlide | 672 |
| SetSpherePos | 2,749 | BSAnimation / SetBANPos / SetBANRot | 600 |
| SetConeVel | 2,214 | ViewYBillboard / ViewVBillboard | 425 / 235 |
| SetGraphScale | 4,000 | Attraction | 231 |
| SetGraphDiffuse | 4,099 | NeverExtinct / NormalTimeLoop | 38 / 18 |

## The flat walk (history)

Before round 619, both readers recovered only a flat list of `(name, raw bytes)` pairs, finding
each boundary by scanning for the next identifier-shaped string. `Parse` / `EfpReader.parse` still
do this for callers that only want names, and now share the client's header handling above.

The root name rule is now relaxed to any bytes without control characters. With that and the
header fix, the flat walk accepts 4,103 files, where it accepted 3,316 before (MEASURED).

Four claims from that period are superseded:
- **"FUN_00cb9120 is the loader."** It is the editor's save path; `FUN_00cb8d70` loads.
- **"ProgramUpdate is followed by 35 bytes."** That was the gap to the next identifier: the 14
  command-header bytes plus the next fields of the body.
- **The header `Count`.** It is the root's controller count. The "top-level count" hypothesis
  refuted on 2026-08-24 was indeed wrong.
- **`NONAME` as a child marker.** It is a child node's name, read as the node's own string.
