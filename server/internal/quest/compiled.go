package quest

import (
	"bufio"
	"encoding/binary"
	"io"
	"math"
	"regexp"
	"strconv"
	"strings"
)

// The compiled quests (round 785): 154 quests are C++ classes in
// SR_GameServer.exe, CQNO_<CODE>, whose DeclareQuestContent (vtable slot 55)
// fills the quest object with literals instead of calling the Lua host
// functions. This reads that setup from a decompilation of the operator's own
// binary (the project's Ghidra dump, `funcs_*.c`: "===FUNC=== <addr>
// CQNO_<CODE>::DeclareQuestContent ..." blocks) -- the same fields the Lua
// path fills, at the quest object's offsets.
//
// What each store means (docs/protocol/quests.md, "Compiled quests"):
//
//	param_1[0xc2] |= mask          the QSC_* condition flags (2 QUEST, 1 LEVEL)
//	param_1[0xc2] + 0x23           required level (= questdata col 3, MEASURED)
//	param_1[0xc2] + 4              the level condition's second value (Lua +0x820)
//	param_1[0xc4] + 8 + 4i         the quest NPCs (LuaQuestInsertNpc's list; READ by
//	                               npcspawn/questtalk.go's census, round 727)
//	FUN_00401fc0("NPC_...")        pushed in order: the complete NPC, then the start
//	                               NPC (INFERRED: CONS_2 pushes MERCHANT, POTION and
//	                               the Lua CONS_3 that follows starts at MERCHANT)
//	FUN_00401fc0("QNO_...")        a prerequisite; param_1[0x150] = n: n of them
//	param_1[0x126 + i]             quest NPC i's greeting (SN_NPC_*_QS)
//	param_1[0x130 + k]             the menu text at key k: the builder's 0x40-byte
//	                               block order, READ in InsertQuestMenuStringList
//	                               0x86c4b0 (menuKeys below)
//	FUN_009dd2bc(size) ... FUN_009173b0()  one mission object; its class is its size
//
// The mission classes, by allocation size (MEASURED across the Europe chain's
// classes against their objective texts):
//
//	0x152 kill:    +9 type 2, +0xd text, +0x15 n, +0x19+4i mob, +0x149 count
//	0x25a gather:  +9 type 1, +0x15 NPC, +0x19 n, +0x1d+4i mob, +0x14d+4i rate
//	               (a float constant), +0x23d count, +0x241 item
//	0xa7 dialog:   +9 type 6, +0x15 NPC, +0x1e talk
//	0x121 deliver: +9 type 3, +0x15 NPC, +0x1a count, +0x42 item, +0xc0 talk
//
// Any other mission class leaves the quest unplayable (its Unhandled names it).

// menuKeys is the builder's per-NPC block, by 4-byte slot (READ, 0x86c4b0
// and the disassembly of its tail, 0x86c820..0x86c978).
var menuKeys = []string{
	"BASIC_MENUSTRING_REQUEST_ACCEPT_QUEST",   // +0x00
	"BASIC_MENUSTRING_AT_ACCEPT",              // +0x04
	"BASIC_MENUSTRING_AT_DENY",                // +0x08
	"BASIC_MENUSTRING_NOT_ACHIEVED",           // +0x0c
	"BASIC_MENUSTRING_ACHIEVED",               // +0x10
	"BASIC_MENUSTRING_NOT_ACHIEVED2",          // +0x14
	"BASIC_MENUSTRING_INVENTORY_FULL",         // +0x18
	"BASIC_MENUSTRING_CONTENT_STRING",         // +0x1c
	"BASIC_MENUSTRING_GREETING",               // +0x20
	"BASIC_MENUSTRING_ACHIEVED_NOW",           // +0x24
	"BASIC_MENUSTRING_ABORT_BY_LEVELUP",       // +0x28
	"BASIC_MENUSTRING_COUNT_LIMIT",            // +0x2c
	"BASIC_MENUSTRING_TIME_LIMIT_AUTO_ABORT",  // +0x30
	"BASIC_MENUSTRING_MIDDLE_ACHIEVED",        // +0x34
	"BASIC_MENUSTRING_ACCEPT_AFTER_ONE_CLEAR", // +0x38
	"BASIC_MENUSTRING_NOT_PARTY",              // +0x3c
}

