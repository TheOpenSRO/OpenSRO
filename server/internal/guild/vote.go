package guild

import (
	"context"
	"database/sql"
	"fmt"
	"sync"
	"time"
)

// Round 844 lane G (part 2): the master-release vote's rules and the
// members' last logout they are judged by (docs/protocol/guild.md, "The
// master-release vote"). READ unless marked: the GameServer s:0x5c6ac0,
// CVoteManager s:0x5e7f00 / 0x5e7ea0, the ShardManager sm:0x436ea0 (the list)
// and sm:0x461a50 (the count), and the two database procedures recovered as
// text from the shard backup on the render box
// (_Guild_Master_Election_Available, _Guild_Is_Master_Candidators).
const (
	// VoteMasterAbsentDays: a vote may start when the master's last logout
	// is this many days ago or more (READ s:0x4419a7 `push 0x2d`, the
	// procedure's `getdate() - LastLogout >= @days`).
	VoteMasterAbsentDays = 45
	// VoteEligibleDays: an offline member is on the list when its last
	// logout is this many days ago or fewer (READ the procedure's `@minus <=
	// 7`; the client's UIIT_MSG_MRELEASEERR_NOTVOTING says three days -- the
	// procedure is followed, OPEN which one retail ran).
	VoteEligibleDays = 7
	// VoteDuration is the vote's length (READ sm:0x461d94 / s:0x5e7e65
	// `push 0x927c0`).
	VoteDuration = 600000 * time.Millisecond
	// VoteWinPercent: a candidate wins the moment votes*100/n reaches it,
	// n the list's size (READ sm:0x461a50, `fcomp [0x79ae30]` = 60.0).
	VoteWinPercent = 60.0
	// VoteTick is the ShardManager's check (READ `push 0x2710`), and
	// VoteTimeEvery the first remaining-time broadcast's delay.
	VoteTick      = 10 * time.Second
	VoteTimeAfter = 60 * time.Second
)

// VoteWins is sm:0x461a50's test.
func VoteWins(votes, listSize int) bool {
	return listSize > 0 && float64(votes)*100.0/float64(listSize) >= VoteWinPercent
}

// DaysSince is the procedures' day count: the difference of the two dates'
// day numbers (`convert(int, getdate()) - convert(int, LastLogout)`), not
// elapsed 24-hour periods. INFERRED: SQL Server's int conversion of a
// datetime rounds to the nearest day; OpenSRO counts calendar days (UTC).
func DaysSince(then, now time.Time) int {
	a := time.Date(then.UTC().Year(), then.UTC().Month(), then.UTC().Day(), 0, 0, 0, 0, time.UTC)
	b := time.Date(now.UTC().Year(), now.UTC().Month(), now.UTC().Day(), 0, 0, 0, 0, time.UTC)
	return int(b.Sub(a).Hours() / 24)
}

// PresenceStore keeps each member's last logout (_CHAR.LastLogout in the
// original; OpenSRO keeps it on the guild member, OURS).
type PresenceStore interface {
	SetLastLogout(ctx context.Context, characterID int64, at time.Time) error
	// LastLogouts is every member of guildID with a recorded logout.
	LastLogouts(ctx context.Context, guildID int64) (map[int64]time.Time, error)
}

// --- MemStore ---------------------------------------------------------------

var memPresence sync.Map // *MemStore -> *sync.Map(characterID -> time.Time)

func (m *MemStore) presence() *sync.Map {
	v, _ := memPresence.LoadOrStore(m, &sync.Map{})
	return v.(*sync.Map)
}

// SetLastLogout implements PresenceStore.
func (m *MemStore) SetLastLogout(_ context.Context, characterID int64, at time.Time) error {
	m.presence().Store(characterID, at)
	return nil
}

// LastLogouts implements PresenceStore.
func (m *MemStore) LastLogouts(_ context.Context, guildID int64) (map[int64]time.Time, error) {
	m.mu.RLock()
	g := m.byID[guildID]
	var ids []int64
	if g != nil {
		for _, mm := range g.Members {
			ids = append(ids, mm.CharacterID)
		}
	}
	m.mu.RUnlock()
	if g == nil {
		return nil, ErrGuildNotFound
	}
	out := map[int64]time.Time{}
	p := m.presence()
	for _, id := range ids {
		if v, ok := p.Load(id); ok {
			out[id] = v.(time.Time)
		}
	}
	return out, nil
}

// --- SQLStore ---------------------------------------------------------------

// manageSchema is this lane's additive schema (round 844 part 2), created by
// the store itself the first time it is needed: the members' last logout, the
// GP history (gphistory.go).
const manageSchema = `
ALTER TABLE guild_members ADD COLUMN IF NOT EXISTS last_logout TIMESTAMPTZ;
CREATE TABLE IF NOT EXISTS guild_gp_history (
	id         BIGSERIAL PRIMARY KEY,
	guild_id   BIGINT NOT NULL,
	at         TIMESTAMPTZ NOT NULL DEFAULT now(),
	kind       INTEGER NOT NULL,
	amount     BIGINT NOT NULL,
	actor      TEXT NOT NULL DEFAULT '',
	detail     TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS guild_gp_history_guild ON guild_gp_history (guild_id, at DESC);
`

var manageSchemaDone sync.Map // *sql.DB -> error

func ensureManageSchema(ctx context.Context, db *sql.DB) error {
	if v, ok := manageSchemaDone.Load(db); ok && v == nil {
		return nil
	}
	if _, err := db.ExecContext(ctx, manageSchema); err != nil {
		return fmt.Errorf("guild: creating the round 844 schema: %w", err)
	}
	manageSchemaDone.Store(db, nil)
	return nil
}

// SetLastLogout implements PresenceStore.
func (s *SQLStore) SetLastLogout(ctx context.Context, characterID int64, at time.Time) error {
	if err := ensureManageSchema(ctx, s.db); err != nil {
		return err
	}
	_, err := s.db.ExecContext(ctx, `UPDATE guild_members SET last_logout = $1 WHERE character_id = $2`, at, characterID)
	if err != nil {
		return fmt.Errorf("guild: setting last logout: %w", err)
	}
	return nil
}

// LastLogouts implements PresenceStore.
func (s *SQLStore) LastLogouts(ctx context.Context, guildID int64) (map[int64]time.Time, error) {
	if err := ensureManageSchema(ctx, s.db); err != nil {
		return nil, err
	}
	rows, err := s.db.QueryContext(ctx,
		`SELECT character_id, last_logout FROM guild_members WHERE guild_id = $1 AND last_logout IS NOT NULL`, guildID)
	if err != nil {
		return nil, fmt.Errorf("guild: reading last logouts: %w", err)
	}
	defer rows.Close()
	out := map[int64]time.Time{}
	for rows.Next() {
		var id int64
		var at time.Time
		if err := rows.Scan(&id, &at); err != nil {
			return nil, err
		}
		out[id] = at
	}
	return out, rows.Err()
}
