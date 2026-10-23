package session

import (
	"bufio"
	"context"
	"os"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/statuseffect"
)

// Round 786: the cure pills through UseItemHandler (curepill.go). The rows
// are the retail ones' shapes (MEASURED, itemdata_*.txt on the RE box):
// ITEM_ETC_CURE_ALL_01 (55) 3/3/2/6 with Param1..6 = 36, ITEM_ETC_CURE_RANDOM_01
// (10374) 3/3/2/1 with Param1 0x17fafc0, Param2 3, Param3 100 and a
// COOLTIME:0x0 of 20000 ms, ITEM_COS_P_CURE_ALL_01 (9226) 3/3/2/7 and
// ITEM_MALL_CURE_SUPERSET_1_BAG (29414) 3/3/2/8.
const (
	pillUniversal    = 55
	pillPurification = 10374
	pillPet          = 9226
	pillBag          = 29414
)

func curePillRows() []refdata.Item {
	return []refdata.Item{
		{ID: pillUniversal, CodeName: "ITEM_ETC_CURE_ALL_01", MaxStack: 500, TypeID1: 3, TypeID2: 3, TypeID3: 2, TypeID4: 6,
			RestoreHP: 36, RestoreHPPct: 36, RestoreMP: 36, RestoreMPPct: 36, Param5: 36, Param6: 36, CanUse: true},
		{ID: pillPurification, CodeName: "ITEM_ETC_CURE_RANDOM_01", MaxStack: 500, TypeID1: 3, TypeID2: 3, TypeID3: 2, TypeID4: 1,
			RestoreHP: 25145280, RestoreHPPct: 3, RestoreMP: 100, RestoreMPPct: 20000, CooltimeMs: 20000, CanUse: true},
		{ID: pillPet, CodeName: "ITEM_COS_P_CURE_ALL_01", MaxStack: 500, TypeID1: 3, TypeID2: 3, TypeID3: 2, TypeID4: 7,
			RestoreHP: 36, RestoreHPPct: 36, RestoreMP: 36, RestoreMPPct: 36, Param5: 36, Param6: 36, CanUse: true},
		{ID: pillBag, CodeName: "ITEM_MALL_CURE_SUPERSET_1_BAG", MaxStack: 10000, TypeID1: 3, TypeID2: 3, TypeID3: 2, TypeID4: 8,
			RestoreHP: -1, RestoreHPPct: -1, RestoreMP: -1, RestoreMPPct: -1, Param5: 0xffffffff, Param6: 0xffffffff, CanUse: true},
	}
}

type pillHarness struct {
	t     *testing.T
	ctx   context.Context
	inv   *inventory.MemStore
	char  int64
	clock *time.Time
	send  func(op uint16, data []byte) *proto.Packet
}