// CompiledSetup is what one DeclareQuestContent sets.
type CompiledSetup struct {
	Code      string
	Mask      int
	Level     int
	LevelArg2 int
	Limit     int
	QuestNPCs []string
	Pushed    []string // NPC pushes, in order
	Deps      []string
	DepCount  int
	Greetings map[int]string
	Menu      map[int]string
	Missions  []compiledMission
	Unhandled []string
}

type compiledMission struct {
	size   int
	fields map[int]string // offset -> raw value (a "string" literal, a number, or a uVar name)
	order  []int
	index  int
	floats map[string]float64
}

var (
	reFunc     = regexp.MustCompile(`^===FUNC=== ([0-9a-f]+) C(Q[A-Z0-9_]+)::DeclareQuestContent\b`)
	reNextFunc = regexp.MustCompile(`^===FUNC=== `)
	reMask     = regexp.MustCompile(`\*\(uint \*\)param_1\[0xc2\] = \*\(uint \*\)param_1\[0xc2\] \| (0x[0-9a-f]+|\d+);`)
	reCond     = regexp.MustCompile(`\(param_1\[0xc2\] \+ (0x[0-9a-f]+|\d+)\) = (0x[0-9a-f]+|\d+);`)
	reLimit    = regexp.MustCompile(`\(\(int\)param_1 \+ 0x2d\) = (0x[0-9a-f]+|\d+);`)
	reQNPC     = regexp.MustCompile(`\(param_1\[0xc4\] \+ (0x[0-9a-f]+|\d+)\) = "([A-Z0-9_]+)";`)
	rePush     = regexp.MustCompile(`FUN_00401fc0\("([A-Z0-9_]+)",`)
	reSlot     = regexp.MustCompile(`param_1\[(0x[0-9a-f]+)\] = \(int\)"([A-Za-z0-9_]+)";`)
	reSlotNum  = regexp.MustCompile(`param_1\[(0x[0-9a-f]+)\] = (0x[0-9a-f]+|\d+);`)
	reAlloc    = regexp.MustCompile(`FUN_009dd2bc\((0x[0-9a-f]+|\d+)`)
	reEnd      = regexp.MustCompile(`FUN_009173b0\(`)
	reField    = regexp.MustCompile(`\(\(int\)(puVar\d+) \+ (0x[0-9a-f]+|\d+)\) = ([^;]+);`)
	reIdx      = regexp.MustCompile(`\((puVar\d+) \+ 2\) = (\d+);`)
	reArr      = regexp.MustCompile(`(puVar\d+)\[(0x[0-9a-f]+|\d+)\] = ([^;]+);`)
	reFloatVar = regexp.MustCompile(`(uVar\d+) = _DAT_([0-9a-f]+);`)
)

func num(s string) int {
	s = strings.TrimSpace(s)
	v, err := strconv.ParseInt(s, 0, 64)
	if err != nil {
		return 0
	}
	return int(v)
}

