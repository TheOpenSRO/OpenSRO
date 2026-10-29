package guild

import (
	"context"
	"strings"
)

// The MemStore's unions (round 842, union.go).

func copyUnion(u *Union) *Union {
	if u == nil {
		return nil
	}
	out := *u
	return &out
}

// UnionOf implements UnionStore.
func (m *MemStore) UnionOf(_ context.Context, guildID int64) (*Union, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	if id, ok := m.unionOf[guildID]; ok {
		return copyUnion(m.unions[id]), nil
	}
	return nil, nil
}

// JoinUnion implements UnionStore.
func (m *MemStore) JoinUnion(_ context.Context, guildID, hostGuildID int64) (*Union, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.byID[guildID]; !ok {
		return nil, ErrGuildNotFound
	}
	if _, ok := m.byID[hostGuildID]; !ok {
		return nil, ErrGuildNotFound
	}
	if guildID == hostGuildID {
		return nil, ErrUnionSameGuild
	}
	if _, in := m.unionOf[guildID]; in {
		return nil, ErrUnionAlreadyMember
	}
	u := m.unions[m.unionOf[hostGuildID]]
	if u == nil {
		m.nextUnion++
		u = &Union{ID: m.nextUnion}
		u.Slots[0] = hostGuildID
		m.unions[u.ID] = u
		m.unionOf[hostGuildID] = u.ID
	}
	for i := range u.Slots {
		if u.Slots[i] == 0 {
			u.Slots[i] = guildID
			m.unionOf[guildID] = u.ID
			return copyUnion(u), nil
		}
	}
	return nil, ErrUnionFull
}

// LeaveUnion implements UnionStore.
func (m *MemStore) LeaveUnion(_ context.Context, guildID int64) (*Union, *Union, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	id, in := m.unionOf[guildID]
	if !in {
		return nil, nil, ErrNoUnion
	}
	before := copyUnion(m.unions[id])
	return before, m.leaveUnionLocked(guildID), nil
}

// leaveUnionLocked frees guildID's slot (a guild deleted leaves its union
// too) and dissolves a union left under MinUnionGuilds; it returns the union
// after, nil when dissolved or when guildID had none.
func (m *MemStore) leaveUnionLocked(guildID int64) *Union {
	id, in := m.unionOf[guildID]
	if !in {
		return nil
	}
	u := m.unions[id]
	delete(m.unionOf, guildID)
	for i := range u.Slots {
		if u.Slots[i] == guildID {
			u.Slots[i] = 0
		}
	}
	if u.Count() < MinUnionGuilds {
		for _, g := range u.GuildIDs() {
			delete(m.unionOf, g)
		}
		delete(m.unions, id)
		return nil
	}
	return copyUnion(u)
}

// GuildByName implements UnionStore.
func (m *MemStore) GuildByName(_ context.Context, name string) (*Guild, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	id, ok := m.names[strings.ToLower(name)]
	if !ok {
		return nil, ErrGuildNotFound
	}
	return m.copy(m.byID[id]), nil
}
