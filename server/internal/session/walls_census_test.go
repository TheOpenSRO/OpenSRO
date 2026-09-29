package session

import (
	"os"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/buff"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// TestToggleAndWallCensus (round 640) walks EVERY row of the player's own
// skill export when SRREVAMP_SKILLS_CSV names it, and is skipped otherwise
// (CI has no game data). Run it with -v for the report.
//
// Every row carrying 'onff' is started as its own caster's buff on an empty
// book, and the census requires what the drain rule needs of it: action kind
// 3, a caster buff (startsCasterBuff), no 'dura' -- so SkillAction_Buff's
// sub-state 2 drains it (0x58522e..0x585242) -- and a drain of onff[1] MP due
// strictly after onff[0] ms. Every row carrying 'pw' must also carry 'onff'
// and a mask of 7 or 11, and its wall must take a blow of a type it covers
// and refuse one it does not. The families are listed.
func TestToggleAndWallCensus(t *testing.T) {
	path := os.Getenv("SRREVAMP_SKILLS_CSV")
	if path == "" {
		t.Skip("SRREVAMP_SKILLS_CSV not set; the census needs the player's own skill export")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	rows, err := refdata.LoadSkillsCSV(f)
	if err != nil {
		t.Fatal(err)
	}
	t0 := time.Date(2026, 9, 29, 12, 0, 0, 0, time.UTC)
	families := map[string]int{}
	onffRows, wallRows := 0, 0
	masks := map[int64]int{}
	for i := range rows {
		r := &rows[i]
		v, onff := r.BuffParam("onff")
		if r.HasWall() {
			wallRows++
			masks[r.Pw0]++
			if !onff {
				t.Errorf("%s: 'pw' without 'onff'", r.BasicCode)
			}
			if r.Pw0 != 7 && r.Pw0 != 11 {
				t.Errorf("%s: 'pw' mask %d", r.BasicCode, r.Pw0)
			}
			if r.Pw1 <= 0 {
				t.Errorf("%s: wall HP %d", r.BasicCode, r.Pw1)
			}
		}
		if !onff {
			continue
		}
		onffRows++
		fam := r.BasicCode
		if k := strings.LastIndex(fam, "_"); k > 0 {
			fam = fam[:k]
		}
		families[fam]++
		if len(v) != 2 || v[0] <= 0 || v[1] <= 0 {
			t.Errorf("%s: 'onff' %v", r.BasicCode, v)
			continue
		}
		if r.ActionKind != 3 || !startsCasterBuff(r) || r.DuraMs > 0 {
			t.Errorf("%s: kind %d, caster buff %v, dura %d -- not a drained toggle", r.BasicCode, r.ActionKind, startsCasterBuff(r), r.DuraMs)
			continue
		}
		b := buff.NewBooks(PlayerRunSpeed)
		rec, _, refused, _ := b.Start(1, buffSpec(r, 1), t0)
		if refused != buff.NotRefused {
			t.Errorf("%s: refused on an empty book", r.BasicCode)
			continue
		}
		if rec.DrainDue(t0.Add(time.Duration(v[0])*time.Millisecond)) || !rec.DrainDue(t0.Add(time.Duration(v[0]+1)*time.Millisecond)) {
			t.Errorf("%s: the drain is not due strictly after %d ms", r.BasicCode, v[0])
		}
		if r.HasWall() {
			covered, other := buff.TypeMagical, buff.TypePhysical
			if r.Pw0 == 7 {
				covered, other = buff.TypePhysical, buff.TypeMagical
			}
			if _, ok := b.HitWall(1, other, func(buff.Wall) int { return 1 }); ok {
				t.Errorf("%s: the wall took a blow of a type it does not cover", r.BasicCode)
			}
			hit, ok := b.HitWall(1, covered, func(w buff.Wall) int { return w.HP })
			if !ok || !hit.Broke || hit.Max != int(r.Pw1) {
				t.Errorf("%s: a covered blow of the wall's whole HP: %+v %v", r.BasicCode, hit, ok)
			}
		}
	}
	var names []string
	for k, n := range families {
		names = append(names, k+" "+itoa(n))
	}
	sort.Strings(names)
	t.Logf("%d rows carry 'onff', %d of them 'pw' (masks %v), in %d families:\n  %s",
		onffRows, wallRows, masks, len(families), strings.Join(names, "\n  "))
	if onffRows == 0 {
		t.Fatal("no 'onff' row: the export carries no BuffParams column")
	}
	if wallRows == 0 {
		t.Fatal("no 'pw' row: re-export with this round's export-refdata (columns 83..86)")
	}
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	var b []byte
	for n > 0 {
		b = append([]byte{byte('0' + n%10)}, b...)
		n /= 10
	}
	return string(b)
}
