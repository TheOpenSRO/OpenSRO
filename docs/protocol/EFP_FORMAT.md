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
| 7 | 20-byte block | inline | u8, u8, u32, u32, u32, u8, u32, u8. Meaning OPEN; the u32s track the LinkMode controller's values |
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
1. When `t ≥ duration`, the emitter is finished and does nothing more.
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

## Playback (round 620)

How the client plays a decoded tree. `client/scripts/efp/efp_sim.gd` (`EfpSim`) implements it and
`efp_effect.gd` (`EfpEffect`) draws it. Labels are as above; OURS marks this client's choices.

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
| NeverExtinct | `FUN_00c84d80` | `if age != 1: age += frames`, so the age sticks at 1 |

### The per-particle program (READ, `EFEffect::FUN_00c893f0`)

**Scheduling.**
- The executor calls this program with the particle's age. The program runs that age's command
  list (`FUN_00c84f90` indexes a per-frame list by the age).
- A Frame* parameter's value i belongs to frame `start + i × step` (INFERRED from the MEASURED key
  counts).

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
- **SetSpherePos.** A uniform point in the unit ball, times the value, added to: 0 the position,
  1 the parent's position, 2 the link's.
  - The point comes from rejection sampling of `(r − 0.5) × 2`. `r` is drawn from a 5000-entry
    table at `0x01114ff0` through `FUN_00c877c0`.
- **SetVelocity / SetConeVel** set the velocity (+0x1bc) to the value. **Force / ConeForce** add it
  (INFERRED: the decompile leaves the add's target implied).
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
- **TextureSlide.** The key's 4 floats are INFERRED to be the UV rectangle (u0, v0, du, dv) at
  +0x22c; the decompile loses the store's target.
  - The draw routines apply that rectangle as `u0 + u × du` (READ).
  - The head is not used; its meaning stays OPEN.
- **SetGraphRandomScale.** The scale is a BlendScaleGraph sampled at a random time
  (`FUN_00c89140`): the first key before `a`, the last after `b`, linear between. Which variable the
  pointer names is INFERRED: the node's first BlendScaleGraph.
- **The ConeForce oddity.** Case 0x46 falls through into 0x47 in the decompile. Whether that is
  real is OPEN.

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
    - INFERRED from the names: the camera-facing and the upright camera-facing billboards.
  - ViewVBillboard: a basis whose Y is the normalised velocity and whose Z is `velocity × up`
    (the identity when the velocity is 0 or straight up).
- **Plate** (`FUN_00c8c210`). The unit quad at `0x00edb070`: x and y ±0.5, z 0, with UV (0,0) at
  (−0.5, +0.5). It is scaled per axis by the particle's scale and transformed.
  - Every vertex takes the particle's colour.
  - The UV corners come from the UV rectangle.
- **Mesh** (`FUN_00c8bf50`). The `.bms` vertices, scaled and transformed the same way. The
  particle's colour replaces each vertex colour, and the UVs map through the rectangle.

### What this client does not do yet (OPEN), and its own choices (OURS)

**Not drawn:**
- a node whose texture or mesh does not load (see "Assets that do not load");
- the flight of AT_MOV_* rows.

BSAnimation needs no drawing. Every one of the 3,230 nodes that carries a BSAnimation variable
(or a BAN controller) is RenderNone (MEASURED). Its motion reaches the particles as the baked
SetBANPos and SetBANRot keys, which are implemented.

**OURS:**
- A particle follows only its parent's translation.
- The order within a frame is: motion, the particle's commands, emission (new particles run their
  frame-0 commands at once), then ages.
- The emitters of a dead particle stop.
- There is a cap of 300 particles per effect and 3,000 in all.
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
one ImmediateMesh per Link node, rebuilt every frame, one triangle strip per emitter.

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
  every link case: 0x03, 0x08, 0x0d, 0x12 (rotation), 0x15, 0x18, 0x1b–0x1e, 0x21, 0x28, 0x2d,
  0x36 (positions), 0x39 (sphere), 0x3d, 0x41, 0x45, 0x49 (velocity, force) and 0x4b
  (attraction). `EfpSim.names_link` lists them by command and space.
