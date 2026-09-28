package efp

// The typed tree decoder (round 619). Everything here was READ from the
// client's own loader in sro_client.exe; the addresses are in
// docs/protocol/EFP_FORMAT.md, which is the reference for every layout below.
// Field *meanings* are labelled where they are known: READ (from the code
// that consumes the field), MEASURED (from the value census over every .efp in
// Particles.pk2) or OPEN. A field without a label is only known by its size.
//
// A file is: the 12-byte "JMXVEFF nnnn" magic, a version-dependent header, one
// root node, and (in 7 of 4,170 retail files) trailing bytes the client never
// reads. A node is: u32 HeadLen, name, a list of named controllers (the editor's
// source blocks), the node's compiled body (program, command lists, render
// state) and its child nodes, recursively.

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"sort"
)

// Limits that stop a corrupt buffer from allocating unbounded slices. The
// 1000 controller cap is the client's own (FUN_00cc3a40 shows an error box
// above it); the rest are ours (OURS), set far above anything in the retail
// corpus (the largest count there is a few thousand frames).
const (
	maxControllers = 1000
	maxStringLen   = 4096
	maxListLen     = 1 << 20
	maxDepth       = 64
)

// Value is one decoded typed value. Its concrete type is one of the 16 value
// types that the property registry CGame::FUN_00ca0500 pairs with its keys;
// TypeName returns the registry's own name for it.
type Value interface{ TypeName() string }

// Vec3 is three little-endian float32s.
type Vec3 [3]float32

// Mat4 is a 4x4 float32 matrix exactly as stored: 16 floats, row-major, in
// Direct3D's row-vector convention (INFERRED from D3DX; the reader does not
// transpose).
type Mat4 [16]float32

// The 16 value types. Each comment gives the byte layout and the reader it was
// read from (the class's vtable slot 5, offset 0x14).
type (
	// Float: 4 bytes. `float`, vtable 0xe0ed3c, reader FUN_00c92350.
	Float float32
	// Vector: 12 bytes. `Vector`, vtable 0xe0ed58, reader 0x00c90960.
	Vector Vec3
	// Matrix: 64 bytes. `Matrix`, vtable 0xe0ee98, reader 0x00c923b0.
	Matrix Mat4
	// AxisVector4: 16 bytes (four floats) then a 64-byte matrix, 80 in all.
	// `AxisVector4`, vtable 0xe0eeb4, reader 0x00c92510. INFERRED: an axis
	// and angle plus the matrix the editor baked from it.
	AxisVector4 struct {
		Axis   [4]float32
		Matrix Mat4
	}
	// RotVector: 12 bytes then a 64-byte matrix, 76 in all. `RotVector`,
	// vtable 0xe0eed0, reader 0x00c92650.
	RotVector struct {
		Rot    Vec3
		Matrix Mat4
	}
	// AngleVector1: two Vec3s, 24 bytes. `AngleVector1`, vtable 0xe0ed74,
	// reader 0x00c90ab0. Used by the cone commands (SetConePos, SetConeVel,
	// ConeForce); which Vec3 is the axis and which the angles is OPEN.
	AngleVector1 struct{ A, B Vec3 }
	// StaticEmit: 20 bytes. `SEFStaticEmit`, vtable 0xe0ecb0, reader
	// 0x00c923d0 (a flat 0x14-byte copy). Field meanings READ from the
	// emitter update FUN_00c84e70 and the particle death FUN_00c87a20; see
	// Tick for the exact rule.
	StaticEmit struct {
		// Delay: frames after the node starts before emission begins.
		Delay uint32
		// Duration: frames (after Delay) during which it triggers.
		Duration uint32
		// Interval: trigger every Interval frames; 0 triggers nothing.
		Interval uint32
		// MaxLive: the cap on the emitter's live-particle count (the
		// accumulator at emitter +0x60 is clamped to it).
		MaxLive uint32
		// PerTrigger: particles each trigger adds to the accumulator;
		// fractions carry over to the next trigger.
		PerTrigger float32
	}
	// FrameScale: u32 n then n Vec3 — one scale per key of the command's
	// frame range (MEASURED: n == Command.Keys in 57,847 of 57,855 retail
	// SetGraphScale commands; usually every frame of the life).
	// `FrameScale`, reader 0x00c9ad90 -> FUN_00c9aba0.
	FrameScale []Vec3
	// FrameDiffuse: u32 n then n u32 colours, one per key (MEASURED: n ==
	// Command.Keys in 61,551 of 61,565 SetGraphDiffuse commands).
	// `FrameDiffuse`, reader 0x00c9b050 -> FUN_00c9af90. INFERRED: D3DCOLOR
	// (0xAARRGGBB).
	FrameDiffuse []uint32
	// FrameBANRotation: f32 then u32 n then n matrices. `FrameBANRotation`,
	// reader 0x00c9d330 -> FUN_00c9c380. The leading value is loaded and
	// stored as a float (fld/fstp); it is mostly 0 but not always
	// (MEASURED: e.g. 0.3). Meaning OPEN.
	FrameBANRotation struct {
		Head     float32
		Matrices []Mat4
	}
	// FrameBANPosition: f32 then u32 n then n Vec3. `FrameBANPosition`,
	// reader 0x00c9b140 -> FUN_00c9aba0. Leading f32 as above.
	FrameBANPosition struct {
		Head      float32
		Positions []Vec3
	}
	// BSAnimation: u32 n then n strings (.ban paths). `BSAnimation`,
	// reader 0x00c9c230 -> FUN_00c9b5f0 -> FUN_00c9a580 (string, then the
	// client loads the animation by that name, FUN_00cb8810).
	BSAnimation []string
	// FrameTextureSlide: a Vec3 then u32 n then n [4]float32.
	// `FrameTextureSlide`, reader 0x00c9d3a0 -> FUN_00c9c610. The head is
	// three floats; MEASURED most often (3,2,1), then (3,2,2) and
	// (3,3,0.25) (the census prints the full table). INFERRED: an atlas
	// grid (columns, rows) and a rate, with one [4]float32 per key. The
	// meanings are OPEN: the command's runtime (vtable 0xe0ef7c) only stores
	// the value into the particle, and its consumer was not traced.
	FrameTextureSlide struct {
		Head Vec3
		Keys [][4]float32
	}
	// BlendScaleGraph: f32 a, f32 b, u32 n, then n × (f32 time, Vec3).
	// `BlendScaleGraph`, reader 0x00c9f540 -> FUN_00c9f420. MEASURED: every
	// time and both a and b lie in [0,1] and the times are ascending.
	BlendScaleGraph struct {
		A, B float32
		Keys []ScaleKey
	}
	// BlendScaleGraphPointer: 4 bytes. `BlendScaleGraphPointer`, vtable
	// 0xe0ece4, reader 0x00c926a0. INFERRED: an index or reference into a
	// scale graph; OPEN.
	BlendScaleGraphPointer uint32
	// BlendDiffuseGraph: f32 a, f32 b, u32 n, then n × (f32 time, u32
	// colour). `BlendDiffuseGraph`, reader 0x00c9e3a0 -> FUN_00c9e2b0.
	BlendDiffuseGraph struct {
		A, B float32
		Keys []ColorKey
	}
)

