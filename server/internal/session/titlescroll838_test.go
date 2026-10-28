package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"net"
	"testing"

	"github.com/TheOpenSRO/OpenSRO/server/internal/mall"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
)

// Round 838 lane 6: the title scrolls and the Random Wing Scroll
// (titlescroll.go) through the use-item handler on real sockets, on the
// service scrolls' fixture. Every row is synthetic, named as the archive
// names them; no archive data.

const (
	tidTitle196    = 9301
	tidTitle1      = 9302
	tidTitleCustom = 9303
	tidRandomWing  = 9304
	tidWing09      = 9305
	tidWing33      = 9306
)

// titleItems adds the lane's rows to the fixture's item table.
func titleItems(t *testing.T) {
	t.Helper()
	refs := serviceRT.Load().Items.(*refdata.MemStore)
	scroll := func(id int64, code string, t4 int) refdata.Item {
		return refdata.Item{ID: id, CodeName: code, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: t4, MaxStack: 1, CanUse: true}
	}
	wing := scroll(tidRandomWing, "ITEM_RANDOM_WING", 1)
	wing.Desc1 = "SKILL_CELESTIUS_SILK_SCROLL_10" // the row's placeholder skill
	if err := refs.ImportItems(context.Background(), []refdata.Item{
		scroll(tidTitle196, "ITEM_TITLE_196", 14), scroll(tidTitle1, "ITEM_TITLE_1", 14),
		scroll(tidTitleCustom, "ITEM_TITLE_255", 14), wing,
		scroll(tidWing09, "ITEM_VSROEDITORCOM_VISUAL_09", 14), scroll(tidWing33, "ITEM_VSROEDITORCOM_VISUAL_33", 14),
	}); err != nil {
		t.Fatal(err)
	}
}

// useText uses Aria's slot with a custom title's text.
func (f *svcFixture) useText(slot int, text string) *UseItemResult {
	f.t.Helper()
	req := &UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot), Option: UseOptionCustomTitle, Text: text}
	p := nextOpAfter(f.t, f.a, f.ra, OpUseItem, req.Encode(), OpUseItemResult)
	r, err := DecodeUseItemResult(p.Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return r
}

func TestRound838TitleScrollKinds(t *testing.T) {
	for code, level := range map[string]int64{"ITEM_TITLE_1": 1, "ITEM_TITLE_196": 196, "ITEM_TITLE_255": 255} {
		if s, ok := serviceScrollOf(&refdata.Item{CodeName: code}); !ok || s.kind != svcTitle || s.amount != level {
			t.Fatalf("%s: %+v %v", code, s, ok)
		}
	}
	for _, code := range []string{"ITEM_TITLE_0", "ITEM_TITLE_256", "ITEM_TITLE_", "ITEM_TITLE_X"} {
		if _, ok := serviceScrollOf(&refdata.Item{CodeName: code}); ok {
			t.Fatalf("%s is a scroll", code)
		}
	}
	// The colour scrolls stay lane 3's.
	if s, _ := serviceScrollOf(&refdata.Item{CodeName: "ITEM_TITLE_COLOR_SKY"}); s.kind != svcTitleColour {
		t.Fatalf("ITEM_TITLE_COLOR_SKY: %+v", s)
	}
	if s, _ := serviceScrollOf(&refdata.Item{CodeName: "ITEM_RANDOM_WING"}); s.kind != svcRandomWing {
		t.Fatalf("ITEM_RANDOM_WING: %+v", s)
	}
	// The placeholder skills are no skill items; a real buff's row is.
	skillItem := func(skill string) bool {
		return isSkillItem(&refdata.Item{TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 1, Desc1: skill})
	}
	for _, s := range []string{"SKILL_CELESTIUS_SILK_SCROLL_10", "SKILL_CELESTIUS_SILK_SCROLL_2500", "SKILL_CRATE_ALPH", "SKILL_SILK_LOTTERY"} {
		if skillItem(s) {
			t.Fatalf("%s is cast", s)
		}
	}
	for _, s := range []string{"SKILL_NEW_GODBLESS_RED", "SKILL_SPEED_105", "SKILL_CELESTIUS_SILKTICKET_GOLD"} {
		if !skillItem(s) {
			t.Fatalf("%s is not cast", s)
		}
	}
	if len(randomWingPool) != 20 || randomWingPool[0] != "ITEM_VSROEDITORCOM_VISUAL_09" || randomWingPool[2] != "ITEM_VSROEDITORCOM_VISUAL_12" {
		t.Fatalf("pool %v", randomWingPool)
	}
}

func TestRound838CustomTitleText(t *testing.T) {
	for in, want := range map[string]string{"Sky Walker": "Sky Walker", "  Pleveling #1 ": "Pleveling #1", "A-Z_.'!#&+?:()": "A-Z_.'!#&+?:()"} {
		if got, why := customTitleOf(in); got != want || why != "" {
			t.Fatalf("%q: %q %q", in, got, why)
		}
	}
	for in, why := range map[string]string{"": customTitleEmpty, "   ": customTitleEmpty, "Twenty-one characters": customTitleLong,
		"Two  spaces": customTitleChars, "*alias": customTitleChars, "<b>": customTitleChars, "Führer": customTitleChars} {
		if _, got := customTitleOf(in); got != why {
			t.Fatalf("%q: %q, want %q", in, got, why)
		}
	}
}

