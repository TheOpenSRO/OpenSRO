// Package navmesh is the server's copy of the game's walkable surface: a
// region's terrain navigation mesh (.nvm) and the navigation meshes of the
// objects it lists, walked the way the client walks them
// (client/scripts/nav/nav_graph.gd, whose rules are READ from sro_client.exe
// and the server's twins in SR_GameServer.exe; docs/protocol/
// NAVMESH_MOVEMENT.md). Round 812: the original server steps every mover on
// its own navigation mesh (docs/protocol/opcodes/movement.md); OpenSRO had no
// geometry on the server at all.
//
// The data is the user's own: cmd/export-navmesh copies it out of their
// Data.pk2 / Map.pk2 into a directory the server is pointed at
// (-navmesh-dir). Nothing of it is committed.
package navmesh

import (
	"encoding/binary"
	"errors"
	"fmt"
	"math"
)

// NVM is the real .nvm magic (a space before 1000).
const NVM = "JMXVNVM 1000"

const (
	TileMapSide   = 96
	TileCount     = TileMapSide * TileMapSide
	HeightMapSide = 97
	HeightCount   = HeightMapSide * HeightMapSide
	PlaneMapSide  = 6
	PlaneCount    = PlaneMapSide * PlaneMapSide
	// TileSize is the height grid's spacing and a region's tile, 1920 / 96.
	TileSize = 20.0
	// RegionSpan is a region's width in local units.
	RegionSpan = 1920.0
)

// LinkedEdge joins one object's edge to another object's (bridge spans).
type LinkedEdge struct {
	OtherObject, OtherEdge, Edge int16
}

// MapObject is one placed object the region's navigation mesh lists.
type MapObject struct {
	ResourceID uint32
	X, Y, Z    float32
	Static     int16
	Yaw        float32
	UID        uint16
	Big        bool
	Struct     bool
	RegionID   uint16
	Links      []LinkedEdge
}

// Cell is one terrain cell: an axis-aligned rectangle and the objects over it.
type Cell struct {
	MinX, MinZ, MaxX, MaxZ float32
	Objects                []uint16
}

// Edge is one terrain edge. RegionFrom/To are -1 on an internal edge.
type Edge struct {
	AX, AZ, BX, BZ       float32
	Flags                uint8
	DirFrom, DirTo       int8
	CellFrom, CellTo     int16
	RegionFrom, RegionTo int32
}

// Blocking is NvmCollision.is_blocking: flag bits 0 or 1.
func (e Edge) Blocking() bool { return e.Flags&3 != 0 }

// Tile is one of the 96 x 96 tiles: the cell over it, flags, texture.
type Tile struct {
	Cell    int32
	Flags   uint16
	Texture uint16
}

// Region is a parsed .nvm (NvmReader.ParsedRegion).
type Region struct {
	Objects       []MapObject
	WalkableCells uint32
	Cells         []Cell
	GlobalEdges   []Edge
	InternalEdges []Edge
	Tiles         []Tile
	Heights       []float32
	PlaneTypes    []byte
	PlaneHeights  []float32
}

var errTrunc = errors.New("nvm: truncated")

// ParseNVM reads a .nvm file; every count is self-describing and the read
// must land on the file's end (NvmReader.parse).
func ParseNVM(data []byte) (*Region, error) {
	if len(data) < len(NVM)+2 || string(data[:len(NVM)]) != NVM {
		return nil, fmt.Errorf("nvm: bad magic")
	}
	le := binary.LittleEndian
	f32 := func(o int) float32 { return math.Float32frombits(le.Uint32(data[o:])) }
	r := &Region{}
	off := len(NVM)
	nObj := int(le.Uint16(data[off:]))
	off += 2
	r.Objects = make([]MapObject, 0, nObj)
	for i := 0; i < nObj; i++ {
		if off+32 > len(data) {
			return nil, errTrunc
		}
		o := MapObject{
			ResourceID: le.Uint32(data[off:]),
			X:          f32(off + 4), Y: f32(off + 8), Z: f32(off + 12),
			Static: int16(le.Uint16(data[off+16:])),
			Yaw:    f32(off + 18),
			UID:    le.Uint16(data[off+22:]),
			Big:    data[off+26] != 0, Struct: data[off+27] != 0,
			RegionID: le.Uint16(data[off+28:]),
		}
		off += 30
		nl := int(le.Uint16(data[off:]))
		off += 2
		if off+6*nl > len(data) {
			return nil, errTrunc
		}
		for j := 0; j < nl; j++ {
			o.Links = append(o.Links, LinkedEdge{int16(le.Uint16(data[off:])), int16(le.Uint16(data[off+2:])), int16(le.Uint16(data[off+4:]))})
			off += 6
		}
		r.Objects = append(r.Objects, o)
	}
	if off+8 > len(data) {
		return nil, errTrunc
	}
	nCell := int(le.Uint32(data[off:]))
	r.WalkableCells = le.Uint32(data[off+4:])
	off += 8
	if nCell > len(data) {
		return nil, errTrunc
	}
	r.Cells = make([]Cell, nCell)
	for i := 0; i < nCell; i++ {
		if off+17 > len(data) {
			return nil, errTrunc
		}
		c := Cell{MinX: f32(off), MinZ: f32(off + 4), MaxX: f32(off + 8), MaxZ: f32(off + 12)}
		n := int(data[off+16])
		off += 17
		if off+2*n > len(data) {
			return nil, errTrunc
		}
		if n > 0 {
			c.Objects = make([]uint16, n)
			for j := 0; j < n; j++ {
				c.Objects[j] = le.Uint16(data[off:])
				off += 2
			}
		}
		r.Cells[i] = c
	}
	var err error
	if r.GlobalEdges, off, err = parseEdges(data, off, true); err != nil {
		return nil, err
	}
	if r.InternalEdges, off, err = parseEdges(data, off, false); err != nil {
		return nil, err
	}
	if off+TileCount*8 > len(data) {
		return nil, errTrunc
	}
	r.Tiles = make([]Tile, TileCount)
	for i := range r.Tiles {
		r.Tiles[i] = Tile{int32(le.Uint32(data[off:])), le.Uint16(data[off+4:]), le.Uint16(data[off+6:])}
		off += 8
	}
	if off+HeightCount*4 > len(data) {
		return nil, errTrunc
	}
	r.Heights = make([]float32, HeightCount)
	for i := range r.Heights {
		r.Heights[i] = f32(off)
		off += 4
	}
	if off+PlaneCount*5 > len(data) {
		return nil, errTrunc
	}
	r.PlaneTypes = append([]byte(nil), data[off:off+PlaneCount]...)
	off += PlaneCount
	r.PlaneHeights = make([]float32, PlaneCount)
	for i := range r.PlaneHeights {
		r.PlaneHeights[i] = f32(off)
		off += 4
	}
	if off != len(data) {
		return nil, fmt.Errorf("nvm: parsed %d bytes of %d", off, len(data))
	}
	return r, nil
}