// ScaleKey is one BlendScaleGraph key.
type ScaleKey struct {
	Time  float32
	Scale Vec3
}

// ColorKey is one BlendDiffuseGraph key.
type ColorKey struct {
	Time  float32
	Color uint32
}

func (Float) TypeName() string                  { return "float" }
func (Vector) TypeName() string                 { return "Vector" }
func (Matrix) TypeName() string                 { return "Matrix" }
func (AxisVector4) TypeName() string            { return "AxisVector4" }
func (RotVector) TypeName() string              { return "RotVector" }
func (AngleVector1) TypeName() string           { return "AngleVector1" }
func (StaticEmit) TypeName() string             { return "SEFStaticEmit" }
func (FrameScale) TypeName() string             { return "FrameScale" }
func (FrameDiffuse) TypeName() string           { return "FrameDiffuse" }
func (FrameBANRotation) TypeName() string       { return "FrameBANRotation" }
func (FrameBANPosition) TypeName() string       { return "FrameBANPosition" }
func (BSAnimation) TypeName() string            { return "BSAnimation" }
func (FrameTextureSlide) TypeName() string      { return "FrameTextureSlide" }
func (BlendScaleGraph) TypeName() string        { return "BlendScaleGraph" }
func (BlendScaleGraphPointer) TypeName() string { return "BlendScaleGraphPointer" }
func (BlendDiffuseGraph) TypeName() string      { return "BlendDiffuseGraph" }

// ValueTypes lists the 16 registry value types in registration order
// (CGame::FUN_00ca0500's FUN_00ca8080 calls).
var ValueTypes = []string{
	"float", "Vector", "Matrix", "SEFStaticEmit", "AxisVector4", "RotVector",
	"AngleVector1", "FrameScale", "BlendScaleGraph", "BlendScaleGraphPointer",
	"FrameDiffuse", "BlendDiffuseGraph", "FrameBANRotation",
	"FrameBANPosition", "BSAnimation", "FrameTextureSlide",
}

// CommandTypes is the command registry: every command name the client knows
// (the FUN_00ca8140 calls in CGame::FUN_00ca0500) mapped to the value type of
// its parameter, "" for a command that carries none.
var CommandTypes = map[string]string{
	"NeverExtinct":        "",
	"NormalTimeExtinct":   "",
	"NormalTimeLoop":      "",
	"StaticEmit":          "SEFStaticEmit",
	"ProgramUpdate":       "",
	"SetRotationMat":      "Matrix",
	"SetRVelocityMat":     "Matrix",
	"SetRotation":         "RotVector",
	"SetBANRot":           "FrameBANRotation",
	"SetRVelocity":        "RotVector",
	"SetRotationAxis":     "AxisVector4",
	"SetRVelocityAxis":    "AxisVector4",
	"SetPosition":         "Vector",
	"SetConePos":          "AngleVector1",
	"SetBANPos":           "FrameBANPosition",
	"SetSpherePos":        "Vector",
	"SetVelocity":         "Vector",
	"SetConeVel":          "AngleVector1",
	"Force":               "Vector",
	"ConeForce":           "AngleVector1",
	"Attraction":          "float",
	"TextureSlide":        "FrameTextureSlide",
	"SetGraphScale":       "FrameScale",
	"SetGraphRandomScale": "BlendScaleGraphPointer",
	"SetGraphDiffuse":     "FrameDiffuse",
	"SetShapeRot":         "AxisVector4",
	"SetShapeRotVel":      "AxisVector4",
	"ViewNone":            "",
	"ViewBillboard":       "",
	"ViewYBillboard":      "",
	"ViewVBillboard":      "",
	"RenderNone":          "",
	"RenderPlate":         "",
	"RenderMesh":          "",
	"RenderLinkDPipe":     "",
	"RenderLinkPipe":      "",
	"RenderLinkObj":       "",
}

// Controllers lists the ten controller keys (the FUN_00ca0180 calls). Note
// the tenth is spelled "BAN" in the file (DAT_00e0f45c, class CEFCBAN).
var Controllers = []string{
	"NormalTimeLife", "NormalTimeLoopLife", "StaticEmit", "Program",
	"LinkMode", "BAN", "ViewMode", "Shape", "ScaleGraph", "DiffuseGraph",
}

