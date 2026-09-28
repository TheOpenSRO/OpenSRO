package efp

import (
	"encoding/binary"
	"math"
	"reflect"
	"strings"
	"testing"
)

// Synthetic buffers only (never retail data): a small encoder that writes the
// layouts Decode reads, one value type at a time and as a whole tree.

type enc struct{ b []byte }

func (e *enc) u8(v uint8)    { e.b = append(e.b, v) }
func (e *enc) u32(v uint32)  { e.b = appendU32(e.b, v) }
func (e *enc) f32(v float32) { e.b = appendF32(e.b, v) }
func (e *enc) str(s string)  { e.b = appendLenPrefixed(e.b, s) }
func (e *enc) vec3(v Vec3)   { e.f32(v[0]); e.f32(v[1]); e.f32(v[2]) }
func (e *enc) mat4(m Mat4) {
	for _, f := range m {
		e.f32(f)
	}
}
func (e *enc) strs(ss []string) {
	e.u32(uint32(len(ss)))
	for _, s := range ss {
		e.str(s)
	}
}
func (e *enc) state(s RenderState) {
	for _, v := range []uint32{s.Cull, s.SrcBlend, s.DestBlend, s.ColorArg1, s.ColorArg2,
		s.ColorOp, s.AlphaArg1, s.AlphaArg2, s.AlphaOp} {
		e.u32(v)
	}
}

func seqMat(base float32) (m Mat4) {
	for i := range m {
		m[i] = base + float32(i)
	}
	return
}

// value writes v in its on-disk layout.
func (e *enc) value(v Value) {
	switch x := v.(type) {
	case Float:
		e.f32(float32(x))
	case Vector:
		e.vec3(Vec3(x))
	case Matrix:
		e.mat4(Mat4(x))
	case AxisVector4:
		for _, f := range x.Axis {
			e.f32(f)
		}
		e.mat4(x.Matrix)
	case RotVector:
		e.vec3(x.Rot)
		e.mat4(x.Matrix)
	case AngleVector1:
		e.vec3(x.A)
		e.vec3(x.B)
	case StaticEmit:
		e.u32(x.Delay)
		e.u32(x.Duration)
		e.u32(x.Interval)
		e.u32(x.MaxLive)
		e.f32(x.PerTrigger)
	case FrameScale:
		e.u32(uint32(len(x)))
		for _, s := range x {
			e.vec3(s)
		}
	case FrameDiffuse:
		e.u32(uint32(len(x)))
		for _, c := range x {
			e.u32(c)
		}
	case FrameBANRotation:
		e.f32(x.Head)
		e.u32(uint32(len(x.Matrices)))
		for _, m := range x.Matrices {
			e.mat4(m)
		}
	case FrameBANPosition:
		e.f32(x.Head)
		e.u32(uint32(len(x.Positions)))
		for _, p := range x.Positions {
			e.vec3(p)
		}
	case BSAnimation:
		e.strs(x)
	case FrameTextureSlide:
		e.vec3(x.Head)
		e.u32(uint32(len(x.Keys)))
		for _, k := range x.Keys {
			for _, f := range k {
				e.f32(f)
			}
		}
	case BlendScaleGraph:
		e.f32(x.A)
		e.f32(x.B)
		e.u32(uint32(len(x.Keys)))
		for _, k := range x.Keys {
			e.f32(k.Time)
			e.vec3(k.Scale)
		}
	case BlendScaleGraphPointer:
		e.u32(uint32(x))
	case BlendDiffuseGraph:
		e.f32(x.A)
		e.f32(x.B)
		e.u32(uint32(len(x.Keys)))
		for _, k := range x.Keys {
			e.f32(k.Time)
			e.u32(k.Color)
		}
	default:
		panic("enc: unhandled value type")
	}
}

