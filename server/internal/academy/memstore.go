package academy

import (
	"context"
	"sort"
	"sync"
	"time"
)

// MemStore is a Store in memory (tests and the -in-memory server).
type MemStore struct {
	mu       sync.Mutex
	camps    map[int64]*Camp
	ofChar   map[int64]int64 // charID -> campID
	seq      map[int64]int64 // charID -> join order
	nextSeq  int64
	nextID   int64
	buffs    map[int64][]BuffRow // recipient -> rows
	bank     map[int64]int
	ranking  []RankRow
	lastRank time.Time
}

// NewMemStore is an empty MemStore.
func NewMemStore() *MemStore {
	return &MemStore{camps: map[int64]*Camp{}, ofChar: map[int64]int64{}, seq: map[int64]int64{},
		buffs: map[int64][]BuffRow{}, bank: map[int64]int{}}
}

func (s *MemStore) copyCamp(c *Camp) *Camp {
	out := *c
	out.Members = append([]Member(nil), c.Members...)
	sortMembers(out.Members, func(m Member) int64 { return s.seq[m.CharID] })
	return &out
}

func (s *MemStore) Found(_ context.Context, j Joiner, now time.Time) (*Camp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, in := s.ofChar[j.CharID]; in {
		return nil, ErrInCamp
	}
	now = Minute(now)
	s.nextID++
	c := &Camp{ID: s.nextID, CreationDate: now, Rank: RankNone, LatestEvaluationDate: now}
	if err := s.add(c, j, now); err != nil {
		s.nextID--
		return nil, err
	}
	s.camps[c.ID] = c
	return s.copyCamp(c), nil
}

func (s *MemStore) add(c *Camp, j Joiner, now time.Time) error {
	class := ClassForMaxLevel(j.MaxLevel)
	if err := checkAdd(c, class); err != nil {
		return err
	}
	honor := s.bank[j.CharID]
	delete(s.bank, j.CharID)
	c.Members = append(c.Members, Member{CampID: c.ID, CharID: j.CharID, RefObjID: j.RefObjID, Name: j.Name,
		JoinDate: now, Class: class, JoinedLevel: j.MaxLevel, CurLevel: j.CurLevel, MaxLevel: j.MaxLevel, Honor: honor})
	s.ofChar[j.CharID] = c.ID
	s.nextSeq++
	s.seq[j.CharID] = s.nextSeq
	s.buffs[j.CharID] = BuffRowsFor(c.ID, j.CharID, class)
	return nil
}

func (s *MemStore) AddMember(_ context.Context, campID int64, j Joiner, now time.Time) (*Camp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, in := s.ofChar[j.CharID]; in {
		return nil, ErrInCamp
	}
	c := s.camps[campID]
	if c == nil {
		return nil, ErrNoSuchCamp
	}
	if err := s.add(c, j, Minute(now)); err != nil {
		return nil, err
	}
	return s.copyCamp(c), nil
}

// drop removes charID's row from c.
func (s *MemStore) drop(c *Camp, charID int64) Member {
	var gone Member
	kept := c.Members[:0]
	for _, m := range c.Members {
		if m.CharID == charID {
			gone = m
			continue
		}
		kept = append(kept, m)
	}
	c.Members = kept
	delete(s.ofChar, charID)
	delete(s.seq, charID)
	delete(s.buffs, charID)
	return gone
}

func (s *MemStore) member(charID int64) (*Camp, int, error) {
	id, in := s.ofChar[charID]
	if !in {
		return nil, 0, ErrNotInCamp
	}
	c := s.camps[id]
	for i, m := range c.Members {
		if m.CharID == charID {
			return c, i, nil
		}
	}
	return nil, 0, ErrNotInCamp
}

func (s *MemStore) RemoveMember(_ context.Context, charID int64, reason int) (*Camp, Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, i, err := s.member(charID)
	if err != nil {
		return nil, Member{}, err
	}
	m := c.Members[i]
	if m.Class == MemberClassGuardian {
		return nil, Member{}, ErrGuardian
	}
	if m.Class == MemberClassSecondGuardian {
		s.bank[charID] += bankAfterRemoval(m, reason)
	}
	s.drop(c, charID)
	return s.copyCamp(c), m, nil
}

