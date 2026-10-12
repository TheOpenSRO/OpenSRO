package session

// The rows behind the active buff records (round 785): the imbue, the
// periodic records and the links need the row of a record that is running,
// and a buff.Record carries only its skill id. Every start through
// startCasterBuffOn (and the monster books) files the row by owner and skill
// id; the rows are refdata's shared pointers, so the map holds no copies.

import (
	"sync"

	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

var activeRows = struct {
	sync.Mutex
	byOwner map[rowOwner]map[int64]*refdata.Skill
}{byOwner: map[rowOwner]map[int64]*refdata.Skill{}}

// rowOwner keys a book: characters and monsters have overlapping ids.
type rowOwner struct {
	monster bool
	id      int64
}

// rememberRow files ref as the row of ownerID's records of ref.ID.
func rememberRow(monster bool, ownerID int64, ref *refdata.Skill) {
	if ref == nil {
		return
	}
	activeRows.Lock()
	defer activeRows.Unlock()
	k := rowOwner{monster, ownerID}
	m := activeRows.byOwner[k]
	if m == nil {
		m = map[int64]*refdata.Skill{}
		activeRows.byOwner[k] = m
	}
	m[ref.ID] = ref
}

// rowOf is the row filed for ownerID's skillID, nil when none was.
func rowOf(monster bool, ownerID, skillID int64) *refdata.Skill {
	activeRows.Lock()
	defer activeRows.Unlock()
	return activeRows.byOwner[rowOwner{monster, ownerID}][skillID]
}

// forgetRows drops an owner's rows (a monster that died, a character that
// left the world).
func forgetRows(monster bool, ownerID int64) {
	activeRows.Lock()
	delete(activeRows.byOwner, rowOwner{monster, ownerID})
	activeRows.Unlock()
}