// Command is one entry of a command list (FUN_00ca5460). On disk: u8 present;
// when non-zero, name, u8 Space, u8 TimeFlags, f32 Start, f32 Step, f32 End,
// then the parameter if the registry gives the command a type.
//
// For a command with no parameter the five header fields are not initialised
// by the retail editor (MEASURED: stack garbage such as 0x0012eba8 and
// 0xcdcdcdcd), so they mean nothing there.
type Command struct {
	Name string
	// Space: the u8 at command+0x1c. MEASURED values 0-7 per command (e.g.
	// SetPosition 7, SetRotation 2, SetSpherePos 1); INFERRED a coordinate-
	// space or link selector; OPEN.
	Space uint8
	// TimeFlags, Start, Step, End: READ from FUN_00ca0f40, which turns them
	// into a frame range over the program's N frames. bit0: Start is a frame
	// number (0) or a percentage of N (1); bit1: Step is frames (0) or a
	// percentage of N (1); (TimeFlags>>2)%5 picks how End is read: 0 frame,
	// 1 percentage of N, 2 Start+End, 3 Start-int(End/-100)*N, 4
	// Start+End*Step (only when End >= 1). End is clamped to N-1. See
	// FrameRange.
	TimeFlags uint8
	Start     float32
	Step      float32
	End       float32
	// Value is the decoded parameter, nil when the command has none.
	Value Value
}

// ftol is the client's float-to-int conversion (_ftol, FUN_00b42d10): it
// truncates toward zero, and a value outside the int32 range, or NaN, gives
// the x87 "integer indefinite" 0x80000000. Mirroring that keeps garbage
// header fields (stack bytes, see Command) from producing huge ranges.
func ftol(x float32) int32 {
	if x != x || x >= 2147483648 || x < -2147483648 {
		return math.MinInt32
	}
	return int32(x)
}

// FrameRange evaluates the command's frame range against a program of n
// frames, exactly as FUN_00ca0f40 does, returning the first and last frame,
// the step, and ok=false where the client skips the command.
//
// The arithmetic is single precision, as the client's x87 runs under
// Direct3D 9's default FPU mode (INFERRED from D3D9 behaviour; it is also
// what makes the key counts match the stored values, see Keys), with 32-bit
// integer products and ftol conversions. Every intermediate is converted to
// float32 explicitly: the Go spec lets an implementation fuse or keep float
// operations wider otherwise, and only a conversion forces the rounding.
func (c *Command) FrameRange(n int) (start, end int, step float32, ok bool) {
	N := int32(n)
	var s, e int32
	if c.TimeFlags&1 == 0 {
		s = ftol(c.Start)
	} else {
		s = ftol(float32(c.Start/100)) * N
	}
	if c.TimeFlags&2 == 0 {
		step = c.Step
	} else {
		step = float32(float32(float32(N)*c.Step) / 100)
	}
	switch (c.TimeFlags >> 2) % 5 {
	case 0:
		e = ftol(c.End)
	case 1:
		e = ftol(float32(c.End/100)) * N
	case 2:
		e = s + ftol(c.End)
	case 3:
		// The divisor is the double -100.0 at 0x00db9a38 (READ), and the
		// product is subtracted, so this is Start + int(End/100)*N. Retail
		// uses it (MEASURED: Force in skill_cast_foot_*.efp, SetShapeRot in
		// dun\bagh_masin_bronze_light.efp, many StaticEmit headers).
		e = s - ftol(float32(c.End/-100))*N
	case 4:
		if c.End < 1 {
			return 0, 0, 0, false
		}
		e = s + ftol(float32(c.End*step))
	}
	if e >= N {
		e = N - 1
	}
	ok = e <= N && s <= e && step >= 1e-6
	return int(s), int(e), step, ok
}

// Keys is the number of keys the command spans over a program of n frames,
// FUN_00ca0f40's return value: ftol((end-start)/step)+1, or 0 when the client
// skips the command. MEASURED: a Frame* parameter holds exactly this many
// values in 132,666 of 132,668 retail Frame* commands (SetGraphDiffuse, SetGraphScale,
// SetBANPos, SetBANRot, TextureSlide), so a value's index is its key. Where ftol
// overflows the client's count would be negative; Keys returns 0 (OURS).
func (c *Command) Keys(n int) int {
	s, e, st, ok := c.FrameRange(n)
	if !ok {
		return 0
	}
	k := ftol(float32(float32(e-s)/st)) + 1
	if k < 0 {
		return 0
	}
	return int(k)
}

// RenderState is the 36-byte block the client hands straight to Direct3D 9
// when it draws the node (READ, EFEffect::FUN_00cabda0: SetRenderState and
// SetTextureStageState on stage 0 with these exact fields). The values are
// D3D enums: blend 2 = D3DBLEND_ONE, 5 = SRCALPHA, 6 = INVSRCALPHA; cull 1 =
// NONE, 2 = CW, 3 = CCW; texture op 2 = SELECTARG1, 4 = MODULATE, 5 =
// MODULATE2X, 6 = MODULATE4X; argument 0 = DIFFUSE, 2 = TEXTURE.
type RenderState struct {
	Cull      uint32 // D3DRS_CULLMODE; the loader rewrites 2 to 3 (FUN_00cc3400, FUN_00cc1760)
	SrcBlend  uint32 // D3DRS_SRCBLEND
	DestBlend uint32 // D3DRS_DESTBLEND
	ColorArg1 uint32 // D3DTSS_COLORARG1
	ColorArg2 uint32 // D3DTSS_COLORARG2
	ColorOp   uint32 // D3DTSS_COLOROP
	AlphaArg1 uint32 // D3DTSS_ALPHAARG1
	AlphaArg2 uint32 // D3DTSS_ALPHAARG2
	AlphaOp   uint32 // D3DTSS_ALPHAOP
}

// Additive reports whether the node blends additively (dest = ONE).
func (r RenderState) Additive() bool { return r.DestBlend == 2 }