// sampleValues holds one non-trivial value of each of the 16 registry types,
// with its expected encoded size.
func sampleValues() []struct {
	v    Value
	size int
} {
	return []struct {
		v    Value
		size int
	}{
		{Float(2.5), 4},
		{Vector{1, 2, 3}, 12},
		{Matrix(seqMat(1)), 64},
		{AxisVector4{Axis: [4]float32{0, 1, 0, 0.5}, Matrix: seqMat(10)}, 80},
		{RotVector{Rot: Vec3{0.1, 0.2, 0.3}, Matrix: seqMat(20)}, 76},
		{AngleVector1{A: Vec3{0, 1, 0}, B: Vec3{30, 45, 0}}, 24},
		{StaticEmit{Delay: 2, Duration: 30, Interval: 3, MaxLive: 10, PerTrigger: 1}, 20},
		{FrameScale{{1, 1, 1}, {2, 2, 2}}, 4 + 24},
		{FrameDiffuse{0xff102030, 0x80ffffff, 0}, 4 + 12},
		{FrameBANRotation{Head: 0.3, Matrices: []Mat4{seqMat(3), seqMat(4)}}, 8 + 128},
		{FrameBANPosition{Head: 0.25, Positions: []Vec3{{1, 0, 0}}}, 8 + 12},
		{BSAnimation{"ani\\a.ban", "b"}, 4 + 4 + 9 + 4 + 1},
		{FrameTextureSlide{Head: Vec3{1, 4, 0.35}, Keys: [][4]float32{{0, 0, 0.25, 1}, {0.25, 0, 0.5, 1}}}, 12 + 4 + 32},
		{BlendScaleGraph{A: 0, B: 1, Keys: []ScaleKey{{0, Vec3{1, 1, 1}}, {1, Vec3{2, 3, 4}}}}, 12 + 32},
		{BlendScaleGraphPointer(7), 4},
		{BlendDiffuseGraph{A: 0, B: 1, Keys: []ColorKey{{0, 0xffffffff}, {0.5, 0x00ff0000}}}, 12 + 16},
	}
}

// Every registry value type decodes to exactly what was written and consumes
// exactly its bytes.
func TestValueTypesRoundTrip(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range sampleValues() {
		var e enc
		e.value(s.v)
		if len(e.b) != s.size {
			t.Fatalf("%s: encoder wrote %d bytes, the layout is %d", s.v.TypeName(), len(e.b), s.size)
		}
		e.b = append(e.b, 0xAA) // a sentinel that must be left unread
		r := &reader{b: e.b}
		got, err := r.readValue(s.v.TypeName())
		if err != nil {
			t.Errorf("%s: %v", s.v.TypeName(), err)
			continue
		}
		if !reflect.DeepEqual(got, s.v) {
			t.Errorf("%s: got %+v, want %+v", s.v.TypeName(), got, s.v)
		}
		if r.off != s.size {
			t.Errorf("%s: consumed %d bytes, want %d", s.v.TypeName(), r.off, s.size)
		}
		seen[s.v.TypeName()] = true
	}
	for _, name := range ValueTypes {
		if !seen[name] {
			t.Errorf("value type %s has no round-trip case", name)
		}
	}
}

// A value cut short anywhere is an error, never a panic or a silent success.
func TestValueTypesTruncated(t *testing.T) {
	for _, s := range sampleValues() {
		var e enc
		e.value(s.v)
		for cut := 0; cut < len(e.b); cut++ {
			r := &reader{b: e.b[:cut]}
			if _, err := r.readValue(s.v.TypeName()); err == nil {
				t.Errorf("%s cut to %d of %d bytes: want an error", s.v.TypeName(), cut, len(e.b))
			}
		}
	}
}

// command writes one present command.
func (e *enc) command(c Command) {
	e.u8(1)
	e.str(c.Name)
	e.u8(c.Space)
	e.u8(c.TimeFlags)
	e.f32(c.Start)
	e.f32(c.Step)
	e.f32(c.End)
	if c.Value != nil {
		e.value(c.Value)
	}
}

func (e *enc) commandList(cs []Command) {
	e.u32(uint32(len(cs)))
	for _, c := range cs {
		e.command(c)
	}
}

func (e *enc) meshes(ms []MeshRef) {
	e.u32(uint32(len(ms)))
	for _, m := range ms {
		e.str(m.Mesh)
		e.strs(m.Textures)
	}
}

var plateState = RenderState{Cull: 1, SrcBlend: 5, DestBlend: 2, ColorArg1: 2, ColorArg2: 0,
	ColorOp: 4, AlphaArg1: 2, AlphaArg2: 0, AlphaOp: 4}