func parseEdges(data []byte, off int, global bool) ([]Edge, int, error) {
	if off+4 > len(data) {
		return nil, off, errTrunc
	}
	le := binary.LittleEndian
	f32 := func(o int) float32 { return math.Float32frombits(le.Uint32(data[o:])) }
	n := int(le.Uint32(data[off:]))
	off += 4
	size := 23
	if global {
		size = 27
	}
	if n < 0 || off+n*size > len(data) {
		return nil, off, errTrunc
	}
	out := make([]Edge, n)
	for i := 0; i < n; i++ {
		e := Edge{AX: f32(off), AZ: f32(off + 4), BX: f32(off + 8), BZ: f32(off + 12),
			Flags: data[off+16], DirFrom: int8(data[off+17]), DirTo: int8(data[off+18]),
			CellFrom: int16(le.Uint16(data[off+19:])), CellTo: int16(le.Uint16(data[off+21:])),
			RegionFrom: -1, RegionTo: -1}
		if global {
			e.RegionFrom = int32(le.Uint16(data[off+23:]))
			e.RegionTo = int32(le.Uint16(data[off+25:]))
		}
		out[i] = e
		off += size
	}
	return out, off, nil
}

// SampleHeight is NvmCollision.sample_height: the height grid bilinearly
// interpolated, clamped to the region.
func (r *Region) SampleHeight(x, z float64) float64 {
	if len(r.Heights) < HeightCount {
		return 0
	}
	last := float64(HeightMapSide - 1)
	fx := clamp(x/TileSize, 0, last)
	fz := clamp(z/TileSize, 0, last)
	c0, r0 := int(math.Floor(fx)), int(math.Floor(fz))
	c1, r1 := min(c0+1, HeightMapSide-1), min(r0+1, HeightMapSide-1)
	tx, tz := fx-float64(c0), fz-float64(r0)
	h := func(row, col int) float64 { return float64(r.Heights[row*HeightMapSide+col]) }
	a := lerp(h(r0, c0), h(r0, c1), tx)
	b := lerp(h(r1, c0), h(r1, c1), tx)
	return lerp(a, b, tz)
}

// SolidPlaneHeight is NvmCollision.solid_plane_height: a plane block with
// type bit 2 (ice, a frozen lake) is a floor; NaN elsewhere.
func (r *Region) SolidPlaneHeight(x, z float64) float64 {
	if len(r.PlaneTypes) < PlaneCount || len(r.PlaneHeights) < PlaneCount {
		return math.NaN()
	}
	tx := int(clamp(math.Floor(x/TileSize), 0, TileMapSide-1))
	tz := int(clamp(math.Floor(z/TileSize), 0, TileMapSide-1))
	i := (tz>>4)*PlaneMapSide + (tx >> 4)
	if r.PlaneTypes[i]&2 == 0 {
		return math.NaN()
	}
	return float64(r.PlaneHeights[i])
}

// TerrainHeight is NvmCollision.terrain_height: the height grid, or a solid
// plane above it.
func (r *Region) TerrainHeight(x, z float64) float64 {
	h := r.SampleHeight(x, z)
	if p := r.SolidPlaneHeight(x, z); !math.IsNaN(p) && p > h {
		return p
	}
	return h
}

func clamp(v, lo, hi float64) float64 { return math.Max(lo, math.Min(hi, v)) }
func lerp(a, b, t float64) float64    { return a + (b-a)*t }
