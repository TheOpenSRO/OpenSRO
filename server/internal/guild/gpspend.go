package guild

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
)

// Round 844 lane G (part 2): a guild store purchase's GP (READ
// GObjPC::CheckCurrencyRequirement s:0x617360, flag 8 after gold: no guild or
// not the master 0x18c4 UIIT_MSG_GUILD_STORE_BUY_LIMIT, GatheredSP below the
// price 0x18c5 UIIT_MSG_GUILD_LACK_GP; the database's _UPDATE_COST takes
// GatheredSP down and leaves _GuildMember.GP_Donation alone, MEASURED).

var (
	ErrGuildStoreNotMaster = errors.New("guild: only the guild master may buy guild goods")
	ErrGuildStoreLackGP    = errors.New("guild: the guild lacks the GP")
)

// The refusals' codes (category 1, the 0xB034 switch c:0x7b8b40).
const (
	CodeGuildStoreBuyLimit uint16 = 0x18c4
	CodeGuildStoreLackGP   uint16 = 0x18c5
)

// GPSpendStore takes GP for a purchase.
type GPSpendStore interface {
	// SpendPoints takes points from characterID's guild: characterID must
	// be its master (ErrGuildStoreNotMaster; also for no guild) and the
	// guild hold them (ErrGuildStoreLackGP). pay runs under the guild's lock
	// before the points go; its error leaves them. Returns the guild after.
	SpendPoints(ctx context.Context, characterID, points int64, pay func() error) (*Guild, error)
}

// SpendPoints implements GPSpendStore.
func (m *MemStore) SpendPoints(_ context.Context, characterID, points int64, pay func() error) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	gid, in := m.ofChar[characterID]
	if !in {
		return nil, ErrGuildStoreNotMaster
	}
	g := m.byID[gid]
	if g.LeaderID != characterID {
		return nil, ErrGuildStoreNotMaster
	}
	if g.GatheredSP < points {
		return nil, ErrGuildStoreLackGP
	}
	if pay != nil {
		if err := pay(); err != nil {
			return nil, err
		}
	}
	g.GatheredSP -= points
	return m.copy(g), nil
}

// SpendPoints implements GPSpendStore: one transaction with the guild's row
// locked.
func (s *SQLStore) SpendPoints(ctx context.Context, characterID, points int64, pay func() error) (*Guild, error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, fmt.Errorf("guild: beginning transaction: %w", err)
	}
	defer tx.Rollback()
	var gid, leader, gp int64
	err = tx.QueryRowContext(ctx,
		`SELECT g.id, g.leader_id, g.gathered_sp FROM guild_members gm JOIN guilds g ON g.id = gm.guild_id
		 WHERE gm.character_id = $1 FOR UPDATE OF g`, characterID).Scan(&gid, &leader, &gp)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrGuildStoreNotMaster
	}
	if err != nil {
		return nil, fmt.Errorf("guild: looking up membership: %w", err)
	}
	if leader != characterID {
		return nil, ErrGuildStoreNotMaster
	}
	if gp < points {
		return nil, ErrGuildStoreLackGP
	}
	if pay != nil {
		if err := pay(); err != nil {
			return nil, err
		}
	}
	if _, err := tx.ExecContext(ctx, `UPDATE guilds SET gathered_sp = gathered_sp - $1 WHERE id = $2`, points, gid); err != nil {
		return nil, fmt.Errorf("guild: spending GP: %w", err)
	}
	g, err := getGuild(ctx, tx, gid)
	if err != nil {
		return nil, err
	}
	if err := tx.Commit(); err != nil {
		return nil, fmt.Errorf("guild: committing: %w", err)
	}
	return g, nil
}