func (s *MemStore) Graduate(_ context.Context, charID int64, points int, now time.Time) (*Camp, Graduation, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, i, err := s.member(charID)
	if err != nil {
		return nil, Graduation{}, err
	}
	m := c.Members[i]
	if m.Class == MemberClassGuardian {
		return nil, Graduation{}, ErrGuardian
	}
	g := Graduation{Member: m}
	if m.Class == MemberClassSecondGuardian {
		s.bank[charID] += m.Honor
	} else {
		c.GraduateCount++
		if m.JoinedLevel <= HonorJoinLevelCeiling {
			c.EvaluationPoint += points
			c.LatestEvaluationDate = Minute(now)
			gs, as := GraduationHonor(m.JoinedLevel)
			for k := range c.Members {
				switch c.Members[k].Class {
				case MemberClassGuardian:
					c.Members[k].Honor += gs
				case MemberClassSecondGuardian:
					c.Members[k].Honor += as
				default:
					continue
				}
			}
		}
	}
	s.drop(c, charID)
	out := s.copyCamp(c)
	if m.Class == MemberClassStudent && m.JoinedLevel <= HonorJoinLevelCeiling {
		for _, o := range out.Members {
			if o.Class != MemberClassStudent {
				g.Shares = append(g.Shares, HonorShare{CharID: o.CharID, Honor: o.Honor})
			}
		}
	}
	return out, g, nil
}

func (s *MemStore) Disband(_ context.Context, campID int64) ([]Member, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.camps[campID]
	if c == nil {
		return nil, ErrNoSuchCamp
	}
	out := s.copyCamp(c).Members
	for _, m := range c.Members {
		if m.Class == MemberClassSecondGuardian && m.Honor > 0 {
			s.bank[m.CharID] += m.Honor
		}
		delete(s.ofChar, m.CharID)
		delete(s.seq, m.CharID)
		delete(s.buffs, m.CharID)
	}
	delete(s.camps, campID)
	return out, nil
}

func (s *MemStore) SetNotice(_ context.Context, campID int64, title, content string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.camps[campID]
	if c == nil {
		return ErrNoSuchCamp
	}
	c.NoticeTitle, c.Notice = title, content
	return nil
}

func (s *MemStore) update(charID int64, f func(*Member)) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, i, err := s.member(charID)
	if err != nil {
		return err
	}
	f(&c.Members[i])
	return nil
}

func (s *MemStore) SetLevels(_ context.Context, charID int64, cur, max int) error {
	return s.update(charID, func(m *Member) { m.CurLevel, m.MaxLevel = cur, max })
}

func (s *MemStore) SetRefObj(_ context.Context, charID, refObjID int64) error {
	return s.update(charID, func(m *Member) { m.RefObjID = refObjID })
}

func (s *MemStore) SetName(_ context.Context, charID int64, name string) error {
	return s.update(charID, func(m *Member) { m.Name = name })
}

func (s *MemStore) SpendHonor(_ context.Context, charID int64, amount int, pay func() error) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, i, err := s.member(charID)
	if err != nil {
		return 0, err
	}
	if c.Members[i].Honor < amount {
		return c.Members[i].Honor, ErrHonorShort
	}
	if pay != nil {
		if err := pay(); err != nil {
			return c.Members[i].Honor, err
		}
	}
	c.Members[i].Honor -= amount
	return c.Members[i].Honor, nil
}

func (s *MemStore) CampOf(_ context.Context, charID int64) (*Camp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	id, in := s.ofChar[charID]
	if !in {
		return nil, ErrNotInCamp
	}
	return s.copyCamp(s.camps[id]), nil
}

func (s *MemStore) Get(_ context.Context, campID int64) (*Camp, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.camps[campID]
	if c == nil {
		return nil, ErrNoSuchCamp
	}
	return s.copyCamp(c), nil
}

func (s *MemStore) BuffRows(_ context.Context, charID int64) ([]BuffRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := append([]BuffRow(nil), s.buffs[charID]...)
	sort.Slice(out, func(i, j int) bool {
		if out[i].Type != out[j].Type {
			return out[i].Type < out[j].Type
		}
		return out[i].Slot < out[j].Slot
	})
	return out, nil
}

func (s *MemStore) Bank(_ context.Context, charID int64) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.bank[charID], nil
}

func (s *MemStore) UpdateRanks(_ context.Context, now time.Time) ([]RankChange, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var all []*Camp
	for _, c := range s.camps {
		all = append(all, c)
	}
	rows, ranks := RankCamps(all)
	var changes []RankChange
	for _, c := range all {
		if r := ranks[c.ID]; r != c.Rank {
			c.Rank = r
			changes = append(changes, RankChange{CampID: c.ID, Rank: r})
		}
	}
	sort.Slice(changes, func(i, j int) bool { return changes[i].CampID < changes[j].CampID })
	s.ranking = rows
	s.lastRank = now
	return changes, nil
}

func (s *MemStore) Ranking(_ context.Context) ([]RankRow, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]RankRow(nil), s.ranking...), nil
}

func (s *MemStore) LastRankUpdate(_ context.Context) (time.Time, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.lastRank, nil
}