// ParseDecomp reads every CQNO_*::DeclareQuestContent body in r. dataFloat
// answers a float constant's value by its virtual address (the exe's .rdata;
// nil leaves rates unknown, read as 100).
func ParseDecomp(r io.Reader, dataFloat func(va uint32) (float64, bool)) map[string]*CompiledSetup {
	out := map[string]*CompiledSetup{}
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<24)
	var cur *CompiledSetup
	var mis *compiledMission
	floatVars := map[string]float64{}
	for sc.Scan() {
		line := sc.Text()
		if m := reFunc.FindStringSubmatch(line); m != nil {
			cur = &CompiledSetup{Code: m[2], Greetings: map[int]string{}, Menu: map[int]string{}}
			out[cur.Code] = cur
			mis = nil
			floatVars = map[string]float64{}
			continue
		}
		if reNextFunc.MatchString(line) {
			cur, mis = nil, nil
			continue
		}
		if cur == nil {
			continue
		}
		if m := reFloatVar.FindStringSubmatch(line); m != nil && dataFloat != nil {
			va, _ := strconv.ParseUint(m[2], 16, 32)
			if f, ok := dataFloat(uint32(va)); ok {
				floatVars[m[1]] = f
			}
		}
		if mis != nil {
			if reEnd.MatchString(line) {
				mis.floats = floatVars
				cur.Missions = append(cur.Missions, *mis)
				mis = nil
				continue
			}
			if m := reIdx.FindStringSubmatch(line); m != nil {
				mis.index = num(m[2])
				continue
			}
			if m := reField.FindStringSubmatch(line); m != nil {
				off := num(m[2])
				if _, seen := mis.fields[off]; !seen {
					mis.order = append(mis.order, off)
				}
				mis.fields[off] = strings.TrimSpace(m[3])
				continue
			}
			if m := reArr.FindStringSubmatch(line); m != nil {
				off := num(m[2]) * 4
				if _, seen := mis.fields[off]; !seen {
					mis.order = append(mis.order, off)
				}
				mis.fields[off] = strings.TrimSpace(m[3])
				continue
			}
			continue
		}
		switch {
		case reAlloc.MatchString(line):
			m := reAlloc.FindStringSubmatch(line)
			mis = &compiledMission{size: num(m[1]), fields: map[int]string{}}
		case reMask.MatchString(line):
			cur.Mask |= num(reMask.FindStringSubmatch(line)[1])
		case reCond.MatchString(line):
			m := reCond.FindStringSubmatch(line)
			switch num(m[1]) {
			case 0x23:
				cur.Level = num(m[2])
			case 4:
				cur.LevelArg2 = num(m[2])
			}
		case reLimit.MatchString(line):
			cur.Limit = num(reLimit.FindStringSubmatch(line)[1])
		case reQNPC.MatchString(line):
			cur.QuestNPCs = append(cur.QuestNPCs, reQNPC.FindStringSubmatch(line)[2])
		case rePush.MatchString(line):
			s := rePush.FindStringSubmatch(line)[1]
			if strings.HasPrefix(s, "NPC_") {
				cur.Pushed = append(cur.Pushed, s)
			} else if strings.HasPrefix(s, "Q") {
				cur.Deps = append(cur.Deps, s)
			}
		case reSlot.MatchString(line):
			m := reSlot.FindStringSubmatch(line)
			slot := num(m[1])
			switch {
			case slot >= 0x126 && slot < 0x130:
				cur.Greetings[slot-0x126] = m[2]
			case slot >= 0x130 && slot < 0x130+len(menuKeys):
				cur.Menu[slot-0x130] = m[2]
			}
		case reSlotNum.MatchString(line):
			m := reSlotNum.FindStringSubmatch(line)
			if num(m[1]) == 0x150 {
				cur.DepCount = num(m[2])
			}
		}
	}
	return out
}

func unquote(v string) (string, bool) {
	v = strings.TrimSpace(v)
	v = strings.TrimPrefix(v, "(int)")
	v = strings.TrimPrefix(v, "(char *)")
	if len(v) >= 2 && v[0] == '"' && v[len(v)-1] == '"' {
		return v[1 : len(v)-1], true
	}
	return "", false
}

// mission turns a compiled mission object into a Mission; false when its
// class is not one of the four modelled.
func (cm compiledMission) mission() (Mission, bool) {
	m := Mission{Index: cm.index, Type: num(cm.fields[9]), MonsterClass: -1}
	m.Text, _ = unquote(cm.fields[0xd])
	str := func(off int) string { s, _ := unquote(cm.fields[off]); return s }
	switch cm.size {
	case 0x152: // kill
		n := num(cm.fields[0x15])
		for i := 0; i < max(n, 1); i++ {
			if s := str(0x19 + 4*i); s != "" {
				m.Targets = append(m.Targets, s)
			}
		}
		m.Count = num(cm.fields[0x149])
	case 0x25a: // gather from monster
		m.NPC = str(0x15)
		n := num(cm.fields[0x19])
		for i := 0; i < max(n, 1); i++ {
			if s := str(0x1d + 4*i); s != "" {
				m.Targets = append(m.Targets, s)
				rate := 100.0
				if v, ok := cm.floats[strings.TrimSpace(cm.fields[0x14d+4*i])]; ok {
					rate = v
				}
				m.Rates = append(m.Rates, rate)
			}
		}
		m.Count = num(cm.fields[0x23d])
		m.Item = str(0x241)
	case 0xa7: // dialog
		m.NPC = str(0x15)
		if s := str(0x1e); s != "" {
			m.Talk = []string{s}
		}
	case 0x121: // deliver
		m.NPC = str(0x15)
		cnt := num(cm.fields[0x1a])
		if it := str(0x42); it != "" {
			m.Deliver = []ItemCount{{Code: it, Count: max(cnt, 1)}}
		}
		if s := str(0xc0); s != "" {
			m.Talk = []string{s}
		}
	default:
		return m, false
	}
	return m, true
}

