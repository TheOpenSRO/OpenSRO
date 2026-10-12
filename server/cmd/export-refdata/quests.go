package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/OpenSRO/OpenSRO/server/internal/quest"
)

// exportQuests builds the quest catalogue (round 785, internal/quest) from
// the files named in args, recognised by base name (case-insensitive):
//
//	questdata.txt, refqusetreward.txt, refquestrewarditems.txt  (Media.pk2)
//	define.sct, questlist.sct, quest.sct                        (the server's Script/VIETNAM/)
//	sr_gameserver.exe                                           (optional: names the compiled quests)
//
// and writes quest.WriteDir's four CSVs into out.
func exportQuests(out string, args []string) error {
	if out == "" || out == "-" {
		return fmt.Errorf("-mode quests needs -out <directory>")
	}
	var in quest.Inputs
	for _, path := range args {
		base := strings.ToLower(filepath.Base(path))
		var err error
		switch base {
		case "questdata.txt":
			in.QuestData, err = readTable(path)
		case "refqusetreward.txt":
			in.Rewards, err = readTable(path)
		case "refquestrewarditems.txt":
			in.RewardItems, err = readTable(path)
		case "define.sct":
			in.Define, err = os.ReadFile(path)
		case "questlist.sct":
			in.QuestList, err = os.ReadFile(path)
		case "quest.sct":
			in.QuestSct, err = os.ReadFile(path)
		case "sr_gameserver.exe":
			in.ServerExe, err = os.ReadFile(path)
		default:
			return fmt.Errorf("unrecognised input %s", path)
		}
		if err != nil {
			return fmt.Errorf("reading %s: %w", path, err)
		}
	}
	if *questDecompDir != "" {
		files, _ := filepath.Glob(filepath.Join(*questDecompDir, "funcs_*.c"))
		sort.Strings(files)
		if len(files) == 0 {
			return fmt.Errorf("-decomp-dir %s holds no funcs_*.c", *questDecompDir)
		}
		for _, f := range files {
			fh, err := os.Open(f)
			if err != nil {
				return err
			}
			defer fh.Close()
			in.Decomp = append(in.Decomp, fh)
		}
	}
	if len(in.QuestData) == 0 {
		return fmt.Errorf("questdata.txt is required")
	}
	if len(in.QuestSct) > 0 && (len(in.Define) == 0 || len(in.QuestList) == 0) {
		return fmt.Errorf("quest.sct needs define.sct and questlist.sct beside it")
	}
	quests, rep, err := quest.Build(in)
	if err != nil {
		return err
	}
	if err := quest.WriteDir(out, quests); err != nil {
		return err
	}
	unhandled := map[string]int{}
	for _, q := range quests {
		for _, u := range q.Unhandled {
			unhandled[u]++
		}
	}
	var names []string
	for k := range unhandled {
		names = append(names, k)
	}
	sort.Strings(names)
	var parts []string
	for _, k := range names {
		parts = append(parts, fmt.Sprintf("%s=%d", k, unhandled[k]))
	}
	cv := rep.Coverage
	fmt.Fprintf(os.Stderr, "export-refdata: wrote %d quests to %s: %d scripted, %d compiled (%d read from the decompilation), %d questdata-only; %d playable, %d of them reachable (prerequisites playable too); %d reward rows, %d reward items\n",
		len(quests), out, rep.Scripted, rep.Compiled, rep.CompiledRead, cv.None, cv.Playable, cv.Reachable, rep.Rewards, rep.RewardItems)
	if len(rep.ScriptFailed) > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: %d listed quests whose setup failed: %s\n", len(rep.ScriptFailed), strings.Join(rep.ScriptFailed, " "))
	}
	if len(rep.NotInQuestData) > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: %d scripted quests not in questdata: %s\n", len(rep.NotInQuestData), strings.Join(rep.NotInQuestData, " "))
	}
	if len(rep.RewardDiffers) > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: %d quests whose script reward differs from the reward table (gold/EXP/skill EXP; the table is paid): %s\n",
			len(rep.RewardDiffers), strings.Join(rep.RewardDiffers, " "))
	}
	if len(parts) > 0 {
		fmt.Fprintf(os.Stderr, "export-refdata: setup calls not modelled (calls): %s\n", strings.Join(parts, " "))
	}
	if *questReport != "" {
		if err := writeQuestReport(*questReport, quests); err != nil {
			return err
		}
	}
	return nil
}

// writeQuestReport writes one line per quest: id, code, level, source,
// playable, reachable, and the first prerequisite blocking it.
func writeQuestReport(path string, quests []*quest.Quest) error {
	cat := quest.NewCatalog(quests)
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	sorted := append([]*quest.Quest(nil), quests...)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].ID < sorted[j].ID })
	fmt.Fprintln(f, "ID,Code,Level,Source,Playable,Reachable,BlockedBy")
	for _, q := range sorted {
		blocked := ""
		for _, code := range append(append([]string(nil), q.Requires...), q.RequiresAny...) {
			if !cat.Reachable(cat.ByCode[code]) {
				blocked = code
				break
			}
		}
		fmt.Fprintf(f, "%d,%s,%d,%s,%v,%v,%s\n", q.ID, q.Code, q.Level, q.Source, q.Playable(), cat.Reachable(q), blocked)
	}
	return nil
}
