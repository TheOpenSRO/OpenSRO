package quest

import (
	"sort"
	"strings"
)

// The quest catalogue (round 785), built from the operator's own data at
// export time (cmd/export-refdata -mode quests, docs/protocol/quests.md):
//
//	questdata.txt          Media.pk2  id, code, required level, text ids
//	refqusetreward.txt     Media.pk2  the client's copy of _RefQuestReward
//	refquestrewarditems.txt Media.pk2 the client's copy of _RefQuestRewardItems
//	Script/VIETNAM/*.sct   the server's own Lua 5.1 quest scripts (luabc)
//
// Every field below says where it comes from; nothing here is invented.

// Mission types, the server script's own define.sct constants (READ:
// MISSION_TYPE_* = 1..13).
const (
	MissionGatherFromMonster = 1
	MissionKillMonster       = 2
	MissionDeliverItem       = 3
	MissionGatherFromNPC     = 4
	MissionGatherFromField   = 5
	MissionDialog            = 6
	MissionEscortNPC         = 7
	MissionCatchMonster      = 8
	MissionDifferentQuest    = 9
	MissionChangeItem        = 10
	MissionTimeCheck         = 11
	MissionKillPlayer        = 12
	MissionTalisman          = 13
)

// Start-condition flags, define.sct's QSC_* (READ).
const (
	QSCLevel  = 1
	QSCQuest  = 2
	QSCItem   = 4
	QSCTime   = 8
	QSCRegion = 16
	QSCRace   = 256
	QSCSex    = 1024
	QSCSystem = 4096
)

// Quest statuses, define.sct's QUEST_STATUS_* (READ).
const (
	StatusAchieving             = 1
	StatusAchievedButNotPaid    = 2
	StatusAchieved              = 3
	StatusNoData                = 4
	StatusAchievedOnlyForServer = 5
	StatusLockedByAbort         = 6
	StatusAchievingKillMonster  = 7
	StatusAchievedKillMonster   = 8
)

// CondRealTime is LuaSetRealTime's bit in the start-condition mask
// (s:0x86ba00 ORs 0x100000 into +0x848, READ): a quest offered again after
// it is cleared, up to its AchievementLimit; at the limit its NPC says
// BASIC_MENUSTRING_COUNT_LIMIT (s:0x920110).
const (
	CondRealTime = 0x100000
)

// Sources of a catalogue entry.
const (
	SourceScript   = "script"   // a Quest.sct function: everything below is known
	SourceCompiled = "compiled" // a CQNO_* class in SR_GameServer.exe: setup read from its DeclareQuestContent (compiled.go) when a decompilation is supplied
	SourceNone     = "none"     // questdata only
)

// Mission is one LuaSetMission*Data call.
type Mission struct {
	Index int
	Type  int
	// Text is the SN_CON_* objective text id the client shows.
	Text string
	// Targets are monster code names (kill and gather-from-monster) -- READ:
	// LuaSetMissionData(_EX)'s mob list (+0x17a8 / +0x1000 per mission) and
	// LuaSetCollectionItemMissionData's (mob, rate) pairs (+0x2ef8/+0x2778).
	Targets []string
	// Rates are the per-target drop chances of a gather mission, in percent
	// (READ: a float per target, +0x2778; INFERRED percent: the values run
	// 0.5..100 and 100 is the commonest).
	Rates []float64
	// Count is the required count: kills, or items to collect (READ:
	// +0x1f48 for kills, +0x3678 for collections; MEASURED against the
	// objective texts, "Hunt 15 Grassps" = 15).
	Count int
	// MonsterClass is LuaSetMissionData's class argument (+0x1028;
	// define.sct MONSTER_CLASS_*). -1 when the call has none.
	MonsterClass int
	// Item is a gather mission's quest item (+0x3698).
	Item string
	// NPC is the mission's NPC: a delivery's target, a gather mission's
	// hand-in NPC (+0x2758).
	NPC string
	// Deliver are the (item, count) pairs a delivery carries: the items the
	// player is handed at acceptance and gives up at NPC (OURS: one list for
	// both; see quests.md "Deliveries").
	Deliver []ItemCount
	// Talk are the SN_TALK_* lines shown at the mission's NPC.
	Talk []string
}

