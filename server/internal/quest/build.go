package quest

import (
	"fmt"
	"io"
	"regexp"
	"strconv"
	"strings"
)

// Inputs are the tables the catalogue is built from, each already split into
// tab-separated rows (cmd/export-refdata reads the UTF-16 text tables).
type Inputs struct {
	QuestData   [][]string // questdata.txt
	Rewards     [][]string // refqusetreward.txt
	RewardItems [][]string // refquestrewarditems.txt
	// The server's Script/VIETNAM/*.sct files (Lua 5.1 bytecode). Optional:
	// without them every quest is catalogued from questdata alone.
	Define, QuestList, QuestSct []byte
	// ServerExe is SR_GameServer.exe, optional: its RTTI names the compiled
	// CQNO_* quests (`.?AVC<CODE>@@`).
	ServerExe []byte
	// Decomp is a decompilation of ServerExe (the project's Ghidra dump,
	// funcs_*.c), optional: the compiled quests' DeclareQuestContent bodies
	// are read from it (compiled.go).
	Decomp []io.Reader
}

// BuildReport says what the build found.
type BuildReport struct {
	QuestData, Scripted, Compiled, CompiledRead, Rewards, RewardItems int
	ScriptFailed                                                      []string
	NotInQuestData                                                    []string
	Coverage                                                          Coverage
}

var rttiQuest = regexp.MustCompile(`\.\?AVC(Q[A-Z0-9_]+)@@`)

// Build makes the catalogue. questdata columns (READ by position, MEASURED on
// a retail archive): 0 Service, 1 ID, 2 CodeName, 3 required level, 4 the
// Korean title, 5 SN_ name, 6 SN_PAY_, 7 xxx, 8 SN_PAYCON_, 9 SN_NN_,
// 10 SN_NC_. Rows with Service 0 are skipped.
func Build(in Inputs) ([]*Quest, BuildReport, error) {
	var rep BuildReport
	byCode := map[string]*Quest{}
	var quests []*Quest
	ids := map[string]int64{}
	for _, r := range in.QuestData {
		if len(r) < 4 || strings.TrimSpace(r[0]) != "1" {
			continue
		}
		id, err := strconv.ParseInt(strings.TrimSpace(r[1]), 10, 64)
		if err != nil {
			continue
		}
		q := &Quest{ID: id, Code: strings.TrimSpace(r[2]), Level: atoi(r[3]), Source: SourceNone, Race: -1, Menus: map[string][]MenuText{}}
		get := func(i int) string {
			if i < len(r) && r[i] != "xxx" {
				return strings.TrimSpace(r[i])
			}
			return ""
		}
		q.TextName, q.TextPay, q.TextPayCon, q.TextNN, q.TextNC = get(5), get(6), get(8), get(9), get(10)
		byCode[q.Code] = q
		ids[q.Code] = id
		quests = append(quests, q)
	}
	rep.QuestData = len(quests)

	// refqusetreward.txt (READ by value against the SN_PAYCON_ texts): 0
	// QuestID, 1 CodeName, 10 gold, 11 EXP, 12 skill EXP.
	for _, r := range in.Rewards {
		if len(r) < 13 {
			continue
		}
		q := byCode[strings.TrimSpace(r[1])]
		if q == nil {
			continue
		}
		q.Reward.Gold, q.Reward.Exp, q.Reward.SPExp = atoi64(r[10]), atoi64(r[11]), atoi64(r[12])
		q.Reward.FromTable = true
		rep.Rewards++
	}
	// refquestrewarditems.txt: 0 QuestID, 1 CodeName, 3 item code, 7 count
	// (INFERRED: 1 on every row of a retail archive's single-item rewards).
	for _, r := range in.RewardItems {
		if len(r) < 8 {
			continue
		}
		q := byCode[strings.TrimSpace(r[1])]
		if q == nil {
			continue
		}
		n := atoi(r[7])
		if n <= 0 {
			n = 1
		}
		q.Reward.Items = append(q.Reward.Items, RewardItem{Code: strings.TrimSpace(r[3]), Count: n})
		rep.RewardItems++
	}

	if len(in.ServerExe) > 0 {
		for _, m := range rttiQuest.FindAllSubmatch(in.ServerExe, -1) {
			if q := byCode[string(m[1])]; q != nil && q.Source == SourceNone {
				q.Source = SourceCompiled
			}
		}
	}

	if len(in.QuestSct) > 0 {
		calls, order, err := RunScripts(in.Define, in.QuestList, in.QuestSct, ids)
		if err != nil {
			return nil, rep, fmt.Errorf("quest: scripts: %w", err)
		}
		for _, code := range order {
			q := byCode[code]
			if q == nil {
				rep.NotInQuestData = append(rep.NotInQuestData, code)
				continue
			}
			if calls[code] == nil {
				rep.ScriptFailed = append(rep.ScriptFailed, code)
				continue
			}
			Apply(q, calls[code])
		}
	}
	if len(in.Decomp) > 0 {
		var fl func(uint32) (float64, bool)
		if len(in.ServerExe) > 0 {
			fl = ExeFloat(in.ServerExe)
		}
		for _, r := range in.Decomp {
			for code, cs := range ParseDecomp(r, fl) {
				if q := byCode[code]; q != nil && q.Source != SourceScript {
					ApplyCompiled(q, cs)
					rep.CompiledRead++
				}
			}
		}
	}
	for _, q := range quests {
		switch q.Source {
		case SourceScript:
			rep.Scripted++
		case SourceCompiled:
			rep.Compiled++
		}
	}
	rep.Coverage = NewCatalog(quests).Coverage()
	return quests, rep, nil
}
