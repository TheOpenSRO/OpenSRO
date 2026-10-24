package quest

import (
	"fmt"
	"strconv"

	"github.com/TheOpenSRO/OpenSRO/server/internal/quest/luabc"
)

// Call is one host-function call a quest's setup made.
type Call struct {
	Name string
	Args []luabc.Value
}

// RunScripts runs the server's quest scripts (round 785): define.sct's
// constants, QuestList.sct's QUEST_LIST() for the quest codes, Quest.sct's
// definitions, then each listed quest's setup function, recording its calls.
// ids gives LuaGetQuestID's answers (questdata's id by code). The result is
// keyed by quest code, in QuestList order (order).
func RunScripts(define, questList, questSct []byte, ids map[string]int64) (calls map[string][]Call, order []string, err error) {
	protos := make([]*luabc.Proto, 3)
	for i, b := range [][]byte{define, questList, questSct} {
		if protos[i], err = luabc.Load(b); err != nil {
			return nil, nil, fmt.Errorf("quest: script %d: %w", i, err)
		}
	}
	var cur *[]Call
	var listed []string
	vm := luabc.NewVM(func(name string, args []luabc.Value) []luabc.Value {
		switch name {
		case "LuaInsertQuest": // (TYPE_ID, "SN_<CODE>.lua", "<CODE>")
			if len(args) >= 3 {
				listed = append(listed, args[2].S)
			}
			return nil
		case "LuaGetQuestID", "LuaGetNameQuestID":
			if len(args) >= 1 {
				if id, ok := ids[args[0].S]; ok {
					return []luabc.Value{{K: luabc.Number, N: float64(id)}}
				}
			}
			return []luabc.Value{{K: luabc.Number, N: 0}}
		}
		if cur != nil {
			*cur = append(*cur, Call{Name: name, Args: append([]luabc.Value(nil), args...)})
		}
		return nil
	})
	for i, p := range protos {
		if err := vm.Run(p); err != nil {
			return nil, nil, fmt.Errorf("quest: running script %d: %w", i, err)
		}
	}
	if err := vm.CallGlobal("QUEST_LIST"); err != nil {
		return nil, nil, fmt.Errorf("quest: QUEST_LIST: %w", err)
	}
	calls = map[string][]Call{}
	for _, code := range listed {
		var c []Call
		cur = &c
		if err := vm.CallGlobal(code); err != nil {
			// A listed quest whose function is missing or fails: recorded as
			// an empty set (the exporter reports it).
			cur = nil
			calls[code] = nil
			order = append(order, code)
			continue
		}
		cur = nil
		calls[code] = c
		order = append(order, code)
	}
	return calls, order, nil
}

// args is a cursor over a call's arguments.
type args struct {
	v   []luabc.Value
	i   int
	bad bool
}

func (a *args) next() luabc.Value {
	if a.i >= len(a.v) {
		a.bad = true
		a.i++
		return luabc.Value{}
	}
	v := a.v[a.i]
	a.i++
	return v
}
func (a *args) num() float64 { return a.next().N }
func (a *args) int() int     { return int(a.next().N) }
func (a *args) str() string {
	v := a.next()
	if v.K == luabc.String {
		return v.S
	}
	if v.K == luabc.Number {
		return strconv.FormatFloat(v.N, 'f', -1, 64)
	}
	return ""
}
func (a *args) strs(n int) []string {
	var out []string
	for i := 0; i < n && !a.bad; i++ {
		if s := a.str(); s != "" {
			out = append(out, s)
		}
	}
	return out
}