// ApplyCompiled fills q from a compiled setup.
func ApplyCompiled(q *Quest, cs *CompiledSetup) {
	q.Source = SourceCompiled
	q.Race = -1
	if q.Menus == nil {
		q.Menus = map[string][]MenuText{}
	}
	q.ConditionMask = cs.Mask
	if q.Level == 0 {
		q.Level = cs.Level
	}
	q.LevelArg2 = cs.LevelArg2
	q.AchievementLimit = cs.Limit
	q.QuestNPCs = append([]string(nil), cs.QuestNPCs...)
	// The pushes: the complete NPC, then the start NPC (INFERRED, see above).
	switch len(cs.Pushed) {
	case 0:
		if len(cs.QuestNPCs) > 0 {
			q.StartNPCs = []string{cs.QuestNPCs[0]}
			q.CompleteNPCs = []string{cs.QuestNPCs[0]}
		}
	case 1:
		q.StartNPCs = []string{cs.Pushed[0]}
		q.CompleteNPCs = []string{cs.Pushed[0]}
	default:
		q.CompleteNPCs = []string{cs.Pushed[0]}
		q.StartNPCs = []string{cs.Pushed[1]}
	}
	if cs.DepCount > 0 && cs.DepCount < len(cs.Deps) {
		q.RequiresAny = append([]string(nil), cs.Deps...)
	} else {
		q.Requires = append([]string(nil), cs.Deps...)
	}
	start := ""
	if len(q.StartNPCs) > 0 {
		start = q.StartNPCs[0]
	}
	for i, npc := range cs.QuestNPCs {
		if g, ok := cs.Greetings[i]; ok {
			q.Menus[npc] = append(q.Menus[npc], MenuText{Key: "BASIC_MENUSTRING_GREETING", Text: g})
		}
	}
	for k := 0; k < len(menuKeys); k++ {
		text, ok := cs.Menu[k]
		if !ok || start == "" {
			continue
		}
		q.Menus[start] = append(q.Menus[start], MenuText{Key: menuKeys[k], Text: text})
	}
	q.Missions = nil
	for _, cm := range cs.Missions {
		m, ok := cm.mission()
		if !ok {
			q.Unhandled = append(q.Unhandled, "compiled mission class 0x"+strconv.FormatInt(int64(cm.size), 16))
			m.Type = -1
		}
		q.Missions = append(q.Missions, m)
	}
	// The complete NPC's ACHIEVED line, when the block named it only at the
	// start NPC: the last mission's talk (the dialogue's own line, as the
	// Lua dialogue quests have it).
	if c := q.CompleteNPC(); c != "" && c != start && q.MenuText(c, "BASIC_MENUSTRING_ACHIEVED") == "" {
		for i := len(q.Missions) - 1; i >= 0; i-- {
			if len(q.Missions[i].Talk) > 0 {
				q.Menus[c] = append(q.Menus[c], MenuText{Key: "BASIC_MENUSTRING_ACHIEVED", Text: q.Missions[i].Talk[0]})
				break
			}
		}
	}
}

// ExeFloat returns a reader of 4-byte float constants in a PE image by
// virtual address (the gather rates' _DAT_ constants).
func ExeFloat(exe []byte) func(va uint32) (float64, bool) {
	if len(exe) < 0x40 {
		return nil
	}
	pe := int(binary.LittleEndian.Uint32(exe[0x3c:]))
	if pe+24 > len(exe) {
		return nil
	}
	nsec := int(binary.LittleEndian.Uint16(exe[pe+6:]))
	optSize := int(binary.LittleEndian.Uint16(exe[pe+20:]))
	base := binary.LittleEndian.Uint32(exe[pe+24+28:])
	type sec struct{ va, vsz, raw, rsz uint32 }
	var secs []sec
	o := pe + 24 + optSize
	for i := 0; i < nsec && o+40 <= len(exe); i++ {
		secs = append(secs, sec{binary.LittleEndian.Uint32(exe[o+12:]), binary.LittleEndian.Uint32(exe[o+8:]),
			binary.LittleEndian.Uint32(exe[o+20:]), binary.LittleEndian.Uint32(exe[o+16:])})
		o += 40
	}
	return func(va uint32) (float64, bool) {
		for _, s := range secs {
			if va >= base+s.va && va+4 <= base+s.va+s.rsz {
				off := int(s.raw + va - base - s.va)
				if off+4 <= len(exe) {
					return float64(math.Float32frombits(binary.LittleEndian.Uint32(exe[off:]))), true
				}
			}
		}
		return 0, false
	}
}
