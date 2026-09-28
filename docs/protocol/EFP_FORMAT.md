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

**The frame's duration in seconds is OPEN.** The emitter age (`FUN_00c84e70` reads it at emitter
+0x28 → +0x54) is the lead.

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

It then switches on a render-type value 1-5 at def +0x208 to pick the draw routine
(`FUN_00c8c210`, `…bf50`, `…de80`, `…e020`, `…c3a0`). Which render mode each value is remains
OPEN.

**Blending is per node, in this block.** This settles the spec's OPEN question: it is not carried
by the texture name. MEASURED, files using each state among rendered nodes:
- src SRCALPHA (5) / dest ONE (2), **additive**: 3,879 files;
- src SRCALPHA / dest INVSRCALPHA (6), **alpha**: 2,007 files;
- other pairs: 30 files. They include ZERO/INVSRCALPHA (9 files), BOTHSRCALPHA (12) with
  INVSRCALPHA or ONE (6 and 5), and INVSRCCOLOR/SRCCOLOR (4). A renderer that handles only
  additive and alpha blending draws 99 % of files with the right blend.

Colour op MODULATE (4) is the most common, then MODULATE2X (5) and MODULATE4X (6). The arguments
are TEXTURE (2) and DIFFUSE (0).

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
