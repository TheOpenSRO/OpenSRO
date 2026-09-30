package combat

import (
	"math"

	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// The hub's region-cell index (round 656): every live monster is filed under
// its zone and the region cell its X/Z falls in, so a question about one part
// of the world -- which monsters a player can see, which lie near a monster
// struck -- reads the cells around that point instead of every monster alive.
// round 657+ places every field row of npcpos (10,195 monsters, docs/TODO.md);
// before this, InZone and All walked all of them for every list, every tick
// and every aggro scan.
//
// A cell is one region of the world frame the zone's coordinates are named
// in: worldmap.RegionSpan (1920, READ: a region's mesh is 97 vertices at
// TILE_SIZE) on a side, with the frame's centre region's middle at the
// origin (worldmap.ToWorld), so the cell lines are the region lines, at
// 960 + k x 1920 on both axes. The cell's numbers are frame-relative, not
// the region's own x/y: (0, 0) is the frame's centre region. That is all the
// index needs -- two positions in one zone are in one frame -- and it keeps
// the index free of which frame a zone is named in (-single-frame).

// Cell is one region-sized square of a zone's world frame: the hub bucket
// (Monster.Zone) and the cell's column along world X and row along world Z.
type Cell struct {
	Zone string
	X, Z int
}

// CellOf is the cell world point (x, z) of zone falls in. The boundary
// 960 + k x 1920 belongs to the cell above it, on both axes (floor).
func CellOf(zone string, x, z float64) Cell {
	return Cell{Zone: zone, X: cellCoord(x), Z: cellCoord(z)}
}

func cellCoord(v float64) int {
	return int(math.Floor((v + worldmap.RegionSpan/2) / worldmap.RegionSpan))
}

// Near reports whether other is within radius cells of c on both axes (the
// Chebyshev distance, a square window) and in the same zone.
func (c Cell) Near(other Cell, radius int) bool {
	if c.Zone != other.Zone {
		return false
	}
	dx, dz := c.X-other.X, c.Z-other.Z
	return dx >= -radius && dx <= radius && dz >= -radius && dz <= radius
}

// CellsWithin is how many cells a radius of dist world units can reach past
// the cell a point stands in: ceil(dist / RegionSpan), at least 0. A scan of
// every point within dist of a monster reads the square of that many cells
// around it.
func CellsWithin(dist float64) int {
	if !(dist > 0) {
		return 0
	}
	return int(math.Ceil(dist / worldmap.RegionSpan))
}

// CellChange is a monster whose cell changed in a step: StepCells reports one
// for each monster whose move carried it over a region line.
type CellChange struct {
	ID       int64
	From, To Cell
}

// cellSet is one cell's monsters, by id.
type cellSet map[int64]*Monster

// fileLocked puts m in the index under cell c. Called with h.mu held.
func (h *Hub) fileLocked(m *Monster, c Cell) {
	set := h.cells[c]
	if set == nil {
		set = cellSet{}
		h.cells[c] = set
		zc := h.zoneCells[c.Zone]
		if zc == nil {
			zc = map[Cell]struct{}{}
			h.zoneCells[c.Zone] = zc
		}
		zc[c] = struct{}{}
	}
	set[m.ID] = m
	h.cellOf[m.ID] = c
}

// unfileLocked takes monster id out of the index. Called with h.mu held.
func (h *Hub) unfileLocked(id int64) {
	c, ok := h.cellOf[id]
	if !ok {
		return
	}
	delete(h.cellOf, id)
	set := h.cells[c]
	delete(set, id)
	if len(set) == 0 {
		delete(h.cells, c)
		if zc := h.zoneCells[c.Zone]; zc != nil {
			delete(zc, c)
			if len(zc) == 0 {
				delete(h.zoneCells, c.Zone)
			}
		}
	}
}

// refileLocked moves m to the cell its position is in now, reporting the
// change when there was one. Called with h.mu held.
func (h *Hub) refileLocked(m *Monster) (CellChange, bool) {
	from := h.cellOf[m.ID]
	to := CellOf(m.Zone, m.X, m.Z)
	if from == to {
		return CellChange{}, false
	}
	h.unfileLocked(m.ID)
	h.fileLocked(m, to)
	return CellChange{ID: m.ID, From: from, To: to}, true
}

// CellOfMonster is the cell monster id is filed under, and whether it is
// alive.
func (h *Hub) CellOfMonster(id int64) (Cell, bool) {
	h.mu.RLock()
	defer h.mu.RUnlock()
	c, ok := h.cellOf[id]
	return c, ok
}

// Exists reports whether monster id is alive, without copying it.
func (h *Hub) Exists(id int64) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.byID[id]
	return ok
}

// Count is how many monsters are alive.
func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.byID)
}

// Facing is the way monster id faces now, in radians from +x toward +z: the
// heading it hatched with (Monster.Heading) until its first leg, then each
// leg's direction (SetMotion) -- what a monster AI brain keeps as its heading.
// A client that meets a standing monster for the first time (the area of
// interest's enter push, session/aoi.go) turns it this way. 0 for a monster
// that is gone.
func (h *Hub) Facing(id int64) float64 {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return h.facing[id]
}

// InWindow returns a copy of every live monster in the cells within radius of
// centre (Cell.Near), appended to dst. The order is the index's, not an id
// order; a caller that needs one sorts.
func (h *Hub) InWindow(dst []Monster, centre Cell, radius int) []Monster {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for x := centre.X - radius; x <= centre.X+radius; x++ {
		for z := centre.Z - radius; z <= centre.Z+radius; z++ {
			for _, m := range h.cells[Cell{Zone: centre.Zone, X: x, Z: z}] {
				dst = append(dst, *m)
			}
		}
	}
	return dst
}

// InCells returns a copy of every live monster filed under one of cells,
// appended to dst, in the order cells names them. A cell named twice is read
// twice.
func (h *Hub) InCells(dst []Monster, cells []Cell) []Monster {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range cells {
		for _, m := range h.cells[c] {
			dst = append(dst, *m)
		}
	}
	return dst
}

// IDsInCells returns the ids of every live monster filed under one of cells,
// appended to dst.
func (h *Hub) IDsInCells(dst []int64, cells []Cell) []int64 {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, c := range cells {
		for id := range h.cells[c] {
			dst = append(dst, id)
		}
	}
	return dst
}

// AppendAll returns a copy of every live monster appended to dst -- All
// without the allocation, for a caller that keeps its buffer between calls.
func (h *Hub) AppendAll(dst []Monster) []Monster {
	h.mu.RLock()
	defer h.mu.RUnlock()
	for _, m := range h.byID {
		dst = append(dst, *m)
	}
	return dst
}