// node writes a node with every controller kind (when full) and the given
// per-particle commands.
//
// The node's opening u32 is patched to the byte length of its name and
// controllers, as retail files carry (Node.HeadLen).
func (e *enc) node(name string, full bool, cmds []Command, kids int, kid func(*enc)) {
	headAt := len(e.b)
	e.u32(0)
	e.str(name)
	if full {
		e.u32(9)
		e.str("NormalTimeLife")
		e.str("StaticEmit")
		e.value(StaticEmit{Delay: 0, Duration: 1, Interval: 1, MaxLive: 1, PerTrigger: 1})
		e.str("LinkMode")
		e.u32(1)
		e.u32(1)
		e.u32(1)
		e.u32(0)
		e.str("Program")
		e.commandList(cmds)
		e.str("BAN")
		e.strs([]string{"ani\\swing.ban"})
		e.str("ViewMode")
		e.str("ViewBillboard")
		e.str("Shape")
		e.str("RenderPlate")
		st := plateState
		st.Cull = 2 // the loader rewrites 2 to 3
		e.state(st)
		e.meshes([]MeshRef{{Mesh: "", Textures: []string{"textures\\glow.ddj"}}})
		e.str("ScaleGraph")
		for i := 0; i < 3; i++ {
			e.f32(0)
			e.f32(1)
			e.u32(2)
			e.f32(0)
			e.f32(8)
			e.f32(1)
			e.f32(16)
		}
		e.u32(0)
		e.f32(60)
		e.str("DiffuseGraph")
		e.f32(0)
		e.f32(1)
		e.u32(1)
		e.f32(0.5)
		e.u8(0x80)
		e.value(BlendDiffuseGraph{A: 0, B: 1, Keys: []ColorKey{{0, 0xff00ff00}}})
	} else {
		e.u32(0)
	}
	binary.LittleEndian.PutUint32(e.b[headAt:], uint32(len(e.b)-headAt-4))
	// Body.
	e.u32(10) // frames
	if full {
		e.u32(3)
		e.str("BlendScaleGraph")
		e.value(BlendScaleGraph{A: 0, B: 1, Keys: []ScaleKey{{0, Vec3{1, 1, 1}}}})
		e.str("BlendDiffuseGraph")
		e.value(BlendDiffuseGraph{A: 0, B: 1})
		e.str("BSAnimation")
		e.value(BSAnimation{"ani\\swing.ban"})
	} else {
		e.u32(0)
	}
	e.commandList(nil)
	e.commandList([]Command{{Name: "StaticEmit", Value: StaticEmit{Duration: 30, Interval: 3, MaxLive: 10, PerTrigger: 1}}})
	e.commandList(nil)
	e.command(Command{Name: "NormalTimeLoop"})
	e.commandList([]Command{{Name: "ProgramUpdate"}})
	e.b = append(e.b, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0) // node flags
	e.command(Command{Name: "ViewBillboard"})
	e.state(plateState)
	e.meshes([]MeshRef{{Mesh: "", Textures: []string{"textures\\glow.ddj"}}})
	e.command(Command{Name: "RenderPlate"})
	e.commandList(nil)
	e.commandList(cmds)
	e.u32(uint32(kids))
	for i := 0; i < kids; i++ {
		kid(e)
	}
}