// MeshRef is one mesh entry of a render block: a .bms path ("" for a plate)
// and its texture paths (FUN_00cc32b0).
type MeshRef struct {
	Mesh     string
	Textures []string
}

// ScalarGraph is a controller-side graph: f32 a, f32 b, u32 n, n × (f32
// time, 4-byte value) — CEFCScaleGraph::FUN_00cbf880. The ScaleGraph
// controller holds three of these (one per axis, INFERRED) with float values.
type ScalarGraph struct {
	A, B float32
	Keys []ScalarKey
}

// ScalarKey is a ScalarGraph key.
type ScalarKey struct{ Time, Value float32 }

// ByteGraph is the DiffuseGraph controller's first graph: f32 a, f32 b, u32
// n, n × (f32 time, u8) — CEFCScaleGraph::FUN_00cbf970. INFERRED: alpha.
type ByteGraph struct {
	A, B float32
	Keys []ByteKey
}

// ByteKey is a ByteGraph key.
type ByteKey struct {
	Time  float32
	Value uint8
}

// Controller is one named source block of a node. These are the editor's
// inputs: the client compiles each into the node body (CEFC*::vslot_006, e.g.
// NormalTimeLife -> the NormalTimeExtinct command, StaticEmit -> the node's
// StaticEmit parameter), so a renderer should read the node body instead.
// Exactly one of the typed fields is set, by Key.
type Controller struct {
	Key string
	// StaticEmit: 20 bytes (CEFCStaticEmit::vslot_003).
	Emit *StaticEmit
	// LinkMode: four u32 (CEFCLinkMode::vslot_003); meaning OPEN.
	Link [4]uint32
	// Program: a command list (CEFCProgram::vslot_003 -> FUN_00ca7280).
	Program []Command
	// BAN: u32 n + n strings (CEFCBAN::vslot_003).
	BAN []string
	// ViewMode: one string (CEFCViewMode::vslot_003).
	View string
	// Shape: render name, RenderState, meshes (CEFCShape::vslot_003).
	Render string
	State  RenderState
	Meshes []MeshRef
	// ScaleGraph: three ScalarGraphs then u32, f32 (CEFCScaleGraph::vslot_003).
	Scale      [3]ScalarGraph
	ScaleTail1 uint32
	ScaleTail2 float32
	// DiffuseGraph: a ByteGraph then a BlendDiffuseGraph
	// (CEFCDiffuseGraph::vslot_003).
	Alpha ByteGraph
	Color BlendDiffuseGraph
}

// Var is one typed variable of a node's program (CEEProgram::FUN_00ca85f0):
// a type name then that type's value. MEASURED: only BlendScaleGraph,
// BlendDiffuseGraph and BSAnimation occur.
type Var struct {
	Type  string
	Value Value
}

// NodeFlags is the 20-byte block between the command lists and the view
// command (FUN_00cc3500: u8, u8, u32, u32, u32, u8, u32, u8). Meanings OPEN;
// MEASURED: U2, U3, U4, U6 track the LinkMode controller's values.
type NodeFlags struct {
	B0, B1     uint8
	U2, U3, U4 uint32
	B5         uint8
	U6         uint32
	B7         uint8
}

// Node is one effect node (FUN_00cc3a40 reads it; FUN_00cc3500 its body).
type Node struct {
	// HeadLen is the u32 that opens a node: the byte length of the node's
	// name (with its length prefix) plus its controller block, i.e. of
	// everything up to the body (MEASURED: equal in 95,801 of 95,801 retail
	// nodes). The loader's cache mode (DAT_01119eac == 0, FUN_00cc3a40)
	// seeks past that span instead of reading it. Before round 619's review
	// this was misread as a node id (Node.ID).
	HeadLen uint32
	// headSpan is the span the reader actually consumed for it.
	headSpan int
	Name     string
	// Controllers in file order.
	Controllers []Controller
	// Frames is the program length N, in frames: the unit every command's
	// frame range and every Frame* value is measured in (READ: the
	// program's +4, read first by CEEProgram::FUN_00ca85f0 and used as N by
	// FUN_00ca0f40). The frame duration in seconds is OPEN.
	Frames uint32
	Vars   []Var
	// The node body's command slots, in file order, named by the commands
	// MEASURED in each over the whole retail corpus.
	List90  []Command // always empty in retail
	Emit    []Command // StaticEmit
	ListD8  []Command // always empty in retail
	Extinct *Command  // NormalTimeExtinct | NeverExtinct | NormalTimeLoop
	Update  []Command // ProgramUpdate
	Flags   NodeFlags
	View    *Command // ViewNone | ViewBillboard | ViewYBillboard | ViewVBillboard
	State   RenderState
	Meshes  []MeshRef
	Render  *Command  // RenderNone | RenderPlate | RenderMesh | RenderLinkPipe | RenderLinkDPipe | RenderLinkObj
	List20C []Command // always empty in retail
	// Commands is the per-particle program: SetPosition, SetConeVel, Force,
	// SetGraphScale, SetGraphDiffuse, TextureSlide, ... (the compiled copy
	// of the Program controller's list).
	Commands []Command
	Children []*Node
}

// File is a decoded .efp.
type File struct {
	Version string
	// Header0012: the f32 read when the version is >= "0012" (client
	// field +0x264); meaning OPEN (MEASURED 0.4 … 1.0).
	Header0012 float32
	// Header0013: the three u32 read when the version is >= "0013"
	// (client fields +0x268, +0x26c, +0x270); meaning OPEN.
	Header0013 [3]uint32
	Root       *Node
	// Trailing is the number of bytes after the root node, which the client
	// never reads. Zero for 4,163 of 4,170 retail files; the rest are padded.
	Trailing int
}

// Emitter-facing helpers, the surface round 620 renders from.

