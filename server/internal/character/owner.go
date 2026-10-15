package character

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/txn"
)

// OwnerStore finds a character by name, online or not (round 788): the GM
// console's /block and /blockinfo name a character to reach its account.
// Both MemStore and SQLStore implement it.
type OwnerStore interface {
	// ByName returns the character named name, compared without case (names
	// are unique without case, sqlstore.go's characters_name_lower), a
	// character pending deletion included. ErrNotFound when none.
	ByName(ctx context.Context, name string) (*Character, error)
}

// ByName implements OwnerStore.
func (m *MemStore) ByName(_ context.Context, name string) (*Character, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for _, c := range m.byID {
		if strings.EqualFold(c.Name, name) {
			cp := *c
			return &cp, nil
		}
	}
	return nil, ErrNotFound
}

// ByName implements OwnerStore: the id, the account and the name as stored
// (the rest of the row is GetByID's).
func (s *SQLStore) ByName(ctx context.Context, name string) (*Character, error) {
	var c Character
	err := txn.Conn(ctx, s.db).QueryRowContext(ctx,
		`SELECT id, account_id, name FROM characters WHERE LOWER(name) = LOWER($1)`, name).Scan(&c.ID, &c.AccountID, &c.Name)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("character: looking up %q: %w", name, err)
	}
	return &c, nil
}