// everyTypedCommand is one command per parameter type the command registry
// uses, 13 types (the other three, BlendScaleGraph, BlendDiffuseGraph and
// BSAnimation, occur as program variables).
func everyTypedCommand() []Command {
	return []Command{
		{Name: "SetPosition", Space: 7, Step: 1, Value: Vector{0, 1, 0}},
		{Name: "SetRotationMat", Step: 1, Value: Matrix(seqMat(0))},
		{Name: "SetShapeRot", Step: 1, Value: AxisVector4{Axis: [4]float32{0, 1, 0, 1}, Matrix: seqMat(5)}},
		{Name: "SetRotation", Space: 2, Step: 1, Value: RotVector{Rot: Vec3{1, 2, 3}, Matrix: seqMat(6)}},
		{Name: "SetConeVel", Space: 2, Step: 1, Value: AngleVector1{A: Vec3{0, 1, 0}, B: Vec3{10, 20, 0}}},
		{Name: "Attraction", Step: 1, Value: Float(3)},
		{Name: "SetGraphScale", TimeFlags: 5, Step: 1, End: 100, Value: FrameScale{{1, 1, 1}}},
		{Name: "SetGraphRandomScale", TimeFlags: 9, Step: 1, End: 1, Value: BlendScaleGraphPointer(2)},
		{Name: "SetGraphDiffuse", TimeFlags: 4, Step: 1, End: 100, Value: FrameDiffuse{0xffffffff}},
		{Name: "SetBANRot", Space: 2, TimeFlags: 5, Step: 1, End: 100, Value: FrameBANRotation{Matrices: []Mat4{seqMat(2)}}},
		{Name: "SetBANPos", Space: 7, TimeFlags: 5, Step: 1, End: 100, Value: FrameBANPosition{Positions: []Vec3{{0, 2, 0}}}},
		{Name: "TextureSlide", TimeFlags: 8, Step: 1, End: 4, Value: FrameTextureSlide{Head: Vec3{1, 4, 0.25}, Keys: [][4]float32{{0, 0, 1, 0.25}}}},
		{Name: "Force", Space: 2, Step: 1, Value: Vector{0, -9.8, 0}},
	}
}

func buildTree(version string) []byte {
	var e enc
	e.b = append(e.b, []byte(magic+" "+version)...)
	switch version {
	case "0012":
		e.f32(0.4)
	case "0013":
		e.f32(0.5)
		e.u32(1)
		e.u32(2)
		e.u32(3)
	}
	e.node("root fx", true, everyTypedCommand(), 1, func(k *enc) {
		k.node("NONAME", false, []Command{{Name: "SetSpherePos", Space: 1, Step: 1, Value: Vector{0.5, 0.5, 0.5}}}, 0, nil)
	})
	return e.b
}

func TestDecodeTree(t *testing.T) {
	for _, version := range []string{"0010", "0011", "0012", "0013"} {
		data := buildTree(version)
		f, err := Decode(data)
		if err != nil {
			t.Fatalf("%s: Decode: %v", version, err)
		}
		if f.Trailing != 0 {
			t.Errorf("%s: %d bytes left, want 0", version, f.Trailing)
		}
		if version == "0013" && (f.Header0012 != 0.5 || f.Header0013 != [3]uint32{1, 2, 3}) {
			t.Errorf("0013 header: %v %v", f.Header0012, f.Header0013)
		}
		if version == "0012" && f.Header0012 != 0.4 {
			t.Errorf("0012 header: %v", f.Header0012)
		}
		n := f.Root
		if !n.HeadLenMatches() || n.Name != "root fx" || n.Frames != 10 {
			t.Fatalf("%s: root headlen %d %q frames %d", version, n.HeadLen, n.Name, n.Frames)
		}
		if len(n.Controllers) != 9 {
			t.Fatalf("%s: %d controllers, want 9", version, len(n.Controllers))
		}
		var shape *Controller
		for i := range n.Controllers {
			if n.Controllers[i].Key == "Shape" {
				shape = &n.Controllers[i]
			}
		}
		if shape == nil || shape.Render != "RenderPlate" || shape.State.Cull != 3 {
			t.Errorf("%s: Shape controller %+v (cull 2 must read as 3)", version, shape)
		}
		if !reflect.DeepEqual(n.Commands, everyTypedCommand()) {
			t.Errorf("%s: commands differ:\n got %+v\nwant %+v", version, n.Commands, everyTypedCommand())
		}
		if len(n.Vars) != 3 || n.Vars[2].Type != "BSAnimation" {
			t.Errorf("%s: vars %+v", version, n.Vars)
		}
		if em := n.Emission(); em == nil || em.MaxLive != 10 || em.Interval != 3 || em.Duration != 30 {
			t.Errorf("%s: emission %+v", version, em)
		}
		if !n.Loops() || n.NeverExtinct() {
			t.Errorf("%s: extinct %+v", version, n.Extinct)
		}
		if n.ViewMode() != "ViewBillboard" || n.RenderMode() != "RenderPlate" {
			t.Errorf("%s: view %q render %q", version, n.ViewMode(), n.RenderMode())
		}
		if n.State != plateState || !n.State.Additive() {
			t.Errorf("%s: render state %+v", version, n.State)
		}
		if len(n.Meshes) != 1 || n.Meshes[0].Textures[0] != "textures\\glow.ddj" {
			t.Errorf("%s: meshes %+v", version, n.Meshes)
		}
		if c := n.Command("SetGraphDiffuse"); c == nil || c.Value.(FrameDiffuse)[0] != 0xffffffff {
			t.Errorf("%s: SetGraphDiffuse %+v", version, c)
		}
		if len(n.Children) == 1 && !n.Children[0].HeadLenMatches() {
			t.Errorf("%s: child HeadLen %d does not match its name+controllers", version, n.Children[0].HeadLen)
		}
		if len(n.Children) != 1 || n.Children[0].Name != "NONAME" || len(n.Children[0].Commands) != 1 {
			t.Fatalf("%s: children %+v", version, n.Children)
		}
		count := 0
		n.Walk(func(*Node) { count++ })
		if count != 2 {
			t.Errorf("%s: Walk visited %d nodes, want 2", version, count)
		}
	}
}

