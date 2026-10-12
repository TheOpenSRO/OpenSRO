package quest

import (
	"sort"
	"strings"
)

// The rules a quest follows (round 785). Pure logic over a Catalog and a
// character's log; the session layer does the I/O (items, gold, EXP,
// packets, the store).
//
// READ, from the server script's define.sct and the setup calls: a quest is
// offered by its start NPCs (LuaSetStartMethod) to a character of at least
// its level (LuaSetStartCodition's QSC_LEVEL), of its race when it has a race
// condition (QSC_RACE, LuaSetRaceStartCodition), who has achieved its
// prerequisites (QSC_QUEST, LuaInsertDependancyQuests[OneClear]) and has not
// reached its achievement limit (LuaSetAchievementLimit). Its missions are
// counted from kills, drops, deliveries and talks; when they are done the
// status is QUEST_STATUS_ACHIEVED_BUT_NOT_PAYED until the complete NPC
// (LuaInsertMissionOrCompleteNpc) pays it, then QUEST_STATUS_ACHIEVED.

// Player is what the gates read from a character.
type Player struct {
	Level int
	// Race is COUNTRY_CHINA 0 or COUNTRY_EUROPE 1 (define.sct).
	Race int
}

// Log is one character's quest log, keyed by quest id.
type Log map[int64]*State

// NewLog builds a log from stored states.
func NewLog(states []State) Log {
	l := Log{}
	for _, s := range states {
		c := s.Clone()
		l[s.QuestID] = &c
	}
	return l
}

// Active reports whether the log has q open (achieving, or done and unpaid).
func (l Log) Active(id int64) bool {
	s := l[id]
	return s != nil && (s.Status == StatusAchieving || s.Status == StatusAchievedButNotPaid)
}

// Done reports whether q was ever completed.
func (l Log) Done(id int64) bool {
	s := l[id]
	return s != nil && s.Achieved > 0
}

// Refusal is why a quest cannot be taken.
type Refusal int

const (
	OK Refusal = iota
	RefuseUnknown
	RefuseNotPlayable
	RefuseLevel
	RefuseRace
	RefusePrerequisite
	RefuseActive
	RefuseLimit
	RefuseNotHere
)

func (r Refusal) String() string {
	return [...]string{"ok", "unknown quest", "not playable", "level too low", "wrong race", "prerequisite missing", "already in progress", "achievement limit reached", "not offered here"}[r]
}

// CanStart says whether p may take q from npc ("" skips the NPC test).
func (c *Catalog) CanStart(p Player, l Log, q *Quest, npc string) Refusal {
	if q == nil {
		return RefuseUnknown
	}
	if !q.Playable() {
		return RefuseNotPlayable
	}
	if npc != "" && !hasString(q.StartNPCs, npc) {
		return RefuseNotHere
	}
	if l.Active(q.ID) {
		return RefuseActive
	}
	if q.AchievementLimit > 0 {
		if s := l[q.ID]; s != nil && s.Achieved >= q.AchievementLimit {
			return RefuseLimit
		}
	}
	if p.Level < q.Level {
		return RefuseLevel
	}
	if q.ConditionMask&QSCRace != 0 && q.Race >= 0 && p.Race != q.Race {
		return RefuseRace
	}
	for _, code := range q.Requires {
		dep := c.ByCode[code]
		if dep == nil || !l.Done(dep.ID) {
			return RefusePrerequisite
		}
	}
	if len(q.RequiresAny) > 0 {
		any := false
		for _, code := range q.RequiresAny {
			if dep := c.ByCode[code]; dep != nil && l.Done(dep.ID) {
				any = true
				break
			}
		}
		if !any {
			return RefusePrerequisite
		}
	}
	return OK
}

// Offers lists the quests npc can give p now, by id.
func (c *Catalog) Offers(p Player, l Log, npc string) []*Quest {
	var out []*Quest
	for _, id := range c.ByNPC[npc] {
		q := c.ByID[id]
		if hasString(q.StartNPCs, npc) && c.CanStart(p, l, q, npc) == OK {
			out = append(out, q)
		}
	}
	return out
}

// AtNPC lists p's open quests npc is part of (to report, deliver or claim).
func (c *Catalog) AtNPC(l Log, npc string) []*Quest {
	var out []*Quest
	for _, id := range c.ByNPC[npc] {
		if l.Active(id) {
			out = append(out, c.ByID[id])
		}
	}
	return out
}

// Start opens q in l and returns the new state and the items the player is
// handed for its deliveries.
func Start(l Log, q *Quest) (*State, []ItemCount) {
	prev := l[q.ID]
	s := &State{QuestID: q.ID, Status: StatusAchieving, Counts: make([]int, len(q.Missions))}
	if prev != nil {
		s.Achieved = prev.Achieved
	}
	l[q.ID] = s
	var give []ItemCount
	for _, m := range q.Missions {
		if m.Type == MissionDeliverItem {
			give = append(give, m.Deliver...)
		}
	}
	return s, give
}

// Required is mission m's target count: its Count, or 1 for a delivery or a
// dialogue.
func Required(m Mission) int {
	switch m.Type {
	case MissionDeliverItem, MissionDialog:
		return 1
	}
	if m.Count <= 0 {
		return 1
	}
	return m.Count
}

