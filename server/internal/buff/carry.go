package buff

// A book that travels between processes (round 869 lane W2, OURS,
// docs/protocol/game_worlds.md 12.1): a character moving to a world on
// another process takes its active records, the book's state bits and its
// speed and wall holders with it, and the target puts them back as they were
// -- the same tokens, starts and remaining walls -- so the buff bar, the
// recast rules and the run speed carry on unchanged. Tokens stay unique
// across processes because each process draws them from its own range
// (SeedTokens). The caster-side links a 'lnks' row keeps on another
// character are not carried (OPEN: such a link spans two characters, who may
// be on two processes).

// BookState is one owner's book in transit.
type BookState struct {
	Records     []Record  `json:"records"`
	SpeedHolder uint32    `json:"speed_holder"`
	WallHolder  uint32    `json:"wall_holder"`
	Bits        [4]uint64 `json:"bits"`
	// GMSpeed is the owner's /speed factor (0 none).
	GMSpeed float64 `json:"gm_speed,omitempty"`
}

// SeedTokens starts the token counter at base (a process's own range: its
// tokens never meet another's on a character that moves).
func (b *Books) SeedTokens(base uint32) {
	if b.next.Load() < base {
		b.next.Store(base)
	}
}

// Snapshot is ownerID's book now.
func (b *Books) Snapshot(ownerID int64) BookState {
	b.mu.Lock()
	defer b.mu.Unlock()
	var s BookState
	if bk := b.books[ownerID]; bk != nil {
		s.Records = append([]Record(nil), bk.records...)
		s.SpeedHolder, s.WallHolder, s.Bits = bk.speedHolder, bk.wallHolder, bk.bits
	}
	if g, ok := b.gmSpeed[ownerID]; ok {
		s.GMSpeed = g
	}
	return s
}

// Restore replaces ownerID's book with s and answers its run speed.
func (b *Books) Restore(ownerID int64, s BookState) Speed {
	b.mu.Lock()
	defer b.mu.Unlock()
	before := b.speedLocked(ownerID, b.books[ownerID])
	if len(s.Records) == 0 && s.SpeedHolder == 0 && s.WallHolder == 0 && s.Bits == [4]uint64{} {
		delete(b.books, ownerID)
	} else {
		bk := &book{records: append([]Record(nil), s.Records...), speedHolder: s.SpeedHolder, wallHolder: s.WallHolder,
			bits: s.Bits}
		for i := range bk.records {
			bk.records[i].OwnerID = ownerID
			bk.records[i].LinkSource = false
		}
		b.books[ownerID] = bk
	}
	if s.GMSpeed > 0 && s.GMSpeed != 1 {
		b.gmSpeed[ownerID] = s.GMSpeed
	} else {
		delete(b.gmSpeed, ownerID)
	}
	b.refreshStatsLocked(ownerID, b.books[ownerID])
	after := b.speedLocked(ownerID, b.books[ownerID])
	return Speed{RunSpeed: after, Changed: after != before}
}