// Every proper prefix of a valid file is an error; bytes after the root node
// are reported, not silently accepted as part of it.
func TestDecodeTruncatedAndTrailing(t *testing.T) {
	data := buildTree("0011")
	for cut := 0; cut < len(data); cut++ {
		if _, err := Decode(data[:cut]); err == nil {
			t.Fatalf("cut to %d of %d bytes: want an error", cut, len(data))
		}
	}
	f, err := Decode(append(append([]byte{}, data...), 0, 0, 0))
	if err != nil || f.Trailing != 3 {
		t.Fatalf("trailing: err %v, trailing %v", err, f)
	}
}

func TestDecodeRejects(t *testing.T) {
	good := buildTree("0011")
	cases := map[string][]byte{
		"bad magic":    append([]byte("JMXVBMS 0011"), good[12:]...),
		"version 0000": append([]byte(magic+" 0000"), good[12:]...),
		"version 9999": append([]byte(magic+" 9999"), good[12:]...),
		"F8FILE":       append([]byte("F8FILE\x01\x00\x00\x01"), make([]byte, 40)...),
		"empty":        nil,
	}
	for name, data := range cases {
		if _, err := Decode(data); err == nil {
			t.Errorf("%s: want an error", name)
		}
	}
	// An unknown command name would desynchronise every later value.
	var e enc
	e.b = append(e.b, []byte(magic+" 0011")...)
	e.node("x", false, []Command{{Name: "SetWobble", Step: 1}}, 0, nil)
	if _, err := Decode(e.b); err == nil || !strings.Contains(err.Error(), "unknown command") {
		t.Errorf("unknown command: got %v", err)
	}
}

// FrameRange follows FUN_00ca0f40.
func TestCommandFrameRange(t *testing.T) {
	cases := []struct {
		c          Command
		n          int
		start, end int
		step       float32
		ok         bool
		why        string
	}{
		{Command{TimeFlags: 4, Start: 0, Step: 1, End: 100}, 30, 0, 29, 1, true, "mode 1: End% of N, clamped to N-1"},
		{Command{TimeFlags: 5, Start: 0, Step: 1, End: 100}, 30, 0, 29, 1, true, "bit0: Start% of N"},
		{Command{TimeFlags: 0, Start: 5, Step: 1, End: 24}, 30, 5, 24, 1, true, "mode 0: absolute frames"},
		{Command{TimeFlags: 8, Start: 2, Step: 1, End: 4}, 30, 2, 6, 1, true, "mode 2: Start+End"},
		{Command{TimeFlags: 2 | 4, Start: 0, Step: 10, End: 100}, 30, 0, 29, 3, true, "bit1: Step% of N"},
		{Command{TimeFlags: 16, Start: 0, Step: 2, End: 3}, 30, 0, 6, 2, true, "mode 4: Start+End*Step"},
		{Command{TimeFlags: 16, Start: 0, Step: 2, End: 0.5}, 30, 0, 0, 0, false, "mode 4 with End < 1 is skipped"},
		{Command{TimeFlags: 0, Start: 10, Step: 1, End: 5}, 30, 10, 5, 1, false, "start after end is skipped"},
		{Command{TimeFlags: 0, Start: 0, Step: 0, End: 5}, 30, 0, 5, 0, false, "zero step is skipped"},
	}
	for _, tc := range cases {
		s, e, st, ok := tc.c.FrameRange(tc.n)
		if s != tc.start || e != tc.end || st != tc.step || ok != tc.ok {
			t.Errorf("%s: got %d..%d step %g ok %v, want %d..%d step %g ok %v",
				tc.why, s, e, st, ok, tc.start, tc.end, tc.step, tc.ok)
		}
	}
}

