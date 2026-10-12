package combat

// Place puts monster id at (x, z) at once, ending any leg (round 785: a
// skill's knockdown or knockback moves its target -- Combat_ApplyActionEffects
// applies the hit's position through vslot 0x4c4, READ). It returns the
// updated copy, the cell change when the move crossed a cell line, and false
// when the monster is gone.
func (h *Hub) Place(id int64, x, z float64) (Monster, CellChange, bool, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	m, ok := h.byID[id]
	if !ok {
		return Monster{}, CellChange{}, false, false
	}
	m.X, m.Z = x, z
	m.DestX, m.DestZ = x, z
	m.Moving = false
	delete(h.moving, id)
	ch, crossed := h.refileLocked(m)
	return *m, ch, crossed, true
}
