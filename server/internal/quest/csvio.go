package quest

import (
	"encoding/csv"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// The exported catalogue is a directory of four CSVs (round 785), written by
// cmd/export-refdata -mode quests and read by cmd/server's -quests-dir. They
// are derived from the operator's own archives and server files; none ships
// with OpenSRO.
const (
	FileQuests      = "quests.csv"
	FileMissions    = "quest_missions.csv"
	FileMenus       = "quest_menus.csv"
	FileRewardItems = "quest_reward_items.csv"
)

var (
	QuestColumns = []string{"ID", "Code", "Level", "LevelArg2", "Source", "ConditionMask", "Race",
		"StartNPCs", "QuestNPCs", "CompleteNPCs", "MissionNPCs", "Requires", "RequiresAny",
		"AchievementLimit", "CompleteNum", "TextName", "TextPay", "TextPayCon", "TextNN", "TextNC",
		"Gold", "Exp", "SPExp", "SkillPoint", "RewardFromTable", "Unhandled"}
	MissionColumns    = []string{"Code", "Index", "Type", "Text", "Targets", "Rates", "Count", "MonsterClass", "Item", "NPC", "Deliver", "Talk"}
	MenuColumns       = []string{"Code", "NPC", "Key", "Text"}
	RewardItemColumns = []string{"Code", "Item", "Count", "Choice"}
)

func join(s []string) string { return strings.Join(s, ";") }
func split(s string) []string {
	if s == "" {
		return nil
	}
	return strings.Split(s, ";")
}
func itoa(i int) string  { return strconv.Itoa(i) }
func i64(i int64) string { return strconv.FormatInt(i, 10) }
func btoa(b bool) string {
	if b {
		return "1"
	}
	return "0"
}

// WriteDir writes quests into dir.
func WriteDir(dir string, quests []*Quest) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	sorted := append([]*Quest(nil), quests...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	var qr, mr, nr, ir [][]string
	for _, q := range sorted {
		qr = append(qr, []string{i64(q.ID), q.Code, itoa(q.Level), itoa(q.LevelArg2), q.Source, itoa(q.ConditionMask), itoa(q.Race),
			join(q.StartNPCs), join(q.QuestNPCs), join(q.CompleteNPCs), join(q.MissionNPCs), join(q.Requires), join(q.RequiresAny),
			itoa(q.AchievementLimit), itoa(q.CompleteNum), q.TextName, q.TextPay, q.TextPayCon, q.TextNN, q.TextNC,
			i64(q.Reward.Gold), i64(q.Reward.Exp), i64(q.Reward.SPExp), i64(q.Reward.SkillPoint), btoa(q.Reward.FromTable), join(q.Unhandled)})
		for _, m := range q.Missions {
			var rates, deliver []string
			for _, r := range m.Rates {
				rates = append(rates, strconv.FormatFloat(r, 'f', -1, 64))
			}
			for _, d := range m.Deliver {
				deliver = append(deliver, d.Code+":"+itoa(d.Count))
			}
			mr = append(mr, []string{q.Code, itoa(m.Index), itoa(m.Type), m.Text, join(m.Targets), join(rates), itoa(m.Count),
				itoa(m.MonsterClass), m.Item, m.NPC, join(deliver), join(m.Talk)})
		}
		npcs := make([]string, 0, len(q.Menus))
		for n := range q.Menus {
			npcs = append(npcs, n)
		}
		sort.Strings(npcs)
		for _, n := range npcs {
			for _, t := range q.Menus[n] {
				nr = append(nr, []string{q.Code, n, t.Key, t.Text})
			}
		}
		for _, it := range q.Reward.Items {
			ir = append(ir, []string{q.Code, it.Code, itoa(it.Count), btoa(it.Choice)})
		}
	}
	for _, f := range []struct {
		name string
		head []string
		rows [][]string
	}{{FileQuests, QuestColumns, qr}, {FileMissions, MissionColumns, mr}, {FileMenus, MenuColumns, nr}, {FileRewardItems, RewardItemColumns, ir}} {
		if err := writeCSV(filepath.Join(dir, f.name), f.head, f.rows); err != nil {
			return err
		}
	}
	return nil
}

func writeCSV(path string, head []string, rows [][]string) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	w := csv.NewWriter(f)
	if err := w.Write(head); err != nil {
		f.Close()
		return err
	}
	if err := w.WriteAll(rows); err != nil {
		f.Close()
		return err
	}
	return f.Close()
}

