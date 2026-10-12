// Package quest is OpenSRO's quest system (round 785): the real quest
// catalogue, built from the operator's own data (catalog.go, build.go,
// script.go), the rules a quest follows (engine.go), and each character's
// quest log, persisted (memstore.go, sqlstore.go).
//
// Where the data comes from (docs/protocol/quests.md):
//
//   - questdata.txt (Media.pk2): id, code, required level, text ids.
//   - refqusetreward.txt / refquestrewarditems.txt (Media.pk2): the client's
//     copies of the shard's _RefQuestReward / _RefQuestRewardItems -- gold,
//     EXP, skill EXP and items.
//   - The game server's Script/VIETNAM/Quest.sct (Lua 5.1 bytecode, the
//     operator's own server files): for 529 quests, the setup the retail
//     server runs -- start NPCs, complete NPC, prerequisites, level, race,
//     how often, missions with their targets, counts and drop rates, and the
//     dialogue text ids. This settles "objectives are code" (quest_scripting.md
//     round 434): for the classless quests the objectives are Lua calls, and
//     their arguments are the data.
//   - 154 quests are compiled CQNO_* classes in SR_GameServer.exe; their setup
//     (DeclareQuestContent) is C++ and is not extracted (OPEN): they are in the
//     catalogue, not offered.
//
// The invented two-quest catalogue this package carried until round 785 is
// gone; its ids 1 and 2 were the real QEVENT_GUIDE and QTUTORIAL_CH.
package quest

import (
	"context"
	"errors"
)

// State is one character's state on one quest: the _CharQuest row's shape
// (READ, quest_scripting.md: _CHARQUEST with Status, AchievementCount,
// QuestData1/2), with the per-mission counts OpenSRO keeps.
type State struct {
	QuestID int64
	// Status is a QUEST_STATUS_* value: StatusAchieving while missions are
	// open, StatusAchievedButNotPaid when they are done and the reward waits,
	// StatusAchieved once paid.
	Status int
	// Counts holds each mission's progress, by mission index.
	Counts []int
	// Achieved is how many times the quest was completed
	// (_CharQuest.AchievementCount).
	Achieved int
}

// Clone copies s.
func (s State) Clone() State {
	s.Counts = append([]int(nil), s.Counts...)
	return s
}

// ErrUnknownQuest is a quest id the catalogue does not have.
var ErrUnknownQuest = errors.New("quest: no such quest")

// Store persists characters' quest logs.
type Store interface {
	// States returns characterID's quest log.
	States(ctx context.Context, characterID int64) ([]State, error)
	// Put writes one state (insert or replace).
	Put(ctx context.Context, characterID int64, s State) error
	// Delete removes characterID's state on questID (an abandoned quest).
	Delete(ctx context.Context, characterID, questID int64) error
	// GrantDefaultQuests and DefaultQuests: a new character's default quests
	// (round 692, defaults.go).
	GrantDefaultQuests(ctx context.Context, characterID int64, codes []string) error
	DefaultQuests(ctx context.Context, characterID int64) ([]GrantedQuest, error)
}