// Loops reports whether the node restarts when its program ends
// (NormalTimeLoop); NeverExtinct nodes persist too.
func (n *Node) Loops() bool { return n.Extinct != nil && n.Extinct.Name == "NormalTimeLoop" }

// NeverExtinct reports whether the node has no end.
func (n *Node) NeverExtinct() bool { return n.Extinct != nil && n.Extinct.Name == "NeverExtinct" }

// HeadLenMatches reports whether HeadLen equals the bytes the reader consumed
// for the name and controllers; the census counts any node where it does not.
func (n *Node) HeadLenMatches() bool { return int(n.HeadLen) == n.headSpan }

// EmitGlobals are the two client globals the emitter update reads (READ).
// One routine (0x005474b1-0x005474fc) sets both from an option string read
// with atoi: option 0 gives {0, 0}; option 1 gives {2, 10}; any other value
// gives {5, 10}. Which option this is, and its retail default, are OPEN.
type EmitGlobals struct {
	// IntervalMul is DAT_01114d54: when above 1, the trigger interval is
	// multiplied by it, unless that reaches the emitter's duration.
	IntervalMul int32
	// Threshold is DAT_01114d58: when above 0 and below an emitter's
	// PerTrigger, that emitter's MaxLive is halved (the float 0.5 at
	// 0xe1b7e0), with a floor of 1.
	Threshold int32
}

// DefaultEmitGlobals is full quality, {0, 0}: both globals live in .bss
// with no static initialiser, so they start at 0 until the option routine
// runs (READ). Chosen as the default because the retail default of the
// option is OPEN (OURS).
var DefaultEmitGlobals = EmitGlobals{}

// Tick runs one frame of an emitter exactly as FUN_00c84e70 does. age is
// the emitter's age in frames (emitter +0x54) and acc its live-particle
// accumulator (emitter +0x60, starting at 0). It returns how many particles
// to spawn this frame, the new accumulator, and stopped=true once the
// emitter is past Delay+Duration. The caller must subtract 1.0 from the
// accumulator for every particle that dies (READ, FUN_00c87a20), which is
// what lets MaxLive cap the live count.
func (e StaticEmit) Tick(age int, acc float32, g EmitGlobals) (spawn int, next float32, stopped bool) {
	t := int32(age) - int32(e.Delay)
	if t >= int32(e.Duration) {
		return 0, acc, true
	}
	interval := int32(e.Interval)
	if interval <= 0 || t < 0 {
		return 0, acc, false
	}
	if g.IntervalMul > 1 {
		if m := interval * g.IntervalMul; m < int32(e.Duration) {
			interval = m
		}
	}
	if t%interval != 0 {
		return 0, acc, false
	}
	capacity := int32(e.MaxLive)
	if g.Threshold > 0 && float32(g.Threshold) < e.PerTrigger && capacity > 0 {
		capacity = ftol(float32(float32(capacity) * 0.5))
		if capacity < 1 {
			capacity = 1
		}
	}
	old := ftol(acc)
	next = float32(e.PerTrigger + acc)
	if c := float32(capacity); c < next {
		next = c
	}
	return int(ftol(next) - old), next, false
}

// Emission returns the node's StaticEmit parameter, or nil.
func (n *Node) Emission() *StaticEmit {
	for i := range n.Emit {
		if v, ok := n.Emit[i].Value.(StaticEmit); ok {
			return &v
		}
	}
	return nil
}

// ViewMode returns the view command's name ("" when absent).
func (n *Node) ViewMode() string {
	if n.View == nil {
		return ""
	}
	return n.View.Name
}

// RenderMode returns the render command's name ("" when absent).
func (n *Node) RenderMode() string {
	if n.Render == nil {
		return ""
	}
	return n.Render.Name
}

// Command returns the first per-particle command with this name, or nil.
func (n *Node) Command(name string) *Command {
	for i := range n.Commands {
		if n.Commands[i].Name == name {
			return &n.Commands[i]
		}
	}
	return nil
}

// Walk visits n and every descendant, depth first, in file order.
func (n *Node) Walk(fn func(*Node)) {
	fn(n)
	for _, c := range n.Children {
		c.Walk(fn)
	}
}

// reader is a bounds-checked little-endian cursor.
type reader struct {
	b   []byte
	off int
}

var errShort = errors.New("efp: truncated")

func (r *reader) need(n int) error {
	if n < 0 || r.off+n > len(r.b) {
		return fmt.Errorf("%w: need %d bytes at offset %d of %d", errShort, n, r.off, len(r.b))
	}
	return nil
}

func (r *reader) u8() (uint8, error) {
	if err := r.need(1); err != nil {
		return 0, err
	}
	v := r.b[r.off]
	r.off++
	return v, nil
}

func (r *reader) u32() (uint32, error) {
	if err := r.need(4); err != nil {
		return 0, err
	}
	v := binary.LittleEndian.Uint32(r.b[r.off:])
	r.off += 4
	return v, nil
}

func (r *reader) f32() (float32, error) {
	v, err := r.u32()
	return math.Float32frombits(v), err
}

func (r *reader) count(limit uint32) (int, error) {
	at := r.off
	n, err := r.u32()
	if err != nil {
		return 0, err
	}
	if n > limit {
		return 0, fmt.Errorf("efp: count %d above %d at offset %d", n, limit, at)
	}
	return int(n), nil
}

// str reads a u32-length-prefixed byte string (Map::FUN_00a09210). Any bytes
// are allowed; retail names include "11111", author labels with spaces and
// EUC-KR Korean. The whole length is consumed, but the value is cut at the
// first NUL, as the client's c_str() users see it, and bytes above 0x7f
// become the Unicode code points of the same value (Latin-1), so the Go and
// GDScript readers produce identical strings (OURS: EUC-KR is not decoded;
// the raw byte values are kept).
func (r *reader) str() (string, error) {
	at := r.off
	n, err := r.u32()
	if err != nil {
		return "", err
	}
	if n > maxStringLen {
		return "", fmt.Errorf("efp: string length %d at offset %d", n, at)
	}
	if err := r.need(int(n)); err != nil {
		return "", err
	}
	s := latin1(r.b[r.off : r.off+int(n)])
	r.off += int(n)
	return s, nil
}

