package efp

// Dump writes a decoded file as canonical text, so the Go reader can be
// diffed against the GDScript one (client/tools/efp_dump.gd writes the same
// format; client/tools/efp_dump_diff.sh compares them). Floats are printed as
// their float32 bit patterns (any NaN as "nan"), strings as "<code points>:<text>", and every
// field of every node, controller, command and value appears in file order.
// Keep the two writers identical.

import (
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
)

type dumper struct {
	b      strings.Builder
	frames int // the current node's program length, for each command's range
}

func (d *dumper) w(format string, a ...any) { fmt.Fprintf(&d.b, format, a...) }
func (d *dumper) f(x float32) {
	if x != x {
		// GDScript's floats are doubles, and widening quiets a signalling
		// NaN (garbage header fields have some), so every NaN prints alike.
		d.w(" nan")
		return
	}
	d.w(" %08x", math.Float32bits(x))
}
func (d *dumper) i(x int64)  { d.w(" %d", x) }
func (d *dumper) s(x string) { d.w(" %d:%s", utf8.RuneCountInString(x), x) }
func (d *dumper) nl()        { d.b.WriteByte('\n') }
func (d *dumper) v3(v Vec3) {
	for _, x := range v {
		d.f(x)
	}
}
func (d *dumper) m4(m Mat4) {
	for _, x := range m {
		d.f(x)
	}
}

func (d *dumper) value(v Value) {
	if v == nil {
		d.w(" -")
		return
	}
	d.w(" %s", v.TypeName())
	switch x := v.(type) {
	case Float:
		d.f(float32(x))
	case Vector:
		d.v3(Vec3(x))
	case Matrix:
		d.m4(Mat4(x))
	case AxisVector4:
		for _, a := range x.Axis {
			d.f(a)
		}
		d.m4(x.Matrix)
	case RotVector:
		d.v3(x.Rot)
		d.m4(x.Matrix)
	case AngleVector1:
		d.v3(x.A)
		d.v3(x.B)
	case StaticEmit:
		d.i(int64(x.Delay))
		d.i(int64(x.Duration))
		d.i(int64(x.Interval))
		d.i(int64(x.MaxLive))
		d.f(x.PerTrigger)
	case FrameScale:
		d.i(int64(len(x)))
		for _, s := range x {
			d.v3(s)
		}
	case FrameDiffuse:
		d.i(int64(len(x)))
		for _, c := range x {
			d.i(int64(c))
		}
	case FrameBANRotation:
		d.f(x.Head)
		d.i(int64(len(x.Matrices)))
		for _, m := range x.Matrices {
			d.m4(m)
		}
	case FrameBANPosition:
		d.f(x.Head)
		d.i(int64(len(x.Positions)))
		for _, p := range x.Positions {
			d.v3(p)
		}
	case BSAnimation:
		d.i(int64(len(x)))
		for _, s := range x {
			d.s(s)
		}
	case FrameTextureSlide:
		d.v3(x.Head)
		d.i(int64(len(x.Keys)))
		for _, k := range x.Keys {
			for _, f := range k {
				d.f(f)
			}
		}
	case BlendScaleGraph:
		d.f(x.A)
		d.f(x.B)
		d.i(int64(len(x.Keys)))
		for _, k := range x.Keys {
			d.f(k.Time)
			d.v3(k.Scale)
		}
	case BlendScaleGraphPointer:
		d.i(int64(x))
	case BlendDiffuseGraph:
		d.diffuse(x)
	}
}

func (d *dumper) diffuse(x BlendDiffuseGraph) {
	d.f(x.A)
	d.f(x.B)
	d.i(int64(len(x.Keys)))
	for _, k := range x.Keys {
		d.f(k.Time)
		d.i(int64(k.Color))
	}
}

func (d *dumper) command(tag string, c *Command) {
	d.w("%s", tag)
	if c == nil {
		d.w(" -")
		d.nl()
		return
	}
	d.s(c.Name)
	d.i(int64(c.Space))
	d.i(int64(c.TimeFlags))
	d.f(c.Start)
	d.f(c.Step)
	d.f(c.End)
	// The command's range over the node's frames, so the two readers'
	// timing arithmetic (single precision, _ftol) is compared too.
	s, e, st, ok := c.FrameRange(d.frames)
	d.w(" r%d..%d", s, e)
	d.f(st)
	d.w(" %v k%d", ok, c.Keys(d.frames))
	d.value(c.Value)
	d.nl()
}

