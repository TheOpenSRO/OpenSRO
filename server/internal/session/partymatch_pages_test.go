package session

import (
	"fmt"
	"testing"

	"github.com/OpenSRO/OpenSRO/server/internal/party"
)

// TestMatchListPagesOverTheWire (round 752; the user, with thousands of swarm
// entries: "It only ever lets you see 1 page"): 50 characters each list an
// entry through 0x7069, and a 51st, holding none, asks for pages 0, 1 and 2
// (the last) and past the end through 0x706c. Each 0xb06c is the
// ShardManager's (SM 0x450d20 / 0x451630, READ): [1][page count][page
// index][n] then the rows, 23 to a page in entry-number order, a page index
// past the end answered as page 0.
func TestMatchListPagesOverTheWire(t *testing.T) {
	const listed = 50
	names := make([]string, 0, listed+1)
	for i := 0; i < listed; i++ {
		names = append(names, fmt.Sprintf("Bot%02d", i))
	}
	names = append(names, "Viewer")
	w, _ := newMatchWorldOf(t, names)
	for i := 0; i < listed; i++ {
		if e := register(t, w, names[i], party.PurposeHunting, 1, 110, party.FlagExpShare); e.Number != uint32(i+1) {
			t.Fatalf("%s's entry number %d, want %d", names[i], e.Number, i+1)
		}
	}
	for _, c := range []struct {
		ask, at      uint8
		n            int
		first, final uint32
	}{
		{0, 0, 23, 1, 23},
		{1, 1, 23, 24, 46},
		{2, 2, 4, 47, 50},   // the last page
		{3, 0, 23, 1, 23},   // past the end: page 0 (SM 0x450d20, `count <= index`)
		{255, 0, 23, 1, 23}, // the u8's top
	} {
		p := listPage(t, w.c["Viewer"], c.ask)
		if p.pages != 3 || p.at != c.at || len(p.rows) != c.n {
			t.Fatalf("page %d: %d pages, index %d, %d rows; want 3, %d, %d", c.ask, p.pages, p.at, len(p.rows), c.at, c.n)
		}
		if p.rows[0].Number != c.first || p.rows[len(p.rows)-1].Number != c.final {
			t.Fatalf("page %d: entries %d..%d, want %d..%d", c.ask, p.rows[0].Number, p.rows[len(p.rows)-1].Number, c.first, c.final)
		}
		for i := 1; i < len(p.rows); i++ {
			if p.rows[i].Number != p.rows[i-1].Number+1 {
				t.Fatalf("page %d: entry %d after %d", c.ask, p.rows[i].Number, p.rows[i-1].Number)
			}
		}
	}
	// An owner sees its own entry first on every page, one row more (SM
	// 0x450d20's `local_19 + 1`): Bot30's entry 31 heads page 0 and page 2.
	if p := listPage(t, w.c["Bot30"], 0); p.pages != 3 || len(p.rows) != 24 || p.rows[0].Number != 31 || p.rows[1].Number != 1 {
		t.Fatalf("Bot30's page 0: %d pages, %d rows, first %d", p.pages, len(p.rows), p.rows[0].Number)
	}
	if p := listPage(t, w.c["Bot30"], 2); p.at != 2 || len(p.rows) != 5 || p.rows[0].Number != 31 || p.rows[1].Number != 47 {
		t.Fatalf("Bot30's page 2: index %d, %d rows, first %d", p.at, len(p.rows), p.rows[0].Number)
	}
}
