package navmesh

import (
	"encoding/binary"
	"fmt"
	"math"
	"strings"
)

// The .bms collision section (BmsReader.parse_collision, round 505+; the
// client's RTNavMeshObj::FUN_004489b0 deserializes it).
const (
	bmsMagic           = "JMXVBMS 0110"
	bmsPreambleEnd     = 0x48
	collisionPtrOffset = 0x28
	collisionFlagsOff  = 0x38
	flagWideEdge       = 0x1
	flagWideCell       = 0x2
	flagHasEvents      = 0x4
	collisionVertexRec = 13
	// NoCell is the "no cell on this side" sentinel.
	NoCell = 0xFFFF
)

// CVertex is one collision vertex in the object's own space.
type CVertex struct{ X, Y, Z float32 }

// CCell is one collision triangle.
type CCell struct{ A, B, C uint16 }

// CEdge is one collision edge.
type CEdge struct {
	V0, V1           uint16
	CellFrom, CellTo uint16
	Flags            uint8
}

// CollisionMesh is an object's own navigation mesh.
type CollisionMesh struct {
	Vertices []CVertex
	Cells    []CCell
	Outline  []CEdge
	Internal []CEdge
	Events   []string
}

// ParseCollision reads the collision section a .bms may carry; nil, nil
// when it has none (the common case).
func ParseCollision(data []byte) (*CollisionMesh, error) {
	if len(data) < bmsPreambleEnd || string(data[:len(bmsMagic)]) != bmsMagic {
		return nil, nil
	}
	le := binary.LittleEndian
	start := int(le.Uint32(data[collisionPtrOffset:]))
	if start == 0 {
		return nil, nil
	}
	if start < bmsPreambleEnd || start >= len(data) {
		return nil, fmt.Errorf("bms: collision offset %d out of range", start)
	}
	flags := le.Uint32(data[collisionFlagsOff:])
	cellRec, edgeRec := 8, 9
	if flags&flagWideCell != 0 {
		cellRec = 9
	}
	if flags&flagWideEdge != 0 {
		edgeRec = 10
	}
	f32 := func(o int) float32 { return math.Float32frombits(le.Uint32(data[o:])) }
	cm := &CollisionMesh{}
	off := start
	need := func(n int) error {
		if n < 0 || off+n > len(data) {
			return errTrunc
		}
		return nil
	}
	if err := need(4); err != nil {
		return nil, err
	}
	nv := int(le.Uint32(data[off:]))
	off += 4
	if err := need(nv * collisionVertexRec); err != nil {
		return nil, err
	}
	cm.Vertices = make([]CVertex, nv)
	for i := range cm.Vertices {
		o := off + i*collisionVertexRec
		cm.Vertices[i] = CVertex{f32(o), f32(o + 4), f32(o + 8)}
	}
	off += nv * collisionVertexRec
	if err := need(4); err != nil {
		return nil, err
	}
	nc := int(le.Uint32(data[off:]))
	off += 4
	if err := need(nc * cellRec); err != nil {
		return nil, err
	}
	cm.Cells = make([]CCell, nc)
	for i := range cm.Cells {
		o := off + i*cellRec
		c := CCell{le.Uint16(data[o:]), le.Uint16(data[o+2:]), le.Uint16(data[o+4:])}
		if int(c.A) >= nv || int(c.B) >= nv || int(c.C) >= nv {
			return nil, fmt.Errorf("bms: collision cell %d indexes past the vertices", i)
		}
		cm.Cells[i] = c
	}
	off += nc * cellRec
	for list := 0; list < 2; list++ {
		if err := need(4); err != nil {
			return nil, err
		}
		ne := int(le.Uint32(data[off:]))
		off += 4
		if err := need(ne * edgeRec); err != nil {
			return nil, err
		}
		edges := make([]CEdge, ne)
		for i := range edges {
			o := off + i*edgeRec
			edges[i] = CEdge{le.Uint16(data[o:]), le.Uint16(data[o+2:]), le.Uint16(data[o+4:]), le.Uint16(data[o+6:]), data[o+8]}
		}
		off += ne * edgeRec
		if list == 0 {
			cm.Outline = edges
		} else {
			cm.Internal = edges
		}
	}
	if flags&flagHasEvents != 0 {
		if err := need(4); err != nil {
			return nil, err
		}
		n := int(le.Uint32(data[off:]))
		off += 4
		for i := 0; i < n; i++ {
			if err := need(4); err != nil {
				return nil, err
			}
			l := int(le.Uint32(data[off:]))
			off += 4
			if err := need(l); err != nil {
				return nil, err
			}
			cm.Events = append(cm.Events, string(data[off:off+l]))
			off += l
		}
	}
	// The lookup grid: read only so the section lands on the file's end.
	if err := need(20); err != nil {
		return nil, err
	}
	w, h, total := le.Uint32(data[off+8:]), le.Uint32(data[off+12:]), le.Uint32(data[off+16:])
	off += 20
	if uint64(total) != uint64(w)*uint64(h) {
		return nil, fmt.Errorf("bms: collision grid %d is not %dx%d", total, w, h)
	}
	for i := uint32(0); i < total; i++ {
		if err := need(4); err != nil {
			return nil, err
		}
		n := int(le.Uint32(data[off:]))
		off += 4
		if err := need(2 * n); err != nil {
			return nil, err
		}
		off += 2 * n
	}
	if off != len(data) {
		return nil, fmt.Errorf("bms: collision section parsed %d of %d bytes", off, len(data))
	}
	return cm, nil
}

// NavmeshPathOfBSR is NavObjectSource.navmesh_path_of_bsr (READ, round 644:
// MapLoader::FUN_0042c4a0 reads the .bsr header word 0x28, seeks there and
// reads one length-prefixed path): "" when there is none.
func NavmeshPathOfBSR(data []byte) string {
	if len(data) < 0x2C {
		return ""
	}
	le := binary.LittleEndian
	at := int(le.Uint32(data[0x28:]))
	if at == 0 || at+4 > len(data) {
		return ""
	}
	n := int(le.Uint32(data[at:]))
	if n == 0 || n > 1024 || at+4+n > len(data) {
		return ""
	}
	return string(data[at+4 : at+4+n])
}

// CollisionPath is which mesh an object index path's navigation mesh comes
// from (NavObjectSource.load_collision, READ round 644, FUN_0042ce60): a
// .bms itself; a .bsr's header-named mesh (bsr is that file's bytes); a .cpd
// none (OPEN, as in the client).
func CollisionPath(path string, bsr func(string) []byte) string {
	l := strings.ToLower(path)
	switch {
	case strings.HasSuffix(l, "s"):
		return path
	case strings.HasSuffix(l, "r"):
		if data := bsr(path); data != nil {
			return NavmeshPathOfBSR(data)
		}
	}
	return ""
}