func newPillHarness(t *testing.T, rows []refdata.Item) *pillHarness {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, rows); err != nil {
		t.Fatalf("import: %v", err)
	}
	inv := inventory.NewMemStore(items)
	for _, r := range rows {
		if err := inv.AddItem(ctx, c.ID, r.ID, 5); err != nil {
			t.Fatalf("add %d: %v", r.ID, err)
		}
	}
	clock := time.Date(2026, 10, 12, 12, 0, 0, 0, time.UTC)
	h := &pillHarness{t: t, ctx: ctx, inv: inv, char: c.ID, clock: &clock}
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return *h.clock }
	t.Cleanup(func() {
		statusFX.mu.Lock()
		delete(statusFX.pcs, c.ID)
		statusFX.mu.Unlock()
	})
	handle := gateway.Chain(LoginHandler(accounts), UseItemHandler(chars, inv, items, mana.NewTracker(), nil, nil, nil, nil, nil, nil, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	h.send = func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	if lr, err := DecodeLoginResult(h.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	return h
}

func (h *pillHarness) qty(id int64) (index, qty int) {
	slots, err := h.inv.List(h.ctx, h.char)
	if err != nil {
		h.t.Fatalf("list: %v", err)
	}
	for _, sl := range slots {
		if sl.ItemID == id {
			return sl.Index, sl.Quantity
		}
	}
	return -1, 0
}

func (h *pillHarness) use(id int64) *UseItemResult {
	h.t.Helper()
	slot, _ := h.qty(id)
	res, err := DecodeUseItemResult(h.send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
	if err != nil {
		h.t.Fatalf("decode: %v", err)
	}
	return res
}

// afflict puts records on the character's holder, as a monster's blow does.
func (h *pillHarness) afflict(recs ...statuseffect.Record) {
	statusFX.mu.Lock()
	defer statusFX.mu.Unlock()
	hd := statusFX.pcs[h.char]
	if hd == nil {
		hd = &statuseffect.Holder{}
		statusFX.pcs[h.char] = hd
	}
	for _, r := range recs {
		hd.Put(r)
	}
}

func (h *pillHarness) holds(slot int) bool {
	statusFX.mu.Lock()
	defer statusFX.mu.Unlock()
	hd := statusFX.pcs[h.char]
	return hd != nil && hd.Holds(slot)
}

// TestRound786UniversalPillCuresTheElementalStates: a universal pill ends an
// elemental state its Params wind past their duration, leaves a
// non-elemental one, is spent, and locks its kind (bit 0x40) for 1.1 s.
func TestRound786UniversalPillCuresTheElementalStates(t *testing.T) {
	h := newPillHarness(t, curePillRows())
	now := statusFX.ms(time.Now())
	h.afflict(
		statuseffect.Record{Code: "bu", Slot: statuseffect.SlotBurn, StartMs: now, DurationMs: 20000},   // 36 x 750 = 27 s back
		statuseffect.Record{Code: "ps", Slot: statuseffect.SlotPoison, StartMs: now, DurationMs: 30000}, // 36 x 1000 = 36 s back
		statuseffect.Record{Code: "se", Slot: 6, Level: 2, StartMs: now, DurationMs: 30000},
	)
	_, before := h.qty(pillUniversal)
	res := h.use(pillUniversal)
	if res.Error != "" {
		t.Fatalf("refused: %q", res.Error)
	}
	if res.Remaining != int32(before-1) || res.MaxHP != 0 {
		t.Fatalf("reply %+v: want remaining %d and no bars", res, before-1)
	}
	if _, after := h.qty(pillUniversal); after != before-1 {
		t.Fatalf("%d left, want %d", after, before-1)
	}
	if h.holds(statuseffect.SlotBurn) || h.holds(statuseffect.SlotPoison) {
		t.Fatal("the pill left an elemental state its Params cover")
	}
	if !h.holds(6) {
		t.Fatal("the universal pill ended a sleep: it reaches slots 0..5 only")
	}
	if res := h.use(pillUniversal); res.Error != reuseDelayRefusal {
		t.Fatalf("a second pill at once: %+v, want the 0x185b refusal", res)
	}
	*h.clock = h.clock.Add(1100 * time.Millisecond)
	if res := h.use(pillUniversal); res.Error != "" {
		t.Fatalf("a pill 1.1 s later: refused %q", res.Error)
	}
}

// TestRound786UniversalPillWithNothingToCureIsSpent: slot 308 answers 1
// whatever it cured (0x49b88c), so DoJob spends the pill.
func TestRound786UniversalPillWithNothingToCureIsSpent(t *testing.T) {
	h := newPillHarness(t, curePillRows())
	_, before := h.qty(pillUniversal)
	if res := h.use(pillUniversal); res.Error != "" {
		t.Fatalf("refused: %q", res.Error)
	}
	if _, after := h.qty(pillUniversal); after != before-1 {
		t.Fatalf("%d left, want %d", after, before-1)
	}
}

// TestRound786PurificationPillCuresOneNonElementalState: one held state the
// mask names ends (chance 100 at or under level 3); the kind lock (0x100,
// outside the byte the gate reads) never refuses, but the row's COOLTIME
// (20000 ms) does.
func TestRound786PurificationPillCuresOneNonElementalState(t *testing.T) {
	h := newPillHarness(t, curePillRows())
	now := statusFX.ms(time.Now())
	h.afflict(
		statuseffect.Record{Code: "se", Slot: 6, Level: 2, StartMs: now, DurationMs: 30000},
		statuseffect.Record{Code: "st", Slot: 14, Level: 1, StartMs: now, DurationMs: 30000}, // stun: not in the mask
		statuseffect.Record{Code: "bu", Slot: statuseffect.SlotBurn, StartMs: now, DurationMs: 30000},
	)
	if res := h.use(pillPurification); res.Error != "" {
		t.Fatalf("refused: %q", res.Error)
	}
	if h.holds(6) {
		t.Fatal("the sleep is still held")
	}
	if !h.holds(14) || !h.holds(statuseffect.SlotBurn) {
		t.Fatal("the purification pill ended a state outside its mask")
	}
	if res := h.use(pillPurification); res.Error != reuseDelayRefusal {
		t.Fatalf("a second pill at once: %+v, want the COOLTIME refusal", res)
	}
	*h.clock = h.clock.Add(19999 * time.Millisecond)
	if res := h.use(pillPurification); res.Error != reuseDelayRefusal {
		t.Fatalf("at 19.999 s: %+v, want refused", res)
	}
	*h.clock = h.clock.Add(time.Millisecond)
	if res := h.use(pillPurification); res.Error != "" {
		t.Fatalf("at 20 s: refused %q", res.Error)
	}
}

// TestRound786PurificationKindLockNeverGates: FUN_004eb410 answers from the
// BYTE at [pc+0x30]+8, so the kind-1 bit 0x100 cannot refuse; a row without
// a COOLTIME is usable again at once.
func TestRound786PurificationKindLockNeverGates(t *testing.T) {
	rows := curePillRows()
	rows[1].CooltimeMs = 0
	h := newPillHarness(t, rows)
	for i := 0; i < 2; i++ {
		if res := h.use(pillPurification); res.Error != "" {
			t.Fatalf("use %d: refused %q", i, res.Error)
		}
	}
}

// TestRound786PetPillAndCureBagStayRefused: the pets' pill takes DoJob's
// slot 327 and the mall's cure bag is OPEN; both are refused and kept.
func TestRound786PetPillAndCureBagStayRefused(t *testing.T) {
	h := newPillHarness(t, curePillRows())
	for _, id := range []int64{pillPet, pillBag} {
		_, before := h.qty(id)
		if res := h.use(id); res.Error == "" {
			t.Fatalf("item %d was used", id)
		}
		if _, after := h.qty(id); after != before {
			t.Fatalf("item %d consumed", id)
		}
	}
}

// TestRound786CurePillRule: the rule each pill hands FUN_004a56c0.
func TestRound786CurePillRule(t *testing.T) {
	rows := curePillRows()
	r, bit, d := curePillRule(&rows[0])
	if !r.HasElem || r.HasCurl || r.Elem != [6]uint32{36, 36, 36, 36, 36, 36} || bit != 0x40 || d != 1100*time.Millisecond {
		t.Fatalf("universal: %+v bit %#x delay %v", r, bit, d)
	}
	r, bit, d = curePillRule(&rows[1])
	if !r.HasCurl || r.CurlMask != 0x17fafc0 || r.CurlChance != 100 || r.CurlLevel != 3 || r.Rcur != 1 || bit != 0x100 || d != 20100*time.Millisecond {
		t.Fatalf("purification: %+v bit %#x delay %v", r, bit, d)
	}
}

// TestRound786EveryCurePillRow runs every TypeID 3/3/2 row of a real export
// (OPENSRO_ITEMS_CSV; skipped without one) through the handler against a
// character holding all six elemental states and five non-elemental ones at
// level 1: a universal pill must end every elemental state its Params cover
// and leave the rest, a purification pill must end exactly one state of its
// mask, and the pets' pills and the cure bags must be refused and kept. It
// prints the census.
func TestRound786EveryCurePillRow(t *testing.T) {
	path := os.Getenv("OPENSRO_ITEMS_CSV")
	if path == "" {
		t.Skip("OPENSRO_ITEMS_CSV not set")
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	all, err := refdata.LoadItemsCSV(f)
	f.Close()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	var rows []refdata.Item
	for _, it := range all {
		if it.TypeID1 == 3 && it.TypeID2 == 3 && it.TypeID3 == 2 {
			it.CooltimeMs = 0 // each row is used once; the cooltime is its own test
			rows = append(rows, it)
		}
	}
	if len(rows) == 0 {
		t.Fatal("no TypeID 3/3/2 rows in the export")
	}
	census := map[string]int{}
	for _, row := range rows {
		h := newPillHarness(t, []refdata.Item{row})
		now := statusFX.ms(time.Now())
		var recs []statuseffect.Record
		for slot := 0; slot <= 5; slot++ {
			recs = append(recs, statuseffect.Record{Slot: slot, StartMs: now, DurationMs: 10000})
		}
		for _, slot := range []int{6, 7, 9, 14, 16} {
			recs = append(recs, statuseffect.Record{Slot: slot, Level: 1, StartMs: now, DurationMs: 60000})
		}
		h.afflict(recs...)
		_, before := h.qty(row.ID)
		res := h.use(row.ID)
		_, after := h.qty(row.ID)
		held := map[int]bool{}
		for slot := 0; slot < 32; slot++ {
			held[slot] = h.holds(slot)
		}
		switch {
		case row.TypeID4 == curePetKind || row.TypeID4 == cureBagKind:
			census["refused (pet pill / cure bag, OPEN)"]++
			if res.Error == "" || after != before {
				t.Errorf("%d %s: used (%+v)", row.ID, row.CodeName, res)
			}
		case row.TypeID4 == curePurificationKind:
			census["purification"]++
			if res.Error != "" || after != before-1 {
				t.Errorf("%d %s: %+v, %d -> %d", row.ID, row.CodeName, res, before, after)
			}
			ended := 0
			for _, slot := range []int{6, 7, 9, 14, 16} {
				if !held[slot] {
					ended++
					if uint32(row.RestoreHP)&statuseffect.MaskForSlot(slot) == 0 {
						t.Errorf("%d %s: ended slot %d outside its mask %#x", row.ID, row.CodeName, slot, row.RestoreHP)
					}
				}
			}
			for slot := 0; slot <= 5; slot++ {
				if !held[slot] {
					t.Errorf("%d %s: ended elemental slot %d", row.ID, row.CodeName, slot)
				}
			}
			if ended != 1 {
				t.Errorf("%d %s: ended %d states, want 1", row.ID, row.CodeName, ended)
			}
		default:
			census["universal"]++
			if res.Error != "" || after != before-1 {
				t.Errorf("%d %s: %+v, %d -> %d", row.ID, row.CodeName, res, before, after)
			}
			r, _, _ := curePillRule(&row)
			for slot := 0; slot <= 5; slot++ {
				unit, _ := statuseffect.DurationUnitMs(slot)
				wantEnded := int(r.Elem[slot]&0xffff)*unit > 10000
				if held[slot] == wantEnded {
					t.Errorf("%d %s: slot %d held %v (strength %d)", row.ID, row.CodeName, slot, held[slot], r.Elem[slot])
				}
			}
			for _, slot := range []int{6, 7, 9, 14, 16} {
				if !held[slot] {
					t.Errorf("%d %s: ended non-elemental slot %d", row.ID, row.CodeName, slot)
				}
			}
		}
		t.Logf("%6d %-36s 3/3/2/%d P=%d,%d,%d,%d,%d,%d -> %q", row.ID, row.CodeName, row.TypeID4,
			row.RestoreHP, row.RestoreHPPct, row.RestoreMP, row.RestoreMPPct, row.Param5, row.Param6, res.Error)
	}
	t.Logf("census over %d TypeID 3/3/2 rows: %v", len(rows), census)
}
