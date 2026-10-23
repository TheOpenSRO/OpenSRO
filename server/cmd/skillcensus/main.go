// Command skillcensus counts, over an exported skills.csv (round 785: the
// Params column, CSV 91), how many player skill rows carry each Param code,
// China and Europe apart, and prints each code's implementation status in the
// server (the table below, kept beside the code that implements it).
//
//	skillcensus -skills-csv skills.csv            # the table
//	skillcensus -skills-csv skills.csv -code efr  # the rows carrying one code
//
// "Player rows" are what a player casts: every SKILL_CH_ / SKILL_EU_ row with
// a mastery and a learn cost (learnable, playerHoldRefusal's shape), the base
// attacks (ReqLearn_SP 0, no mastery: combat.BaseAttackSkillFor) and every
// chain link such a row reaches through Basic_ChainCode (the skill tick plays
// them, docs/TODO.md "Chain skills, link by link"). The counts are statistics
// of the operator's own data; no row is printed unless -code asks.
package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skillparam"
)

func main() {
	path := flag.String("skills-csv", os.Getenv("OPENSRO_SKILLS_CSV"), "an export-refdata -mode skills CSV with the Params column")
	code := flag.String("code", "", "list the player rows carrying this code (id, code name, values)")
	flag.Parse()
	f, err := os.Open(*path)
	if err != nil {
		fmt.Fprintln(os.Stderr, "skillcensus:", err)
		os.Exit(1)
	}
	rows, err := refdata.LoadSkillsCSV(f)
	f.Close()
	if err != nil {
		fmt.Fprintln(os.Stderr, "skillcensus:", err)
		os.Exit(1)
	}
	byID := map[int64]*refdata.Skill{}
	for i := range rows {
		byID[rows[i].ID] = &rows[i]
	}
	player := PlayerRows(byID)
	if *code != "" {
		ids := make([]int64, 0, len(player))
		for id := range player {
			ids = append(ids, id)
		}
		sort.Slice(ids, func(a, b int) bool { return ids[a] < ids[b] })
		for _, id := range ids {
			sk := byID[id]
			for _, v := range sk.Runs().All(skillparam.Code(*code)) {
				fmt.Printf("%d\t%s\t%v\n", id, sk.BasicCode, v)
			}
		}
		return
	}
	type count struct{ ch, eu int }
	counts := map[skillparam.Code]*count{}
	noParams := 0
	nCH, nEU := 0, 0
	for id := range player {
		sk := byID[id]
		if !sk.HasParams() {
			noParams++
			continue
		}
		eu := strings.HasPrefix(sk.BasicCode, "SKILL_EU_")
		if eu {
			nEU++
		} else {
			nCH++
		}
		for _, c := range sk.Runs().Codes() {
			if counts[c] == nil {
				counts[c] = &count{}
			}
			if eu {
				counts[c].eu++
			} else {
				counts[c].ch++
			}
		}
	}
	if noParams > 0 {
		fmt.Fprintf(os.Stderr, "skillcensus: %d rows carry no Params column: re-export with round 785's export-refdata\n", noParams)
	}
	codes := make([]skillparam.Code, 0, len(counts))
	for c := range counts {
		codes = append(codes, c)
	}
	sort.Slice(codes, func(a, b int) bool {
		x, y := counts[codes[a]], counts[codes[b]]
		if x.ch+x.eu != y.ch+y.eu {
			return x.ch+x.eu > y.ch+y.eu
		}
		return codes[a] < codes[b]
	})
	fmt.Printf("player rows: %d China, %d Europe\n", nCH, nEU)
	fmt.Printf("| code | CH | EU | status |\n|---|---:|---:|---|\n")
	for _, c := range codes {
		st, ok := Status[c]
		if !ok {
			st = "-"
		}
		fmt.Printf("| `%s` | %d | %d | %s |\n", c, counts[c].ch, counts[c].eu, st)
	}
}

// PlayerRows returns the ids a player casts (see the package comment).
func PlayerRows(byID map[int64]*refdata.Skill) map[int64]bool {
	out := map[int64]bool{}
	var walk func(id int64, depth int)
	walk = func(id int64, depth int) {
		sk, ok := byID[id]
		if !ok || out[id] || depth > 16 {
			return
		}
		out[id] = true
		if sk.BasicChainCode != 0 {
			walk(sk.BasicChainCode, depth+1)
		}
	}
	for id, sk := range byID {
		if !strings.HasPrefix(sk.BasicCode, "SKILL_CH_") && !strings.HasPrefix(sk.BasicCode, "SKILL_EU_") {
			continue
		}
		if sk.Mastery1 > 0 && sk.ReqLearnSP > 0 {
			walk(id, 0)
		}
	}
	for t := 1; t <= 15; t++ {
		if id := combat.BaseAttackSkillFor(t); id != 0 {
			walk(id, 0)
		}
	}
	return out
}