// latin1 cuts b at its first NUL and maps each byte to the code point of the
// same value.
func latin1(b []byte) string {
	if i := bytes.IndexByte(b, 0); i >= 0 {
		b = b[:i]
	}
	ascii := true
	for _, c := range b {
		if c >= 0x80 {
			ascii = false
			break
		}
	}
	if ascii {
		return string(b)
	}
	rs := make([]rune, len(b))
	for i, c := range b {
		rs[i] = rune(c)
	}
	return string(rs)
}

func (r *reader) vec3() (v Vec3, err error) {
	if err = r.need(12); err != nil {
		return
	}
	for i := range v {
		v[i], _ = r.f32()
	}
	return
}

func (r *reader) mat4() (m Mat4, err error) {
	if err = r.need(64); err != nil {
		return
	}
	for i := range m {
		m[i], _ = r.f32()
	}
	return
}

func (r *reader) strs() ([]string, error) {
	n, err := r.count(maxListLen)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, min(n, 64))
	for i := 0; i < n; i++ {
		s, err := r.str()
		if err != nil {
			return nil, err
		}
		out = append(out, s)
	}
	return out, nil
}

// readValue decodes one value of the named registry type.
func (r *reader) readValue(typ string) (Value, error) {
	switch typ {
	case "float":
		v, err := r.f32()
		return Float(v), err
	case "Vector":
		v, err := r.vec3()
		return Vector(v), err
	case "Matrix":
		m, err := r.mat4()
		return Matrix(m), err
	case "AxisVector4":
		var v AxisVector4
		if err := r.need(80); err != nil {
			return nil, err
		}
		for i := range v.Axis {
			v.Axis[i], _ = r.f32()
		}
		v.Matrix, _ = r.mat4()
		return v, nil
	case "RotVector":
		var v RotVector
		if err := r.need(76); err != nil {
			return nil, err
		}
		v.Rot, _ = r.vec3()
		v.Matrix, _ = r.mat4()
		return v, nil
	case "AngleVector1":
		var v AngleVector1
		if err := r.need(24); err != nil {
			return nil, err
		}
		v.A, _ = r.vec3()
		v.B, _ = r.vec3()
		return v, nil
	case "SEFStaticEmit":
		var v StaticEmit
		if err := r.need(20); err != nil {
			return nil, err
		}
		v.Delay, _ = r.u32()
		v.Duration, _ = r.u32()
		v.Interval, _ = r.u32()
		v.MaxLive, _ = r.u32()
		v.PerTrigger, _ = r.f32()
		return v, nil
	case "FrameScale":
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(12 * n); err != nil {
			return nil, err
		}
		v := make(FrameScale, n)
		for i := range v {
			v[i], _ = r.vec3()
		}
		return v, nil
	case "FrameDiffuse":
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(4 * n); err != nil {
			return nil, err
		}
		v := make(FrameDiffuse, n)
		for i := range v {
			v[i], _ = r.u32()
		}
		return v, nil
	case "FrameBANRotation":
		var v FrameBANRotation
		var err error
		if v.Head, err = r.f32(); err != nil {
			return nil, err
		}
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(64 * n); err != nil {
			return nil, err
		}
		v.Matrices = make([]Mat4, n)
		for i := range v.Matrices {
			v.Matrices[i], _ = r.mat4()
		}
		return v, nil
	case "FrameBANPosition":
		var v FrameBANPosition
		var err error
		if v.Head, err = r.f32(); err != nil {
			return nil, err
		}
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(12 * n); err != nil {
			return nil, err
		}
		v.Positions = make([]Vec3, n)
		for i := range v.Positions {
			v.Positions[i], _ = r.vec3()
		}
		return v, nil
	case "BSAnimation":
		s, err := r.strs()
		return BSAnimation(s), err
	case "FrameTextureSlide":
		var v FrameTextureSlide
		var err error
		if v.Head, err = r.vec3(); err != nil {
			return nil, err
		}
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(16 * n); err != nil {
			return nil, err
		}
		v.Keys = make([][4]float32, n)
		for i := range v.Keys {
			for j := 0; j < 4; j++ {
				v.Keys[i][j], _ = r.f32()
			}
		}
		return v, nil
	case "BlendScaleGraph":
		var v BlendScaleGraph
		if err := r.need(12); err != nil {
			return nil, err
		}
		v.A, _ = r.f32()
		v.B, _ = r.f32()
		n, err := r.count(maxListLen)
		if err != nil {
			return nil, err
		}
		if err := r.need(16 * n); err != nil {
			return nil, err
		}
		v.Keys = make([]ScaleKey, n)
		for i := range v.Keys {
			v.Keys[i].Time, _ = r.f32()
			v.Keys[i].Scale, _ = r.vec3()
		}
		v.Keys = mapKeys(v.Keys, func(k ScaleKey) float32 { return k.Time })
		return v, nil
	case "BlendScaleGraphPointer":
		v, err := r.u32()
		return BlendScaleGraphPointer(v), err
	case "BlendDiffuseGraph":
		g, err := r.diffuseGraph()
		return g, err
	}
	return nil, fmt.Errorf("efp: unknown value type %q at offset %d", typ, r.off)
}

