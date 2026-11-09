package trigger

// Round 869 lane W3 (docs/protocol/forgotten_world.md 11 SERVER item 4):
// every Forgotten World script of the operator's export run to its boss on a
// fake layer -- the 22 INS_GOD_* worlds (Togui 63..68, Flame 69..76, Wreck
// inside 77, 78, 81, 82 and outside 79, 80, 83, 84), each hive killed once
// all its nests are awake, the codename conditions (the Wreck bosses) by a
// kill of that codename. Skipped without OPENSRO_GAMEWORLD_DIR and
// OPENSRO_TRIGGER_NESTS.

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/reftable"
)

func TestEveryGodScriptExport(t *testing.T) {
	dir, nestFile := os.Getenv("OPENSRO_GAMEWORLD_DIR"), os.Getenv("OPENSRO_TRIGGER_NESTS")
	if dir == "" || nestFile == "" {
		t.Skip("OPENSRO_GAMEWORLD_DIR / OPENSRO_TRIGGER_NESTS not set")
	}
	tables := map[string]*reftable.Table{}
	for _, n := range TableNames {
		if tab, err := reftable.ReadFile(filepath.Join(dir, n+".csv")); err == nil {
			tables[n] = tab
		}
	}
	ref, err := BuildRef(func(n string) *reftable.Table { return tables[n] })
	if err != nil {
		t.Fatal(err)
	}
	nt, err := reftable.ReadFile(nestFile)
	if err != nil {
		t.Fatal(err)
	}
	for world := 63; world <= 84; world++ {
		ts := ref.ForWorld(world)
		if len(ts) == 0 {
			t.Errorf("world %d: no triggers", world)
			continue
		}
		hives := map[int64]bool{}
		var codes []string
		entry := 0
		for _, tr := range ts {
			if tr.Event == EventWorldEntrance {
				entry++
			}
			for _, c := range tr.Conditions {
				switch c.Kind {
				case CondHiveKill:
					hives[c.Params.Int("HIVE_MONSTER_SELECT")] = true
				case CondMonsterKill:
					codes = append(codes, c.Params.Get("MONSTER_SELECT"))
				}
			}
		}
		nests := map[int64][3]int64{}
		for _, r := range nt.Rows {
			h := nt.Int(r, "dwHiveID")
			if hives[h] {
				nests[nt.Int(r, "dwNestID")] = [3]int64{h, nt.Int(r, "dwMaxTotalCount"), nt.Int(r, "btType")}
			}
		}
		f := &fakeLayer{nests: nests, players: []int64{7}}
		e := NewEngine(ts, f)
		// The entry notice: its two actions at once, in the data's binding
		// order (MEASURED for world 67: the banner, then the system line;
		// world 69 binds the system line first, and world 72 binds two
		// banners -- the data's own).
		e.Fire(Event{Kind: EventWorldEntrance, User: 7, UserLevel: 40})
		if entry != 1 || len(f.msgs) != 2 || !strings.Contains(f.msgs[0], "COMMON_MONSTER_KILL [7] @0s") ||
			!strings.Contains(f.msgs[1], "COMMON_MONSTER_KILL [7] @0s") ||
			(world <= 68 && (!strings.HasPrefix(f.msgs[0], "1 ") || !strings.HasPrefix(f.msgs[1], "2 "))) {
			t.Errorf("world %d: entry notices %q (%d entrance triggers)", world, f.msgs, entry)
		}
		killed := map[int64]bool{}
		for progress := true; progress; {
			progress = false
			var ids []int64
			for h := range hives {
				ids = append(ids, h)
			}
			sort.Slice(ids, func(i, j int) bool { return ids[i] < ids[j] })
			for _, h := range ids {
				if killed[h] {
					continue
				}
				awake := true
				for _, n := range f.nests {
					if n[0] == h && n[2] != 0 {
						awake = false
					}
				}
				if awake {
					killHive(e, f, h)
					killed[h] = true
					progress = true
				}
			}
		}
		for _, c := range codes {
			e.Fire(Event{Kind: EventMonsterKill, User: 7, UserLevel: 40, Monster: &Monster{ID: 99, Code: c}})
		}
		if len(killed) != len(hives) {
			t.Errorf("world %d: killed %d of %d hives; the rest never woke", world, len(killed), len(hives))
		}
		dormant := 0
		for _, n := range nests {
			if n[2] != 0 {
				dormant++
			}
		}
		if dormant != 0 {
			t.Errorf("world %d: %d nests never woken", world, dormant)
		}
		bossShown, bossKilled := false, false
		for _, m := range f.msgs {
			bossShown = bossShown || strings.Contains(m, "_BOSS ") || strings.Contains(m, "WRECK_OUT_BOSS")
			bossKilled = bossKilled || strings.Contains(m, "BOSS_KILL")
		}
		if !bossShown || !bossKilled || !strings.Contains(f.msgs[len(f.msgs)-1], "BOSS_KILL") {
			t.Errorf("world %d: boss shown %v, killed %v, last %q", world, bossShown, bossKilled, f.msgs[len(f.msgs)-1])
		}
		t.Logf("world %d: %d triggers, %d hives, %d nests woken, %d doors, %d notices, loads %v", world, len(ts), len(hives),
			len(f.woken), len(f.doors), len(f.msgs), f.loads)
	}
}