- The particle init also copies the owner's rotation and a second matrix (+0x64), and resets both
  to identity when bit 0 of emitter +0x74 is set. That bit's source was not traced (OPEN).

### Which particle draws (READ)

The draw setup `EFEffect::FUN_00cabda0` calls the node's routine for every particle. Each Link
routine returns at once unless +0x34 is 0. So only the oldest live particle of each emitter draws,
and it walks the list through +0x38 to the newest. That makes one strip per emitter, oldest first.
A child node has one emitter per parent particle, so it has one strip per parent particle.

### Points (READ, all three routines)

- A point is (position +0x1b0, colour +0x228, width = scale.x +0x1c8).
- A particle is taken if it is the first, or if its position differs from the last taken one by
  more than 1e-6 on some axis (the float at `0x00e1b848`). Otherwise it overwrites the last taken
  one.

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
  at zero). That gives a world direction across the line on screen. INFERRED: `0x00edbde8` is the
  camera-facing billboard matrix (round 620), whose rows are the camera's right and up.
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

### Texture (READ, `CEFCShape::FUN_00c883d0`)

A particle's shape (+0x1d4) is its node's first mesh entry, and its texture (+0x1d8) is that
entry's first texture. A RenderNone node has neither. `FUN_00cabda0` binds +0x1d8 with SetTexture
for every render mode, the Link modes included. This settles round 620's OURS "only the first
mesh entry and its first texture": that is what the client does.

### This client's choices (OURS)

- A strip becomes a triangle list, with the strip's alternating winding.
- Both faces are drawn. The game's handedness is mirrored on the way into Godot, and which face
  of a generated ribbon D3D would cull was not checked.
- Without a camera (headless tests and the census), the projection is orthographic down −Z of the
  effect's own axes.
- Which side gets v = 0 may be mirrored against retail by the handedness change (not checked).

## Assets that do not load (round 621, MEASURED with `efp_census.gd --build --assets`)

The census lists every texture and mesh that fails, with the reason. It checks Particles.pk2,
Media.pk2 and Data.pk2 beside it, other extensions, and the same basename in any folder of all
three.

**Textures** (75 files skip a node for one):
- **4 load now**: `textures\ques1_monster_paper_q_2..5.ddj`. Their DDS FourCC slot holds the
  bytes 71 00 00 00: D3DFORMAT 113, D3DFMT_A16B16G16R16F. The client hands the DDS after the
  20-byte wrapper to the static D3DX loader (READ, `FUN_00b8eb60`:
  D3DXGetImageInfoFromFileInMemory, then D3DXCreateTextureFromFileInMemoryEx), and D3DX accepts a
  numeric D3DFORMAT there. MEASURED: all four are 128×128 with 8 mips, and every channel lies
  in 0..1. Each payload is twice the 174,760-byte mip chain; the surplus is not read (INFERRED
  that D3DX ignores it too).
  - Those 4 files each also name a `-glow` texture that is absent, so no file-level count
    changes.
- **20 texture paths are absent** from all three archives, under any folder or extension:
  `4ur_`, `aur_`, `bur_` and `cur_eplan03_rotation`, `bas_smoke_inver_h`, `beam_r`,
  `crash_glow`, `dark_ourp`, `daro_oura`, `eu_harp_14_l`, `explosion`, `n-light-reo`,
  `n-light01-z`, `oura_0555`, `ques1_monster2..5-glow`, `thunder4x4_02` and `water_80_glow`.
- **4 more are absent at their path**, with the same name elsewhere:
  - `water_offset_01.ddj` exists only in Data.pk2 as `Prim\Mtrl\etc\water_offset_01.ddj`.
    `FUN_00b8eb60` opens the path it is given with no rewrite (READ), so that copy is not
    reachable from an effect.
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
  `TestRetailCensus` when `SRREVAMP_PARTICLES_PK2` is set.
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