// ItemCount is an item code and a count.
type ItemCount struct {
	Code  string
	Count int
}

// MenuText is one InsertQuestMenuStringList pair: a BASIC_MENUSTRING_* key
// and the text id shown for it at one NPC.
type MenuText struct {
	Key  string
	Text string
}

// Reward is a quest's _RefQuestReward row (refqusetreward.txt) and its items.
type Reward struct {
	Gold  int64 // column 10 (MEASURED against SN_PAYCON_*: "Exp 270 / GOLD 205")
	Exp   int64 // column 11
	SPExp int64 // column 12 ("Skill Exp 100")
	// SkillPoint is LuaSetAchievedSkillPont's value (READ, +? ; usually 0).
	SkillPoint int64
	Items      []RewardItem
	// FromTable is true when the row came from refqusetreward.txt; false
	// when only the script's LuaSetAchievedItem values were found.
	FromTable bool
}

// RewardItem is a refquestrewarditems.txt row (or a LuaSetAchievedItem item).
type RewardItem struct {
	Code  string
	Count int
	// Choice is true when the player picks one of the quest's choice items.
	Choice bool
}

// Quest is one catalogue entry.
type Quest struct {
	ID    int64
	Code  string
	Level int // questdata column 3; LuaSetStartCodition's level (+0x86c)
	// LevelArg2 is LuaSetStartCodition's last argument (+0x820, copied to the
	// condition's +4). What it means is OPEN; it is recorded, not used.
	LevelArg2 int
	Source    string
	// Text ids from questdata.
	TextName, TextPay, TextPayCon, TextNN, TextNC string

	ConditionMask int // LuaSetStartCodition's ORed QSC_* flags (+0x848)
	// Race is LuaSetRaceStartCodition's byte (+0x870): 0 China, 1 Europe;
	// -1 when the quest has no race condition.
	Race int
	// StartNPCs offer the quest (LuaSetStartMethod, +0x87c).
	StartNPCs []string
	// QuestNPCs are the NPCs the quest involves (LuaQuestInsertNpc, +0x82c).
	QuestNPCs []string
	// CompleteNPCs pay the reward (LuaInsertMissionOrCompleteNpc).
	CompleteNPCs []string
	// MissionNPCs (LuaInsertMissionNPC).
	MissionNPCs []string
	// Requires must all be achieved first (LuaInsertDependancyQuests);
	// RequiresAny needs one of them (LuaInsertDependancyQuestsOneClear).
	Requires    []string
	RequiresAny []string
	// AchievementLimit is how many times the quest can be completed
	// (LuaSetAchievementLimit, +0x825). 0: no limit (INFERRED from the
	// builder's memset to 0 and the quests that omit it, e.g. grind quests).
	AchievementLimit int
	// CompleteNum is LuaSetMissionCompleteNum's value: 0 = every mission.
	CompleteNum int
	// DivideType is LuaSetDivideType's byte (s:0x86bb20, builder +0x826;
	// the quest's +0x2e, READ): 0 and 5 any player, 1 only in a party that
	// shares EXP and items (s:0x9261d0; any other value never passes). The
	// quest window's row bar is drawn by it (0x30D5 byte +9, s:0x871bd0).
	DivideType int
	// DifferentString is LuaSetDifferentString's byte (s:0x86b200, builder
	// +0x85d; the condition block's +0x1d): a quest cleared before offers
	// itself with BASIC_MENUSTRING_ACCEPT_AFTER_ONE_CLEAR (s:0x920110).
	DifferentString bool
	Missions    []Mission
	Menus       map[string][]MenuText
	Reward      Reward
	// Unhandled counts setup calls this catalogue does not model.
	Unhandled []string
	// scriptReward is the script's own LuaSetAchievedItem values, kept for
	// the exporter's comparison with the reward table (not exported).
	scriptReward *Reward
}