func TestRound838TitleScroll(t *testing.T) {
	f := setupService(t)
	titleItems(t)
	ctx := context.Background()
	t.Cleanup(func() { titles.Delete(f.ariaID) })
	hwan := func(c net.Conn, r *bufio.Reader) []byte { return nextOp(t, c, r, OpHwanLevel).Data }
	slot := f.give(tidTitle196, 1)
	if r := f.use(slot); r.Error != "" || r.Remaining != 0 {
		t.Fatalf("196: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "Your title has been changed." {
		t.Fatalf("line %q", l)
	}
	want := encodeHwanLevel(f.ariaID, 196)
	if got := hwan(f.a, f.ra); string(got) != string(want) {
		t.Fatalf("Aria's 0x30DF % x", got)
	}
	if got := hwan(f.b, f.rb); string(got) != string(want) {
		t.Fatalf("Bram's 0x30DF % x", got)
	}
	if l, c, _ := f.chars.Title(ctx, f.ariaID); l != 196 || c != "" || hwanLevelOf(f.ariaID) != 196 {
		t.Fatalf("stored %d %q, cached %d", l, c, hwanLevelOf(f.ariaID))
	}
	if f.slotOf(tidTitle196) >= 0 {
		t.Fatal("the scroll was not spent")
	}
	// The same title again is refused and the scroll kept.
	slot = f.give(tidTitle196, 1)
	if r := f.use(slot); r.Error != "You already have that title." || f.slotOf(tidTitle196) < 0 {
		t.Fatalf("again: %+v", r)
	}
	// Another replaces it.
	slot = f.give(tidTitle1, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("1: %+v", r)
	}
	if got := hwan(f.b, f.rb); string(got) != string(encodeHwanLevel(f.ariaID, 1)) {
		t.Fatalf("Bram's 0x30DF % x", got)
	}
	// The custom title: refused without its text or with a bad one, the
	// scroll kept; with it, the text then the level to both.
	slot = f.give(tidTitleCustom, 1)
	if r := f.use(slot); r.Error != customTitleNone {
		t.Fatalf("no text: %+v", r)
	}
	if r := f.useText(slot, "Two  spaces"); r.Error != customTitleChars || f.slotOf(tidTitleCustom) < 0 {
		t.Fatalf("bad text: %+v", r)
	}
	if r := f.useText(slot, " Sky Walker "); r.Error != "" {
		t.Fatalf("custom: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != `Your title is now "Sky Walker".` {
		t.Fatalf("line %q", l)
	}
	if got := nextOp(t, f.b, f.rb, OpCustomTitle).Data; string(got) != string(encodeCustomTitle(f.ariaID, "Sky Walker")) {
		t.Fatalf("Bram's 0x01A8 % x", got)
	}
	if got := hwan(f.b, f.rb); string(got) != string(encodeHwanLevel(f.ariaID, 255)) {
		t.Fatalf("Bram's 0x30DF % x", got)
	}
	if l, c, _ := f.chars.Title(ctx, f.ariaID); l != 255 || c != "Sky Walker" {
		t.Fatalf("stored %d %q", l, c)
	}
	// A third player arriving gets the level in Aria's record and the text
	// after it.
	f.accounts.Add("carol", "pw3")
	if _, err := f.chars.Create(ctx, 3, "Cyra"); err != nil {
		t.Fatal(err)
	}
	c, r := f.enter("carol", "pw3", "Cyra")
	var recs []pcspawn.Record
	for recs == nil {
		p := readFrame737(t, c, r)
		if p.Opcode == npcspawn.OpSingleSpawn || p.Opcode == npcspawn.OpGroupBegin {
			recs = playerSpawnsIn(t, p, func() *proto.Packet { return readFrame737(t, c, r) })
		}
	}
	found := false
	for _, rec := range recs {
		if rec.UID == uint32(f.ariaID) {
			found = rec.HwanLevel == 255
		}
	}
	if !found {
		t.Fatalf("Aria's record in %+v", recs)
	}
	if got := nextOp(t, c, r, OpCustomTitle).Data; string(got) != string(encodeCustomTitle(f.ariaID, "Sky Walker")) {
		t.Fatalf("Cyra's 0x01A8 % x", got)
	}
	// The next entry reads it back from the store.
	titles.Delete(f.ariaID)
	titleAtEntry(ctx, f.chars, f.ariaID)
	if v, ok := titles.Load(f.ariaID); !ok || v.(titleEntry) != (titleEntry{level: 255, custom: "Sky Walker"}) {
		t.Fatalf("at entry %+v", v)
	}
	// A plain title after the custom one clears its text.
	slot = f.give(tidTitle1, 1)
	if r := f.use(slot); r.Error != "" {
		t.Fatalf("1 again: %+v", r)
	}
	if l, c, _ := f.chars.Title(ctx, f.ariaID); l != 1 || c != "" || customTitleFrame(f.ariaID) != nil {
		t.Fatalf("stored %d %q", l, c)
	}
}

func TestRound838RandomWing(t *testing.T) {
	f := setupService(t)
	titleItems(t)
	ctx := context.Background()
	f.roll = 1 // the second of the two wings the table holds
	slot := f.give(tidRandomWing, 1)
	if r := f.use(slot); r.Error != "" || r.Remaining != 0 {
		t.Fatalf("use: %+v", r)
	}
	if l := f.line(f.a, f.ra); l != "A random wing has been placed in your Item Chest." {
		t.Fatalf("line %q", l)
	}
	got := nextOp(t, f.a, f.ra, mall.OpChestReceived).Data
	if binary.LittleEndian.Uint32(got) != tidWing33 {
		t.Fatalf("0x00D6 % x", got)
	}
	es, _ := f.store.Chest(ctx, f.ariaID)
	if len(es) != 1 || es[0].ItemID != tidWing33 || es[0].Quantity != 1 || es[0].From != randomWingFrom {
		t.Fatalf("chest %+v", es)
	}
	if f.slotOf(tidRandomWing) >= 0 {
		t.Fatal("the scroll was not spent")
	}
}
