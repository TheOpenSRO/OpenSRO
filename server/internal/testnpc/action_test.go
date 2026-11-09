package testnpc

import (
	"fmt"
	"reflect"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 872: the reset action -- the builtin's one action line, its bytes
// pinned, the refusals, and the Dimension Holes line's fourth tab, which
// lists the entrance ticket where the item table has its row and nothing
// where it has not.
func TestResetActionAndTicketTab(t *testing.T) {
	d, err := Builtin()
	if err != nil {
		t.Fatal(err)
	}
	want := []Action{{ID: 1, Label: "Reset Forgotten World Timers", Confirm: "UIIT_STT_DUNGEON_FREE_TICKET_ENTER_FORGOTTEN", Do: ActionResetForgottenWorld}}
	if !reflect.DeepEqual(d.Actions, want) {
		t.Fatalf("actions %+v", d.Actions)
	}
	holes := d.Lines[len(d.Lines)-1]
	if len(holes.Tabs) != 4 || holes.Tabs[3].Label != "Ticket" {
		t.Fatalf("the Dimension Holes line's tabs %+v", holes.Tabs)
	}
	items := []*refdata.Item{
		item(35883, "ITEM_ETC_TELEPORT_HOLE_TOGUI_35_50_LEVEL_1", [4]int{3, 3, 12, 7}, 0),
		item(36780, "ITEM_MALL_DUNGEON_FREE_TICKET_EGYPT", [4]int{3, 3, 13, 22}, 0),
		item(36781, "ITEM_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD", [4]int{3, 3, 13, 23}, 0),
		item(38295, "ITEM_PRE_MALL_DUNGEON_FREE_TICKET_FORGOTTEN_WORLD", [4]int{3, 3, 13, 23}, 0),
	}
	s := d.Resolve(items)
	last := s.Lines[len(s.Lines)-1]
	if got := last.Tabs[3].ItemIDs; !reflect.DeepEqual(got, []uint32{36781, 38295}) {
		t.Errorf("the Ticket tab %v, want both tickets", got)
	}
	if got := last.Tabs[0].ItemIDs; !reflect.DeepEqual(got, []uint32{35883}) {
		t.Errorf("the Togui tab %v", got)
	}
	if got := d.Resolve(items[:2]).Lines[len(s.Lines)-1].Tabs[3].ItemIDs; len(got) != 0 {
		t.Errorf("the Ticket tab without the rows: %v", got)
	}
	if a, ok := s.Action(1); !ok || a.Do != ActionResetForgottenWorld {
		t.Errorf("Shop.Action(1) %+v %v", a, ok)
	}
	b := (&Shop{Actions: []Action{{ID: 1, Label: "R", Confirm: "K", Do: ActionResetForgottenWorld}}}).EncodeActions(0x7f000123)
	if got := fmt.Sprintf("% x", b); got != "23 01 00 7f 01 01 01 00 52 01 00 4b" {
		t.Fatalf("OpNpcActionDef % x", b)
	}
	uid, acts, err := DecodeActions(b)
	if err != nil || uid != 0x7f000123 || !reflect.DeepEqual(acts, []Action{{ID: 1, Label: "R", Confirm: "K"}}) {
		t.Fatalf("decode %d %+v %v", uid, acts, err)
	}
	if _, _, err := DecodeActions(b[:len(b)-1]); err == nil {
		t.Fatal("a truncated OpNpcActionDef decoded")
	}
	if (&Shop{}).EncodeActions(1) != nil {
		t.Error("a shop with no action encoded one")
	}
	if u, id, err := DecodeAction(EncodeAction(0x7f000123, 1)); err != nil || u != 0x7f000123 || id != 1 {
		t.Errorf("OpNpcAction %x %d %v", u, id, err)
	}
	line := `"lines":[{"label":"a","tabs":[{"label":"t","rules":[{}]}]}]`
	for _, bad := range []string{
		`{"name":"x","model":"m",` + line + `,"actions":[{"id":0,"label":"a","do":"reset_forgotten_world"}]}`,
		`{"name":"x","model":"m",` + line + `,"actions":[{"id":1,"label":"","do":"reset_forgotten_world"}]}`,
		`{"name":"x","model":"m",` + line + `,"actions":[{"id":1,"label":"a","do":"nope"}]}`,
		`{"name":"x","model":"m",` + line + `,"actions":[{"id":1,"label":"a","do":"reset_forgotten_world"},{"id":1,"label":"b","do":"reset_forgotten_world"}]}`,
	} {
		if _, err := Parse([]byte(bad)); err == nil {
			t.Errorf("Parse accepted %s", bad)
		}
	}
}
