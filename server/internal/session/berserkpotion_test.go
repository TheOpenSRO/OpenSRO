package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/berserk"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// The synthetic rows below copy the SHAPE of the retail berserk potions
// (round 632): TypeID 3/3/1/8, CanUse set, and a COOLTIME descriptor of
// group 0xC9 / 1,200,000 ms on the first, none on the second. The ids are
// the retail ones only so the test reads like the data; no row is copied.
const (
	testHwanFill   = 23937 // ITEM_ETC_SECOND_HWAN's shape: COOLTIME 0xC9, 20 min
	testHwanPotion = 24331 // ITEM_ETC_E080723_HWAN_POTION's shape: no COOLTIME
)

type berserkPotionFixture struct {
	t      *testing.T
	ctx    context.Context
	chars  *character.MemStore
	inv    *inventory.MemStore
	zerk   *berserk.Tracker
	charID int64
	clock  time.Time
	use    func(slot int) *UseItemResult
	slotOf func(id int64) (index, qty int)
}

func newBerserkPotionFixture(t *testing.T, gate *gm.Gate) *berserkPotionFixture {
	t.Helper()
	f := &berserkPotionFixture{t: t, ctx: context.Background()}
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	f.chars = character.NewMemStore()
	c, err := f.chars.Create(f.ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	f.charID = c.ID
	items := refdata.NewMemStore()
	if err := items.ImportItems(f.ctx, []refdata.Item{
		{ID: testHwanFill, MaxStack: 1, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 8, CanUse: true,
			CooltimeGroup: 0xC9, CooltimeMs: 1200000},
		{ID: testHwanPotion, MaxStack: 10, TypeID1: 3, TypeID2: 3, TypeID3: 1, TypeID4: 8, CanUse: true},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	f.inv = inventory.NewMemStore(items)
	if err := f.inv.AddItem(f.ctx, c.ID, testHwanFill, 1); err != nil {
		t.Fatalf("add fill: %v", err)
	}
	if err := f.inv.AddItem(f.ctx, c.ID, testHwanFill, 1); err != nil {
		t.Fatalf("add second fill: %v", err)
	}
	if err := f.inv.AddItem(f.ctx, c.ID, testHwanPotion, 3); err != nil {
		t.Fatalf("add potion: %v", err)
	}
	f.zerk = berserk.NewTracker()

	// A past clock, so an armed group can never outlive the test into
	// another one that reads the real time (itemCooldowns is process-wide).
	f.clock = time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return f.clock }

	handle := gateway.Chain(LoginHandler(accounts),
		UseItemHandler(f.chars, f.inv, items, nil, nil, nil, nil, f.zerk, gate))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	send := func(op uint16, data []byte) *proto.Packet {
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
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	f.use = func(slot int) *UseItemResult {
		t.Helper()
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode result: %v", err)
		}
		return res
	}
	f.slotOf = func(id int64) (index, qty int) {
		t.Helper()
		slots, err := f.inv.List(f.ctx, f.charID)
		if err != nil {
			t.Fatalf("list: %v", err)
		}
		for _, sl := range slots {
			if sl.ItemID == id {
				return sl.Index, sl.Quantity
			}
		}
		return -1, 0
	}
	return f
}

// countOf is how many of an item the bag holds across every stack.
func (f *berserkPotionFixture) countOf(id int64) int {
	f.t.Helper()
	slots, err := f.inv.List(f.ctx, f.charID)
	if err != nil {
		f.t.Fatalf("list: %v", err)
	}
	n := 0
	for _, sl := range slots {
		if sl.ItemID == id {
			n += sl.Quantity
		}
	}
	return n
}

// A berserk potion fills all five orbs (slot 308's AddHwanCount(+5)), is spent,
// persists the count, reports the gauge, and a berserk can then be activated.
func TestBerserkPotionFillsTheGauge(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	slot, _ := f.slotOf(testHwanPotion)
	res := f.use(slot)
	if res.Error != "" {
		t.Fatalf("the berserk potion was refused: %q", res.Error)
	}
	if !res.HasBerserk || res.BerserkGauge != berserk.Max || res.BerserkActive {
		t.Errorf("reply %+v, want HasBerserk, gauge %d, not active", res, berserk.Max)
	}
	if res.MaxHP != 0 || res.Remaining != 2 {
		t.Errorf("reply MaxHP %d Remaining %d, want 0 (bars untouched) and 2", res.MaxHP, res.Remaining)
	}
	if got := f.zerk.Charges(f.charID); got != berserk.Orbs {
		t.Errorf("charges %d, want %d", got, berserk.Orbs)
	}
	if c, _ := f.chars.GetByID(f.ctx, f.charID); c.HwanCount != berserk.Orbs {
		t.Errorf("persisted HwanCount %d, want %d", c.HwanCount, berserk.Orbs)
	}
	if n := f.countOf(testHwanPotion); n != 2 {
		t.Errorf("%d potions left, want 2", n)
	}
	// At five orbs the potion is still spent (slot 308 never reads the count;
	// AddHwanCount clamps). No COOLTIME on this row, so no delay either.
	if res := f.use(slot); res.Error != "" || res.BerserkGauge != berserk.Max {
		t.Errorf("a second potion at full orbs got %+v, want used with the gauge still full", res)
	}
	if n := f.countOf(testHwanPotion); n != 1 {
		t.Errorf("%d potions left after the second use, want 1", n)
	}
	// The gauge the potion filled is the one Tab spends.
	if !f.zerk.Activate(f.charID) {
		t.Fatal("berserk did not activate on the potion's five orbs")
	}
	// While berserk: 0x18ce, the potion is kept.
	if res := f.use(slot); res.Error != berserkPotionRefusal {
		t.Errorf("a potion during berserk got %+v, want %q", res, berserkPotionRefusal)
	}
	if n := f.countOf(testHwanPotion); n != 1 {
		t.Errorf("the refused potion was spent: %d left, want 1", n)
	}
}

// A normal player's fill arms its COOLTIME group: the second fill inside the
// 20 minutes is refused and kept, and one after them is used.
func TestBerserkPotionCooltimeForAPlayer(t *testing.T) {
	f := newBerserkPotionFixture(t, gm.ParseAccounts("somebody_else"))
	slot, _ := f.slotOf(testHwanFill)
	if res := f.use(slot); res.Error != "" || res.BerserkGauge != berserk.Max {
		t.Fatalf("first fill: %+v, want used and the gauge full", res)
	}
	f.zerk.Add(f.charID, -berserk.Orbs) // empty the orbs again
	f.clock = f.clock.Add(1200000*time.Millisecond - time.Second)
	slot, _ = f.slotOf(testHwanFill)
	if res := f.use(slot); res.Error != "wait for the reuse delay" {
		t.Errorf("second fill 19:59 later got %+v, want the reuse-delay refusal", res)
	}
	if n := f.countOf(testHwanFill); n != 1 {
		t.Errorf("the refused fill was spent: %d left, want 1", n)
	}
	if got := f.zerk.Charges(f.charID); got != 0 {
		t.Errorf("the refused fill added orbs: %d", got)
	}
	f.clock = f.clock.Add(time.Second)
	if res := f.use(slot); res.Error != "" || res.BerserkGauge != berserk.Max {
		t.Errorf("fill after 20:00 got %+v, want used", res)
	}
}

// OURS, the user's request: a GM account's berserk potion has no reuse delay.
func TestBerserkPotionNoCooltimeForAGM(t *testing.T) {
	f := newBerserkPotionFixture(t, gm.ParseAccounts("alice"))
	slot, _ := f.slotOf(testHwanFill)
	if res := f.use(slot); res.Error != "" {
		t.Fatalf("first fill: %q", res.Error)
	}
	f.zerk.Add(f.charID, -berserk.Orbs)
	slot, _ = f.slotOf(testHwanFill)
	if res := f.use(slot); res.Error != "" || res.BerserkGauge != berserk.Max {
		t.Errorf("a GM's second fill at once got %+v, want used and the gauge full", res)
	}
	if n := f.countOf(testHwanFill); n != 0 {
		t.Errorf("%d fills left, want 0", n)
	}
}

// Tracker.Add is AddHwanCount: clamp to [0, 5], and no gain while berserk.
func TestTrackerAddIsAddHwanCount(t *testing.T) {
	z := berserk.NewTracker()
	if got := z.Add(1, 3); got != 3 {
		t.Errorf("Add(3) from 0 added %d", got)
	}
	if got := z.Add(1, berserk.PotionCharges); got != 2 || z.Charges(1) != berserk.Orbs {
		t.Errorf("Add(5) from 3 added %d to %d, want 2 to %d", got, z.Charges(1), berserk.Orbs)
	}
	if !z.Activate(1) {
		t.Fatal("activate")
	}
	if got := z.Add(1, 5); got != 0 || z.Charges(1) != 0 {
		t.Errorf("Add while berserk added %d, want 0", got)
	}
}
