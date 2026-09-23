package guild

import (
	"context"
	"sort"
	"strings"
	"sync"
)

// MemStore is an in-memory Store, for tests and for running the server
// without a database (see cmd/server's -in-memory). Nothing is persisted.
type MemStore struct {
	mu      sync.RWMutex
	byID    map[int64]*Guild
	ofChar  map[int64]int64  // characterID -> guildID
	names   map[string]int64 // lowercased name -> guildID
	nextID  int64
	joinSeq map[int64]int64 // characterID -> join order, for leader succession
	seq     int64
}

// NewMemStore returns an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{
		byID:    make(map[int64]*Guild),
		ofChar:  make(map[int64]int64),
		names:   make(map[string]int64),
		joinSeq: make(map[int64]int64),
	}
}

func (m *MemStore) copy(g *Guild) *Guild {
	out := *g
	out.Members = append([]Member(nil), g.Members...)
	// Leader first, then join order, so a roster reads the same way the
	// SQL store's ORDER BY does.
	sort.SliceStable(out.Members, func(i, j int) bool {
		if (out.Members[i].Role == RoleLeader) != (out.Members[j].Role == RoleLeader) {
			return out.Members[i].Role == RoleLeader
		}
		return m.joinSeq[out.Members[i].CharacterID] < m.joinSeq[out.Members[j].CharacterID]
	})
	return &out
}

// Create implements Store.
func (m *MemStore) Create(_ context.Context, name string, leaderID int64, leaderName string) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// The engine's order (see Store.Create): membership, then name length,
	// then uniqueness.
	if _, in := m.ofChar[leaderID]; in {
		return nil, ErrAlreadyInGuild
	}
	if !ValidName(name) {
		return nil, ErrInvalidNameLength
	}
	key := strings.ToLower(name)
	if _, taken := m.names[key]; taken {
		return nil, ErrNameTaken
	}

	m.nextID++
	m.seq++
	g := &Guild{
		ID: m.nextID, Name: name, LeaderID: leaderID,
		Members: []Member{{CharacterID: leaderID, Name: leaderName, Role: RoleLeader}},
	}
	m.byID[g.ID] = g
	m.names[key] = g.ID
	m.ofChar[leaderID] = g.ID
	m.joinSeq[leaderID] = m.seq
	return m.copy(g), nil
}

// Join implements Store.
func (m *MemStore) Join(_ context.Context, guildID, characterID int64, characterName string) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	g := m.byID[guildID]
	if g == nil {
		return nil, ErrGuildNotFound
	}
	if _, in := m.ofChar[characterID]; in {
		return nil, ErrAlreadyInGuild
	}
	if len(g.Members) >= MaxMembers {
		return nil, ErrGuildFull
	}
	m.seq++
	g.Members = append(g.Members, Member{CharacterID: characterID, Name: characterName, Role: RoleMember})
	m.ofChar[characterID] = guildID
	m.joinSeq[characterID] = m.seq
	return m.copy(g), nil
}

// Leave implements Store.
func (m *MemStore) Leave(_ context.Context, characterID int64) (int64, *Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	guildID, in := m.ofChar[characterID]
	if !in {
		return 0, nil, ErrNotInGuild
	}
	g := m.byID[guildID]
	delete(m.ofChar, characterID)
	delete(m.joinSeq, characterID)

	kept := g.Members[:0]
	for _, member := range g.Members {
		if member.CharacterID != characterID {
			kept = append(kept, member)
		}
	}
	g.Members = kept

	if len(g.Members) == 0 {
		delete(m.byID, guildID)
		delete(m.names, strings.ToLower(g.Name))
		return guildID, nil, nil
	}

	// Leadership passes to the longest-standing remaining member.
	if g.LeaderID == characterID {
		successor := 0
		for i := range g.Members {
			if m.joinSeq[g.Members[i].CharacterID] < m.joinSeq[g.Members[successor].CharacterID] {
				successor = i
			}
		}
		for i := range g.Members {
			g.Members[i].Role = RoleMember
		}
		g.Members[successor].Role = RoleLeader
		g.LeaderID = g.Members[successor].CharacterID
	}
	return guildID, m.copy(g), nil
}

// GetByCharacter implements Store.
func (m *MemStore) GetByCharacter(_ context.Context, characterID int64) (*Guild, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	guildID, in := m.ofChar[characterID]
	if !in {
		return nil, ErrNotInGuild
	}
	return m.copy(m.byID[guildID]), nil
}

// GuildIDOf implements Store.
func (m *MemStore) GuildIDOf(_ context.Context, characterID int64) (int64, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	guildID, in := m.ofChar[characterID]
	if !in {
		return 0, ErrNotInGuild
	}
	return guildID, nil
}

// Get implements Store.
func (m *MemStore) Get(_ context.Context, guildID int64) (*Guild, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	g := m.byID[guildID]
	if g == nil {
		return nil, ErrGuildNotFound
	}
	return m.copy(g), nil
}

// AddPoints implements Store: the guild's GatheredSP and the member's
// GPDonation together, or neither (CGuild::AddPoints, 0x5c4110, touches both
// only once FUN_005d0c90 has found the member).
func (m *MemStore) AddPoints(_ context.Context, guildID, characterID int64, points int) error {
	if points <= 0 {
		return nil
	}
	m.mu.Lock()
	defer m.mu.Unlock()

	g := m.byID[guildID]
	if g == nil {
		return ErrGuildNotFound
	}
	for i := range g.Members {
		if g.Members[i].CharacterID == characterID {
			g.Members[i].GPDonation += int64(points)
			g.GatheredSP += int64(points)
			return nil
		}
	}
	return ErrNotInGuild
}