func (r *reader) diffuseGraph() (BlendDiffuseGraph, error) {
	var v BlendDiffuseGraph
	if err := r.need(12); err != nil {
		return v, err
	}
	v.A, _ = r.f32()
	v.B, _ = r.f32()
	n, err := r.count(maxListLen)
	if err != nil {
		return v, err
	}
	if err := r.need(8 * n); err != nil {
		return v, err
	}
	v.Keys = make([]ColorKey, n)
	for i := range v.Keys {
		v.Keys[i].Time, _ = r.f32()
		v.Keys[i].Color, _ = r.u32()
	}
	v.Keys = mapKeys(v.Keys, func(k ColorKey) float32 { return k.Time })
	return v, nil
}

// command reads one FUN_00ca5460 entry; ok=false for an absent (u8 0) slot.
func (r *reader) command() (c Command, ok bool, err error) {
	present, err := r.u8()
	if err != nil || present == 0 {
		return c, false, err
	}
	if c.Name, err = r.str(); err != nil {
		return
	}
	if err = r.need(14); err != nil {
		return
	}
	c.Space, _ = r.u8()
	c.TimeFlags, _ = r.u8()
	c.Start, _ = r.f32()
	c.Step, _ = r.f32()
	c.End, _ = r.f32()
	typ, known := CommandTypes[c.Name]
	if !known {
		// The client skips the parameter of a name it does not know
		// (FUN_00ca4180 returns null), which would desynchronise any typed
		// command; we fail instead, so the census counts it.
		return c, true, fmt.Errorf("efp: unknown command %q at offset %d", c.Name, r.off)
	}
	if typ != "" {
		if c.Value, err = r.readValue(typ); err != nil {
			return
		}
	}
	return c, true, nil
}

func (r *reader) commandList() ([]Command, error) {
	n, err := r.count(maxControllers)
	if err != nil {
		return nil, err
	}
	var out []Command
	for i := 0; i < n; i++ {
		c, ok, err := r.command()
		if err != nil {
			return nil, err
		}
		if ok {
			out = append(out, c)
		}
	}
	return out, nil
}

func (r *reader) optCommand() (*Command, error) {
	c, ok, err := r.command()
	if err != nil || !ok {
		return nil, err
	}
	return &c, nil
}

func (r *reader) renderState() (RenderState, error) {
	var s RenderState
	if err := r.need(36); err != nil {
		return s, err
	}
	f := []*uint32{&s.Cull, &s.SrcBlend, &s.DestBlend, &s.ColorArg1, &s.ColorArg2,
		&s.ColorOp, &s.AlphaArg1, &s.AlphaArg2, &s.AlphaOp}
	for _, p := range f {
		*p, _ = r.u32()
	}
	if s.Cull == 2 {
		s.Cull = 3 // the loader's own rewrite
	}
	return s, nil
}