// MissionsDone reports whether s has finished q's missions: every one, or
// CompleteNum of them when the script sets one.
func MissionsDone(q *Quest, s *State) bool {
	done := 0
	for i, m := range q.Missions {
		if i < len(s.Counts) && s.Counts[i] >= Required(m) {
			done++
		}
	}
	if q.CompleteNum > 0 {
		return done >= q.CompleteNum
	}
	return done == len(q.Missions)
}

// Progress is one mission's count changing.
type Progress struct {
	Quest   *Quest
	Mission int
	Count   int
	// Item is set when the step dropped a quest item into the bag.
	Item string
	// Finished is true when this step finished the quest's missions.
	Finished bool
}

func step(q *Quest, s *State, i int, item string) Progress {
	for len(s.Counts) < len(q.Missions) {
		s.Counts = append(s.Counts, 0)
	}
	s.Counts[i]++
	p := Progress{Quest: q, Mission: i, Count: s.Counts[i], Item: item}
	if s.Status == StatusAchieving && MissionsDone(q, s) {
		s.Status = StatusAchievedButNotPaid
		p.Finished = true
	}
	return p
}

// OnKill credits a kill of the species code. roll(rate) decides a gather
// mission's drop; rate is in percent.
func (c *Catalog) OnKill(l Log, code string, roll func(rate float64) bool) []Progress {
	var out []Progress
	ids := make([]int64, 0, len(l))
	for id := range l {
		ids = append(ids, id)
	}
	sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	for _, id := range ids {
		s := l[id]
		q := c.ByID[id]
		if q == nil || s.Status != StatusAchieving {
			continue
		}
		for i, m := range q.Missions {
			if i < len(s.Counts) && s.Counts[i] >= Required(m) {
				continue
			}
			switch m.Type {
			case MissionKillMonster:
				if hasString(m.Targets, code) {
					out = append(out, step(q, s, i, ""))
				}
			case MissionGatherFromMonster:
				for t, target := range m.Targets {
					if !strings.EqualFold(target, code) {
						continue
					}
					rate := 100.0
					if t < len(m.Rates) {
						rate = m.Rates[t]
					}
					if roll(rate) {
						out = append(out, step(q, s, i, m.Item))
					}
					break
				}
			}
			if s.Status != StatusAchieving {
				break
			}
		}
	}
	return out
}

// OnTalk settles the deliveries and dialogues p's open quests have at npc.
// has reports how many of an item the player holds.
func (c *Catalog) OnTalk(l Log, npc string, has func(code string) int) (out []Progress, take []ItemCount) {
	for _, q := range c.AtNPC(l, npc) {
		s := l[q.ID]
		if s.Status != StatusAchieving {
			continue
		}
		for i, m := range q.Missions {
			if i < len(s.Counts) && s.Counts[i] >= Required(m) {
				continue
			}
			switch m.Type {
			case MissionDeliverItem:
				if !strings.EqualFold(m.NPC, npc) {
					continue
				}
				ok := true
				for _, d := range m.Deliver {
					if has(d.Code) < max(d.Count, 1) {
						ok = false
					}
				}
				if ok {
					take = append(take, m.Deliver...)
					out = append(out, step(q, s, i, ""))
				}
			case MissionDialog:
				// A dialogue is achieved at the quest's complete NPC
				// (TREASURE_1: started at the smith, achieved at the
				// warehouse, whose ACHIEVED line is the mission's talk).
				if strings.EqualFold(q.CompleteNPC(), npc) {
					out = append(out, step(q, s, i, ""))
				}
			}
		}
	}
	return out, take
}

// GatherItems lists q's gather missions' quest items.
func GatherItems(q *Quest) []string {
	var out []string
	for _, m := range q.Missions {
		if m.Type == MissionGatherFromMonster && m.Item != "" {
			out = append(out, m.Item)
		}
	}
	return out
}

// Claim pays q at npc: the quest must be done and unpaid, and npc its complete
// NPC. It marks the state paid (or removes it for the next round of a
// repeatable quest -- OURS: the log keeps the achievement count) and returns
// the quest items to take back.
func Claim(l Log, q *Quest, npc string) (bool, []ItemCount) {
	s := l[q.ID]
	if s == nil || s.Status != StatusAchievedButNotPaid {
		return false, nil
	}
	if npc != "" && !strings.EqualFold(q.CompleteNPC(), npc) && !hasString(q.CompleteNPCs, npc) {
		return false, nil
	}
	s.Status = StatusAchieved
	s.Achieved++
	var take []ItemCount
	for _, m := range q.Missions {
		if m.Type == MissionGatherFromMonster && m.Item != "" {
			take = append(take, ItemCount{Code: m.Item, Count: Required(m)})
		}
	}
	return true, take
}

// Abandon drops q from l: an achieved quest keeps its count, an open one is
// forgotten. It returns the quest items to take back.
func Abandon(l Log, q *Quest) []ItemCount {
	s := l[q.ID]
	if s == nil || !l.Active(q.ID) {
		return nil
	}
	if s.Achieved > 0 {
		s.Status = StatusAchieved
		s.Counts = nil
	} else {
		delete(l, q.ID)
	}
	var take []ItemCount
	for _, m := range q.Missions {
		switch m.Type {
		case MissionGatherFromMonster:
			if m.Item != "" {
				take = append(take, ItemCount{Code: m.Item, Count: -1})
			}
		case MissionDeliverItem:
			for _, d := range m.Deliver {
				take = append(take, ItemCount{Code: d.Code, Count: -1})
			}
		}
	}
	return take
}