func readCSV(path string, head []string) ([][]string, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	r := csv.NewReader(f)
	r.FieldsPerRecord = -1
	got, err := r.Read()
	if err != nil {
		return nil, fmt.Errorf("%s: header: %w", path, err)
	}
	if len(got) < len(head) {
		return nil, fmt.Errorf("%s: header has %d columns, want %d (%s)", path, len(got), len(head), strings.Join(head, ","))
	}
	for i, h := range head {
		if got[i] != h {
			return nil, fmt.Errorf("%s: column %d is %q, want %q", path, i, got[i], h)
		}
	}
	var rows [][]string
	for {
		rec, err := r.Read()
		if err == io.EOF {
			return rows, nil
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		for len(rec) < len(head) {
			rec = append(rec, "")
		}
		rows = append(rows, rec)
	}
}

func atoi(s string) int {
	v, _ := strconv.Atoi(strings.TrimSpace(s))
	return v
}
func atoi64(s string) int64 {
	v, _ := strconv.ParseInt(strings.TrimSpace(s), 10, 64)
	return v
}

// LoadDir reads a catalogue WriteDir wrote.
func LoadDir(dir string) (*Catalog, error) {
	qrows, err := readCSV(filepath.Join(dir, FileQuests), QuestColumns)
	if err != nil {
		return nil, err
	}
	byCode := map[string]*Quest{}
	var quests []*Quest
	for _, r := range qrows {
		q := &Quest{ID: atoi64(r[0]), Code: r[1], Level: atoi(r[2]), LevelArg2: atoi(r[3]), Source: r[4],
			ConditionMask: atoi(r[5]), Race: atoi(r[6]), StartNPCs: split(r[7]), QuestNPCs: split(r[8]),
			CompleteNPCs: split(r[9]), MissionNPCs: split(r[10]), Requires: split(r[11]), RequiresAny: split(r[12]),
			AchievementLimit: atoi(r[13]), CompleteNum: atoi(r[14]), TextName: r[15], TextPay: r[16], TextPayCon: r[17],
			TextNN: r[18], TextNC: r[19], Menus: map[string][]MenuText{}, Unhandled: split(r[25])}
		q.Reward = Reward{Gold: atoi64(r[20]), Exp: atoi64(r[21]), SPExp: atoi64(r[22]), SkillPoint: atoi64(r[23]), FromTable: r[24] == "1"}
		if q.Code == "" {
			return nil, fmt.Errorf("%s: a row with no code", FileQuests)
		}
		byCode[q.Code] = q
		quests = append(quests, q)
	}
	mrows, err := readCSV(filepath.Join(dir, FileMissions), MissionColumns)
	if err != nil {
		return nil, err
	}
	for _, r := range mrows {
		q := byCode[r[0]]
		if q == nil {
			continue
		}
		m := Mission{Index: atoi(r[1]), Type: atoi(r[2]), Text: r[3], Targets: split(r[4]), Count: atoi(r[6]),
			MonsterClass: atoi(r[7]), Item: r[8], NPC: r[9], Talk: split(r[11])}
		for _, s := range split(r[5]) {
			f, _ := strconv.ParseFloat(s, 64)
			m.Rates = append(m.Rates, f)
		}
		for _, s := range split(r[10]) {
			code, cnt, _ := strings.Cut(s, ":")
			m.Deliver = append(m.Deliver, ItemCount{Code: code, Count: atoi(cnt)})
		}
		q.Missions = append(q.Missions, m)
	}
	nrows, err := readCSV(filepath.Join(dir, FileMenus), MenuColumns)
	if err != nil {
		return nil, err
	}
	for _, r := range nrows {
		if q := byCode[r[0]]; q != nil {
			q.Menus[r[1]] = append(q.Menus[r[1]], MenuText{Key: r[2], Text: r[3]})
		}
	}
	irows, err := readCSV(filepath.Join(dir, FileRewardItems), RewardItemColumns)
	if err != nil {
		return nil, err
	}
	for _, r := range irows {
		if q := byCode[r[0]]; q != nil {
			q.Reward.Items = append(q.Reward.Items, RewardItem{Code: r[1], Count: atoi(r[2]), Choice: r[3] == "1"})
		}
	}
	for _, q := range quests {
		sort.SliceStable(q.Missions, func(i, j int) bool { return q.Missions[i].Index < q.Missions[j].Index })
	}
	return NewCatalog(quests), nil
}