func (r *reader) meshes() ([]MeshRef, error) {
	n, err := r.count(maxListLen)
	if err != nil {
		return nil, err
	}
	out := make([]MeshRef, 0, min(n, 16))
	for i := 0; i < n; i++ {
		var m MeshRef
		if m.Mesh, err = r.str(); err != nil {
			return nil, err
		}
		if m.Textures, err = r.strs(); err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	return out, nil
}

func (r *reader) scalarGraph() (ScalarGraph, error) {
	var g ScalarGraph
	if err := r.need(12); err != nil {
		return g, err
	}
	g.A, _ = r.f32()
	g.B, _ = r.f32()
	n, err := r.count(maxListLen)
	if err != nil {
		return g, err
	}
	if err := r.need(8 * n); err != nil {
		return g, err
	}
	g.Keys = make([]ScalarKey, n)
	for i := range g.Keys {
		g.Keys[i].Time, _ = r.f32()
		g.Keys[i].Value, _ = r.f32()
	}
	g.Keys = mapKeys(g.Keys, func(k ScalarKey) float32 { return k.Time })
	return g, nil
}

func (r *reader) byteGraph() (ByteGraph, error) {
	var g ByteGraph
	if err := r.need(12); err != nil {
		return g, err
	}
	g.A, _ = r.f32()
	g.B, _ = r.f32()
	n, err := r.count(maxListLen)
	if err != nil {
		return g, err
	}
	if err := r.need(5 * n); err != nil {
		return g, err
	}
	g.Keys = make([]ByteKey, n)
	for i := range g.Keys {
		g.Keys[i].Time, _ = r.f32()
		g.Keys[i].Value, _ = r.u8()
	}
	g.Keys = mapKeys(g.Keys, func(k ByteKey) float32 { return k.Time })
	return g, nil
}

func (r *reader) controller(key string) (Controller, error) {
	c := Controller{Key: key}
	var err error
	switch key {
	case "NormalTimeLife", "NormalTimeLoopLife":
		// No data (their vslot_003 is an empty `ret 4`, 0x00cb9d80).
	case "StaticEmit":
		var v Value
		if v, err = r.readValue("SEFStaticEmit"); err == nil {
			e := v.(StaticEmit)
			c.Emit = &e
		}
	case "LinkMode":
		if err = r.need(16); err == nil {
			for i := range c.Link {
				c.Link[i], _ = r.u32()
			}
		}
	case "Program":
		c.Program, err = r.commandList()
	case "BAN":
		c.BAN, err = r.strs()
	case "ViewMode":
		c.View, err = r.str()
	case "Shape":
		if c.Render, err = r.str(); err != nil {
			break
		}
		if c.State, err = r.renderState(); err != nil {
			break
		}
		c.Meshes, err = r.meshes()
	case "ScaleGraph":
		for i := range c.Scale {
			if c.Scale[i], err = r.scalarGraph(); err != nil {
				return c, err
			}
		}
		if c.ScaleTail1, err = r.u32(); err == nil {
			c.ScaleTail2, err = r.f32()
		}
	case "DiffuseGraph":
		if c.Alpha, err = r.byteGraph(); err == nil {
			c.Color, err = r.diffuseGraph()
		}
	default:
		err = fmt.Errorf("efp: unknown controller %q at offset %d", key, r.off)
	}
	return c, err
}

func (r *reader) node(depth int) (*Node, error) {
	if depth > maxDepth {
		return nil, fmt.Errorf("efp: nodes nested deeper than %d", maxDepth)
	}
	n := &Node{}
	var err error
	if n.HeadLen, err = r.u32(); err != nil {
		return nil, err
	}
	headStart := r.off
	if n.Name, err = r.str(); err != nil {
		return nil, err
	}
	nc, err := r.count(maxControllers)
	if err != nil {
		return nil, err
	}
	for i := 0; i < nc; i++ {
		key, err := r.str()
		if err != nil {
			return nil, err
		}
		c, err := r.controller(key)
		if err != nil {
			return nil, err
		}
		n.Controllers = append(n.Controllers, c)
	}
	n.headSpan = r.off - headStart
	// The body, FUN_00cc3500, field by field.
	if n.Frames, err = r.u32(); err != nil {
		return nil, err
	}
	nv, err := r.count(maxControllers)
	if err != nil {
		return nil, err
	}
	for i := 0; i < nv; i++ {
		var v Var
		if v.Type, err = r.str(); err != nil {
			return nil, err
		}
		if v.Value, err = r.readValue(v.Type); err != nil {
			return nil, err
		}
		n.Vars = append(n.Vars, v)
	}
	if n.List90, err = r.commandList(); err != nil {
		return nil, err
	}
	if n.Emit, err = r.commandList(); err != nil {
		return nil, err
	}
	if n.ListD8, err = r.commandList(); err != nil {
		return nil, err
	}
	if n.Extinct, err = r.optCommand(); err != nil {
		return nil, err
	}
	if n.Update, err = r.commandList(); err != nil {
		return nil, err
	}
	if err = r.need(20); err != nil {
		return nil, err
	}
	f := &n.Flags
	f.B0, _ = r.u8()
	f.B1, _ = r.u8()
	f.U2, _ = r.u32()
	f.U3, _ = r.u32()
	f.U4, _ = r.u32()
	f.B5, _ = r.u8()
	f.U6, _ = r.u32()
	f.B7, _ = r.u8()
	if n.View, err = r.optCommand(); err != nil {
		return nil, err
	}
	if n.State, err = r.renderState(); err != nil {
		return nil, err
	}
	if n.Meshes, err = r.meshes(); err != nil {
		return nil, err
	}
	if n.Render, err = r.optCommand(); err != nil {
		return nil, err
	}
	if n.List20C, err = r.commandList(); err != nil {
		return nil, err
	}
	if n.Commands, err = r.commandList(); err != nil {
		return nil, err
	}
	kids, err := r.count(maxListLen)
	if err != nil {
		return nil, err
	}
	for i := 0; i < kids; i++ {
		c, err := r.node(depth + 1)
		if err != nil {
			return nil, err
		}
		n.Children = append(n.Children, c)
	}
	return n, nil
}

// headerSize returns the bytes between the 12-byte magic and the root node
// for a version, following FUN_00cb8d70: it compares the version as a
// big-endian number, reads an f32 when it is >= "0012" and three u32 more
// when it is >= "0013". Versions outside the retail set are rejected (the
// client would read anything above "0013" as 0013; we have never seen one).
//
// "0000" is rejected too. The client would read it like "0011", but the 7
// retail files carrying it are not in the node format (MEASURED: a run of
// small bytes precedes the name, and the first u32 read as a string length is
// 5,385 or more), and no skilleffect row names any of them. What wrote them
// is OPEN.
func headerSize(version string) (int, error) {
	switch version {
	case "0010", "0011":
		return 0, nil
	case "0012":
		return 4, nil
	case "0013":
		return 16, nil
	}
	if version == "0000" {
		return 0, errors.New("efp: version 0000 is not the node format")
	}
	return 0, fmt.Errorf("efp: unrecognized version %q", version)
}

// Decode reads a whole .efp into its typed tree. An error means the bytes do
// not follow the client's layout; File.Trailing > 0 means they did, with bytes
// left over that the client ignores.
func Decode(data []byte) (*File, error) {
	if len(data) < magicLen+1+versionLen {
		return nil, errors.New("efp: file too small to contain a header")
	}
	if string(data[:magicLen+1]) != magic+" " {
		return nil, fmt.Errorf("efp: bad magic %q, want %q", data[:magicLen+1], magic+" ")
	}
	f := &File{Version: string(data[magicLen+1 : magicLen+1+versionLen])}
	hs, err := headerSize(f.Version)
	if err != nil {
		return nil, err
	}
	r := &reader{b: data, off: magicLen + 1 + versionLen}
	if err := r.need(hs); err != nil {
		return nil, err
	}
	if hs >= 4 {
		f.Header0012, _ = r.f32()
	}
	if hs >= 16 {
		for i := range f.Header0013 {
			f.Header0013[i], _ = r.u32()
		}
	}
	if f.Root, err = r.node(0); err != nil {
		return nil, err
	}
	f.Trailing = len(data) - r.off
	return f, nil
}

// mapKeys orders graph keys the way the client stores them: in a std::map
// keyed by time (READ: FUN_00c9f420, FUN_00c9e2b0, FUN_00cbf880 and
// FUN_00cbf970 insert each key with map[time] = value). So the keys come out
// ascending by time and a repeated time keeps the value read last.
func mapKeys[K any](ks []K, time func(K) float32) []K {
	sort.SliceStable(ks, func(i, j int) bool { return time(ks[i]) < time(ks[j]) })
	out := ks[:0]
	for i, k := range ks {
		if i+1 < len(ks) && time(ks[i+1]) == time(k) {
			continue // a later key with the same time overwrites this one
		}
		out = append(out, k)
	}
	return out
}