func (d *dumper) list(tag string, cs []Command) {
	d.w("%s %d", tag, len(cs))
	d.nl()
	for i := range cs {
		d.command("c", &cs[i])
	}
}

func (d *dumper) state(s RenderState) {
	d.w("R")
	for _, v := range []uint32{s.Cull, s.SrcBlend, s.DestBlend, s.ColorArg1, s.ColorArg2,
		s.ColorOp, s.AlphaArg1, s.AlphaArg2, s.AlphaOp} {
		d.i(int64(v))
	}
	d.nl()
}

func (d *dumper) meshes(ms []MeshRef) {
	d.w("M %d", len(ms))
	d.nl()
	for _, m := range ms {
		d.w("m")
		d.s(m.Mesh)
		d.i(int64(len(m.Textures)))
		for _, t := range m.Textures {
			d.s(t)
		}
		d.nl()
	}
}

func (d *dumper) keyGraph(times []float32, vals []float64, a, b float32, isByte bool) {
	d.f(a)
	d.f(b)
	d.i(int64(len(times)))
	for i := range times {
		d.f(times[i])
		if isByte {
			d.i(int64(vals[i]))
		} else {
			d.f(float32(vals[i]))
		}
	}
}

func (d *dumper) controller(c *Controller) {
	d.w("C")
	d.s(c.Key)
	switch c.Key {
	case "StaticEmit":
		d.value(*c.Emit)
	case "LinkMode":
		for _, v := range c.Link {
			d.i(int64(v))
		}
	case "BAN":
		d.i(int64(len(c.BAN)))
		for _, s := range c.BAN {
			d.s(s)
		}
	case "ViewMode":
		d.s(c.View)
	case "Shape":
		d.s(c.Render)
		d.nl()
		d.state(c.State)
		d.meshes(c.Meshes)
		return
	case "ScaleGraph":
		for _, g := range c.Scale {
			ts := make([]float32, len(g.Keys))
			vs := make([]float64, len(g.Keys))
			for i, k := range g.Keys {
				ts[i], vs[i] = k.Time, float64(k.Value)
			}
			d.keyGraph(ts, vs, g.A, g.B, false)
		}
		d.i(int64(c.ScaleTail1))
		d.f(c.ScaleTail2)
	case "DiffuseGraph":
		ts := make([]float32, len(c.Alpha.Keys))
		vs := make([]float64, len(c.Alpha.Keys))
		for i, k := range c.Alpha.Keys {
			ts[i], vs[i] = k.Time, float64(k.Value)
		}
		d.keyGraph(ts, vs, c.Alpha.A, c.Alpha.B, true)
		d.diffuse(c.Color)
	case "Program":
		d.nl()
		d.list("P", c.Program)
		return
	}
	d.nl()
}

func (d *dumper) node(n *Node) {
	d.frames = int(n.Frames)
	d.w("N %d", n.HeadLen)
	d.s(n.Name)
	d.w(" %d", len(n.Controllers))
	d.nl()
	for i := range n.Controllers {
		d.controller(&n.Controllers[i])
	}
	d.w("B %d %d", n.Frames, len(n.Vars))
	d.nl()
	for _, v := range n.Vars {
		d.w("A")
		d.s(v.Type)
		d.value(v.Value)
		d.nl()
	}
	d.list("L90", n.List90)
	d.list("Lb4", n.Emit)
	d.list("Ld8", n.ListD8)
	d.command("X", n.Extinct)
	d.list("L130", n.Update)
	f := n.Flags
	d.w("F %d %d %d %d %d %d %d %d", f.B0, f.B1, f.U2, f.U3, f.U4, f.B5, f.U6, f.B7)
	d.nl()
	d.command("V", n.View)
	d.state(n.State)
	d.meshes(n.Meshes)
	d.command("D", n.Render)
	d.list("L20c", n.List20C)
	d.list("L234", n.Commands)
	d.w("K %d", len(n.Children))
	d.nl()
	for _, k := range n.Children {
		d.node(k)
	}
}

// Dump returns the canonical text of a decoded file.
func Dump(f *File) string {
	var d dumper
	d.w("V")
	d.s(f.Version)
	d.f(f.Header0012)
	for _, h := range f.Header0013 {
		d.i(int64(h))
	}
	d.i(int64(f.Trailing))
	d.nl()
	d.node(f.Root)
	return d.b.String()
}