// Apply fills q from its setup calls. Argument orders are READ from the host
// functions' bodies in SR_GameServer.exe (docs/protocol/quests.md, "The
// setup calls"); each lua_tonumber/lua_tostring in a body takes the next
// stack index.
func Apply(q *Quest, calls []Call) {
	q.Source = SourceScript
	q.Race = -1
	if q.Menus == nil {
		q.Menus = map[string][]MenuText{}
	}
	missions := map[int]*Mission{}
	var lua Reward
	luaReward := false
	for _, c := range calls {
		a := &args{v: c.Args}
		switch c.Name {
		case "LuaSetStartCodition": // 0x869f90: n, n x mask, level (+0x86c), arg (+0x820)
			n := a.int()
			for i := 0; i < n; i++ {
				q.ConditionMask |= a.int()
			}
			lv := a.int()
			q.LevelArg2 = a.int()
			if q.Level == 0 {
				q.Level = lv
			}
		case "LuaSetRaceStartCodition": // 0x869ef0: mask |= arg1; race byte (+0x870)
			q.ConditionMask |= a.int()
			q.Race = a.int()
		case "LuaSetStartMethod": // 0x86a1c0: method (+0x874), n (+0x878), n x npc (+0x87c)
			a.int()
			n := a.int()
			q.StartNPCs = append(q.StartNPCs, a.strs(n)...)
		case "LuaQuestInsertNpc": // 0x86c430: n (+0x840), n x npc (+0x82c)
			n := a.int()
			q.QuestNPCs = append(q.QuestNPCs, a.strs(n)...)
		case "LuaInsertMissionOrCompleteNpc": // 0x86a280: one npc
			q.CompleteNPCs = append(q.CompleteNPCs, a.str())
		case "LuaInsertMissionNPC": // 0x86b090: one npc
			q.MissionNPCs = append(q.MissionNPCs, a.str())
		case "LuaSetAchievementLimit": // 0x86a180: byte +0x825
			q.AchievementLimit = a.int()
		case "LuaInsertDependancyQuests": // 0x86a500: n, n x code
			n := a.int()
			q.Requires = append(q.Requires, a.strs(n)...)
		case "LuaInsertDependancyQuestsOneClear":
			n := a.int()
			q.RequiresAny = append(q.RequiresAny, a.strs(n)...)
		case "LuaSetMissionCompleteNum":
			q.CompleteNum = a.int()
		case "LuaSetDivideType": // 0x86bb20: byte +0x826
			q.DivideType = a.int()
		case "LuaSetRealTime": // 0x86ba00: +0x848 |= 0x100000, no argument
			q.ConditionMask |= CondRealTime
		case "LuaSetDifferentString": // 0x86b200: byte +0x85d
			q.DifferentString = a.int() != 0
		case "LuaSetMissionDataSize":
		case "LuaSetMissionData": // 0x86c0f0
			a.next() // QUESTID
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			n := a.int()
			if n > 0 {
				m.Targets = append(m.Targets, a.str()) // one mob is read (+0x17a8)
			}
			a.int() // +0x1f28 (OPEN)
			m.MonsterClass = a.int()
			m.Count = a.int() // +0x1f48
			a.int()           // +0x1f68 (OPEN)
		case "LuaSetMissionData_EX": // 0x86b710
			a.next()
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			m.Targets = append(m.Targets, a.strs(a.int())...)
			nx := a.int()
			for i := 0; i < nx; i++ {
				a.int() // +0x880 list (OPEN)
			}
			m.Count = a.int() // +0x1f48
			a.int()           // +0x1f28
			a.int()           // +0x2738
			m.MonsterClass = -1
		case "LuaSetCollectionItemMissionData": // 0x86bf20
			a.next()
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			n := a.int()
			m.NPC = a.str()   // +0x2758
			a.int()           // read and dropped
			m.Count = a.int() // +0x3678
			m.Item = a.str()  // +0x3698
			for i := 0; i < n && !a.bad; i++ {
				m.Targets = append(m.Targets, a.str())
				m.Rates = append(m.Rates, a.num())
			}
			m.MonsterClass = -1
		case "LuaSetDeliverMissionData": // 0x86ab00
			a.next()
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			m.NPC = a.str() // +0xc98
			n := a.int()
			for i := 0; i < n && !a.bad; i++ {
				cnt := a.int()
				m.Deliver = append(m.Deliver, ItemCount{Code: a.str(), Count: cnt})
			}
			m.Talk = append(m.Talk, a.strs(a.int())...)
			m.MonsterClass = -1
		case "LuaSetDeliverMissionData_EX": // 0x86acb0
			a.next()
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			m.NPC = a.str()
			n := a.int()
			for i := 0; i < n && !a.bad; i++ {
				cnt := a.int()
				m.Deliver = append(m.Deliver, ItemCount{Code: a.str(), Count: cnt})
			}
			m.Talk = append(m.Talk, a.strs(a.int())...)
			n = a.int() // <= 10, +0x1924: (count, item) handed over
			for i := 0; i < n && !a.bad; i++ {
				cnt := a.int()
				m.Deliver = append(m.Deliver, ItemCount{Code: a.str(), Count: cnt})
			}
			m.MonsterClass = -1
		case "LuaSetDialLogMissionData": // 0x86bb80
			a.next()
			m := mission(missions, a.int())
			m.Type = a.int()
			m.Text = a.str()
			m.Talk = append(m.Talk, a.strs(a.int())...)
			m.MonsterClass = -1
		case "InsertQuestMenuStringList": // 0x86c4b0: npc, n, n x (key, text)
			npc := a.str()
			n := a.int()
			for i := 0; i < n && !a.bad; i++ {
				k := a.str()
				q.Menus[npc] = append(q.Menus[npc], MenuText{Key: k, Text: a.str()})
			}
		case "LuaSetAchievedItem": // 0x86c2e0: n, exp (+0x8c4), spexp (+0x8c8), gold (+0x8c0), n x (flag, item, count)
			luaReward = true
			n := a.int()
			lua.Exp = int64(a.num())
			lua.SPExp = int64(a.num())
			lua.Gold = int64(a.num())
			for i := 0; i < n && !a.bad; i++ {
				a.int()
				code := a.str()
				lua.Items = append(lua.Items, RewardItem{Code: code, Count: a.int()})
			}
		case "LuaSetAchievedSkillPont":
			q.Reward.SkillPoint = int64(a.num())
		default:
			q.Unhandled = append(q.Unhandled, c.Name)
		}
	}
	for i := 0; i < len(missions); i++ {
		if m, ok := missions[i]; ok {
			q.Missions = append(q.Missions, *m)
		}
	}
	if luaReward {
		q.scriptReward = &lua
	}
	if !q.Reward.FromTable && luaReward {
		sp := q.Reward.SkillPoint
		q.Reward = lua
		q.Reward.SkillPoint = sp
	}
}

func mission(ms map[int]*Mission, idx int) *Mission {
	m, ok := ms[idx]
	if !ok {
		m = &Mission{Index: idx, MonsterClass: -1}
		ms[idx] = m
	}
	return m
}