// Playable reports whether OpenSRO can run the quest end to end: a scripted
// quest with a start NPC, every mission of a modelled type.
func (q *Quest) Playable() bool {
	if (q.Source != SourceScript && q.Source != SourceCompiled) || len(q.StartNPCs) == 0 || len(q.Missions) == 0 {
		return false
	}
	for _, m := range q.Missions {
		switch m.Type {
		case MissionKillMonster, MissionGatherFromMonster, MissionDeliverItem, MissionDialog:
		default:
			return false
		}
	}
	return true
}

// CompleteNPC is the NPC that pays the reward: the script's complete NPC, or
// the first start NPC when it names none (OURS).
func (q *Quest) CompleteNPC() string {
	if len(q.CompleteNPCs) > 0 {
		return q.CompleteNPCs[0]
	}
	if len(q.StartNPCs) > 0 {
		return q.StartNPCs[0]
	}
	return ""
}

// MenuText returns the text id the quest shows at npc for key, "" if none.
func (q *Quest) MenuText(npc, key string) string {
	for _, m := range q.Menus[npc] {
		if m.Key == key {
			return m.Text
		}
	}
	return ""
}

// Catalog is the loaded catalogue.
type Catalog struct {
	ByID   map[int64]*Quest
	ByCode map[string]*Quest
	// ByNPC lists the quests each NPC is involved in (start, complete,
	// mission or quest NPC), by id.
	ByNPC map[string][]int64
}

// NewCatalog indexes quests.
func NewCatalog(quests []*Quest) *Catalog {
	c := &Catalog{ByID: map[int64]*Quest{}, ByCode: map[string]*Quest{}, ByNPC: map[string][]int64{}}
	for _, q := range quests {
		c.ByID[q.ID] = q
		c.ByCode[q.Code] = q
		seen := map[string]bool{}
		for _, list := range [][]string{q.StartNPCs, q.CompleteNPCs, q.MissionNPCs, q.QuestNPCs} {
			for _, n := range list {
				if !seen[n] {
					seen[n] = true
					c.ByNPC[n] = append(c.ByNPC[n], q.ID)
				}
			}
		}
		for _, m := range q.Missions {
			if m.NPC != "" && !seen[m.NPC] {
				seen[m.NPC] = true
				c.ByNPC[m.NPC] = append(c.ByNPC[m.NPC], q.ID)
			}
		}
	}
	for _, ids := range c.ByNPC {
		sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
	}
	return c
}

// Len is the number of quests.
func (c *Catalog) Len() int {
	if c == nil {
		return 0
	}
	return len(c.ByID)
}

// Coverage counts the catalogue by what OpenSRO can do with each quest.
// Reachable counts the playable quests whose prerequisites are all
// reachable too (a playable quest behind a compiled one cannot be taken).
type Coverage struct {
	Total, Playable, Reachable, Script, Compiled, None int
}

// Reachable reports whether q is playable and every prerequisite chain under
// it is playable.
func (c *Catalog) Reachable(q *Quest) bool {
	return c.reachable(q, map[int64]bool{})
}

func (c *Catalog) reachable(q *Quest, seen map[int64]bool) bool {
	if q == nil || !q.Playable() {
		return false
	}
	if seen[q.ID] {
		return true
	}
	seen[q.ID] = true
	for _, code := range q.Requires {
		if !c.reachable(c.ByCode[code], seen) {
			return false
		}
	}
	if len(q.RequiresAny) > 0 {
		for _, code := range q.RequiresAny {
			if c.reachable(c.ByCode[code], seen) {
				return true
			}
		}
		return false
	}
	return true
}

// Coverage measures c.
func (c *Catalog) Coverage() Coverage {
	var cv Coverage
	if c == nil {
		return cv
	}
	for _, q := range c.ByID {
		cv.Total++
		switch q.Source {
		case SourceScript:
			cv.Script++
		case SourceCompiled:
			cv.Compiled++
		default:
			cv.None++
		}
		if q.Playable() {
			cv.Playable++
		}
		if c.Reachable(q) {
			cv.Reachable++
		}
	}
	return cv
}

func hasString(list []string, s string) bool {
	for _, x := range list {
		if strings.EqualFold(x, s) {
			return true
		}
	}
	return false
}