// Keys is FUN_00ca0f40's return: the number of values a Frame* parameter
// holds over the range.
func TestCommandKeys(t *testing.T) {
	cases := []struct {
		c    Command
		n    int
		keys int
	}{
		{Command{TimeFlags: 5, Step: 1, End: 100}, 30, 30},         // every frame of the life
		{Command{TimeFlags: 8, Start: 2, Step: 1, End: 4}, 30, 5},  // frames 2..6
		{Command{TimeFlags: 6, Step: 10, End: 100}, 30, 10},        // 0..29 every 3
		{Command{TimeFlags: 16, Step: 2, End: 3}, 30, 4},           // 0..6 every 2
		{Command{TimeFlags: 16, Step: 2, End: 0.5}, 30, 0},         // skipped
		{Command{TimeFlags: 0, Start: 10, Step: 1, End: 5}, 30, 0}, // skipped
	}
	for _, tc := range cases {
		if got := tc.c.Keys(tc.n); got != tc.keys {
			t.Errorf("%+v over %d frames: %d keys, want %d", tc.c, tc.n, got, tc.keys)
		}
	}
}

// Every command in the registry has a known parameter type.
func TestCommandRegistryTypes(t *testing.T) {
	types := map[string]bool{}
	for _, v := range ValueTypes {
		types[v] = true
	}
	if len(CommandTypes) != 37 {
		t.Errorf("%d commands, the registry has 37", len(CommandTypes))
	}
	for name, typ := range CommandTypes {
		if typ != "" && !types[typ] {
			t.Errorf("command %s has unknown type %q", name, typ)
		}
	}
	if len(ValueTypes) != 16 || len(Controllers) != 10 {
		t.Errorf("%d value types, %d controllers; the registry has 16 and 10", len(ValueTypes), len(Controllers))
	}
}

// End mode 3 divides by the double -100.0 at 0x00db9a38 and subtracts:
// end = start - ftol(End/-100)*N, i.e. start + int(End/100)*N.
func TestFrameRangeMode3(t *testing.T) {
	c := Command{TimeFlags: 12, Start: 2, Step: 1, End: 100} // (12>>2)%5 == 3
	s, e, _, ok := c.FrameRange(30)
	if s != 2 || e != 29 || !ok {
		t.Errorf("End 100: got %d..%d ok %v, want 2..29 (start + N, clamped to N-1)", s, e, ok)
	}
	c.End = 50 // int(0.5) == 0
	if s, e, _, ok := c.FrameRange(30); s != 2 || e != 2 || !ok {
		t.Errorf("End 50: got %d..%d ok %v, want 2..2", s, e, ok)
	}
}

// Garbage header floats (the editor left no-parameter commands uninitialised)
// go through the client's _ftol: out of range is 0x80000000, never a huge
// positive frame or key count.
func TestFrameRangeGarbage(t *testing.T) {
	if got := ftol(3e9); got != math.MinInt32 {
		t.Errorf("ftol(3e9) = %d, want MinInt32", got)
	}
	if got := ftol(float32(math.NaN())); got != math.MinInt32 {
		t.Errorf("ftol(NaN) = %d, want MinInt32", got)
	}
	if got := ftol(-2.9); got != -2 {
		t.Errorf("ftol(-2.9) = %d, want -2 (truncation)", got)
	}
	cases := []Command{
		{TimeFlags: 0, Start: 0, Step: 1, End: 1e20},     // end -> MinInt32 < start
		{TimeFlags: 0, Start: 3e9, Step: 1, End: 5},      // start -> MinInt32, end 5
		{TimeFlags: 8, Start: 0, Step: 1, End: 1e30},     // start + MinInt32
		{TimeFlags: 0, Start: 0, Step: 1e-30, End: 20},   // step below 1e-6
		{TimeFlags: 16, Start: 0, Step: 1e10, End: 1e10}, // End*Step overflows
	}
	for _, c := range cases {
		k := c.Keys(30)
		if k < 0 || k > 30*2 {
			// A range can only span start..N-1; with start at MinInt32 the
			// client's own count overflows, and Keys reports 0.
			if k != 0 {
				t.Errorf("%+v: %d keys", c, k)
			}
		}
		if k > 0 {
			s, e, st, _ := c.FrameRange(30)
			if s < -1<<31 || e > 29 || st < 1e-6 {
				t.Errorf("%+v: range %d..%d step %g", c, s, e, st)
			}
		}
	}
}

