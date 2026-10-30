package guild

import "context"

// The MemStore's notice, permissions and hand-over (round 844, manage.go).

// SetNotice implements ManageStore.
func (m *MemStore) SetNotice(_ context.Context, guildID int64, title, body string) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.byID[guildID]
	if g == nil {
		return nil, ErrGuildNotFound
	}
	g.NoticeTitle, g.NoticeBody = title, body
	return m.copy(g), nil
}

// SetPermissions implements ManageStore.
func (m *MemStore) SetPermissions(_ context.Context, guildID int64, changes []PermissionChange) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.byID[guildID]
	if g == nil {
		return nil, ErrGuildNotFound
	}
	at := make([]int, len(changes))
	for i, c := range changes {
		at[i] = -1
		for j := range g.Members {
			if g.Members[j].CharacterID == c.CharacterID {
				at[i] = j
			}
		}
		if at[i] < 0 {
			return nil, ErrNotInGuild
		}
		if g.Members[at[i]].Role == RoleLeader {
			return nil, ErrIsMaster
		}
	}
	for i, c := range changes {
		g.Members[at[i]].Permission = c.Permission
	}
	return m.copy(g), nil
}

// TransferMaster implements ManageStore.
func (m *MemStore) TransferMaster(_ context.Context, guildID, toID int64) (*Guild, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	g := m.byID[guildID]
	if g == nil {
		return nil, ErrGuildNotFound
	}
	to := -1
	for i := range g.Members {
		if g.Members[i].CharacterID == toID {
			to = i
		}
	}
	if to < 0 {
		return nil, ErrNotInGuild
	}
	if g.Members[to].Role == RoleLeader {
		return nil, ErrIsMaster
	}
	for i := range g.Members {
		if g.Members[i].Role == RoleLeader {
			g.Members[i].Role = RoleMember
			g.Members[i].Permission = MasterHandOverPermission
			g.Members[i].SiegeAuthority = SiegeNone
		}
	}
	g.Members[to].Role = RoleLeader
	g.Members[to].Permission = PermAll
	g.Members[to].SiegeAuthority = SiegeCommander
	g.LeaderID = toID
	return m.copy(g), nil
}
