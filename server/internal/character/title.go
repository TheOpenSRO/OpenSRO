package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/txn"
)

// TitleStore keeps a character's title (round 838): the engine's
// _CHAR.HwanLevel, the byte its spawn record and character data carry and
// the client turns into the title drawn left of the name (READ, sro_client
// FUN_009ca930 through hwanleveldata.txt), and the text of a custom title
// (OURS, the archive's ITEM_TITLE_255 "Custom Title Scroll").
//
// The engine persists HwanLevel on the character row (_CHAR, charData +0xf2:
// CGObjChar::UpdateHwanLevel 0x004a9f40 -> GObjPC::FUN_004a9e20 sets the
// byte and the row's dirty bit 0x2000). The custom text has no engine
// column: the private server's filter kept it, which no binary here holds.
//
// Kept off Character, as ServiceStore is.
type TitleStore interface {
	// Title returns characterID's hwan level (0 = none) and its custom
	// title's text ("" unless the level is CustomTitleLevel).
	Title(ctx context.Context, characterID int64) (level uint8, custom string, err error)
	// SetTitle stores both; a level other than CustomTitleLevel stores ""
	// for the text.
	SetTitle(ctx context.Context, characterID int64, level uint8, custom string) error
}

// CustomTitleLevel is the hwan level of the custom title (OURS): the
// archive's ITEM_TITLE_255 is the "Custom Title Scroll", and hwanleveldata's
// row 255 names UIO_SECOND_HWAN_CH_NAME_LEVEL_255, whose text is "Custom".
const CustomTitleLevel uint8 = 255

// titleSchema adds the title columns to the characters table (round 838).
const titleSchema = `
ALTER TABLE characters ADD COLUMN IF NOT EXISTS hwan_level SMALLINT NOT NULL DEFAULT 0;
ALTER TABLE characters ADD COLUMN IF NOT EXISTS custom_title TEXT NOT NULL DEFAULT '';
`

// memTitle is one character's MemStore title.
type memTitle struct {
	level  uint8
	custom string
}

// Title implements TitleStore.
func (m *MemStore) Title(_ context.Context, characterID int64) (uint8, string, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if _, ok := m.byID[characterID]; !ok {
		return 0, "", ErrNotFound
	}
	t := m.titles[characterID]
	return t.level, t.custom, nil
}

// SetTitle implements TitleStore.
func (m *MemStore) SetTitle(ctx context.Context, characterID int64, level uint8, custom string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[characterID]; !ok {
		return ErrNotFound
	}
	if level != CustomTitleLevel {
		custom = ""
	}
	if m.titles == nil {
		m.titles = map[int64]memTitle{}
	}
	before, had := m.titles[characterID]
	m.titles[characterID] = memTitle{level: level, custom: custom}
	txn.OnRollback(ctx, func() {
		m.mu.Lock()
		defer m.mu.Unlock()
		if had {
			m.titles[characterID] = before
		} else {
			delete(m.titles, characterID)
		}
	})
	return nil
}

// Title implements TitleStore.
func (s *SQLStore) Title(ctx context.Context, characterID int64) (uint8, string, error) {
	var level int64
	var custom string
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx, `SELECT hwan_level, custom_title FROM characters WHERE id = $1`,
		characterID).Scan(&level, &custom)
	if errors.Is(err, sql.ErrNoRows) {
		return 0, "", ErrNotFound
	}
	if err != nil {
		return 0, "", fmt.Errorf("character: reading the title: %w", err)
	}
	return uint8(level), custom, nil
}

// SetTitle implements TitleStore.
func (s *SQLStore) SetTitle(ctx context.Context, characterID int64, level uint8, custom string) error {
	if level != CustomTitleLevel {
		custom = ""
	}
	return s.serviceUpdate(ctx, `UPDATE characters SET hwan_level = $1, custom_title = $2 WHERE id = $3`,
		int64(level), custom, characterID)
}