// Tick follows FUN_00c84e70: MaxLive caps the live accumulator, PerTrigger
// fractions carry, and the two globals scale interval and cap.
func TestStaticEmitTick(t *testing.T) {
	e := StaticEmit{Delay: 2, Duration: 10, Interval: 2, MaxLive: 3, PerTrigger: 1.5}
	var acc float32
	var got []int
	for age := 0; age < 14; age++ {
		n, next, stopped := e.Tick(age, acc, DefaultEmitGlobals)
		acc = next
		if stopped && age < 12 {
			t.Fatalf("stopped at age %d, want at 12 (Delay+Duration)", age)
		}
		got = append(got, n)
	}
	// Triggers at ages 2, 4, 6, 8, 10 (t = 0, 2, 4, 6, 8): acc 1.5, 3 (cap),
	// then stays at the cap because nothing died.
	want := []int{0, 0, 1, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("spawns %v, want %v", got, want)
	}
	// A death subtracts 1.0; the next trigger refills to the cap.
	acc -= 1
	if n, next, _ := e.Tick(6, acc, DefaultEmitGlobals); n != 1 || next != 3 {
		t.Errorf("after a death: spawn %d acc %g, want 1 and 3", n, next)
	}
	// Reduced quality: the interval doubles (4 < Duration 10), so age 4
	// (t = 2) does not trigger; and MaxLive halves only when PerTrigger
	// exceeds the threshold.
	low := EmitGlobals{IntervalMul: 2, Threshold: 10}
	if n, _, _ := e.Tick(4, 0, low); n != 0 {
		t.Errorf("interval x2: age 4 spawned %d", n)
	}
	big := StaticEmit{Duration: 10, Interval: 1, MaxLive: 9, PerTrigger: 20}
	if n, next, _ := big.Tick(0, 0, low); n != 4 || next != 4 {
		t.Errorf("halved cap: spawn %d acc %g, want 4 (int(9*0.5))", n, next)
	}
	if n, _, _ := big.Tick(0, 0, DefaultEmitGlobals); n != 9 {
		t.Errorf("full quality cap: spawn %d, want 9", n)
	}
}

// Graph keys land in a std::map keyed by time: sorted, last write wins.
func TestGraphKeysAreAMap(t *testing.T) {
	var e enc
	e.f32(0)
	e.f32(1)
	e.u32(4)
	for _, k := range []ColorKey{{1, 0x10}, {0, 0x20}, {0.5, 0x30}, {0, 0x40}} {
		e.f32(k.Time)
		e.u32(k.Color)
	}
	r := &reader{b: e.b}
	g, err := r.diffuseGraph()
	if err != nil {
		t.Fatal(err)
	}
	want := []ColorKey{{0, 0x40}, {0.5, 0x30}, {1, 0x10}}
	if !reflect.DeepEqual(g.Keys, want) {
		t.Errorf("keys %v, want %v", g.Keys, want)
	}
}

// Strings are cut at the first NUL (the client's c_str) after consuming the
// full length, and high bytes keep their values as code points.
func TestStringNULAndHighBytes(t *testing.T) {
	var e enc
	e.str("abc\x00def")
	e.str("\xb7\xb9")
	e.u32(7)
	r := &reader{b: e.b}
	a, _ := r.str()
	b, _ := r.str()
	tail, _ := r.u32()
	if a != "abc" || b != "\u00b7\u00b9" || tail != 7 {
		t.Errorf("got %q %q tail %d", a, b, tail)
	}
}

func TestDecodeChecksFullMagic(t *testing.T) {
	data := buildTree("0011")
	data[7] = '_'
	if _, err := Decode(data); err == nil {
		t.Error("magic without its space: want an error")
	}
}
