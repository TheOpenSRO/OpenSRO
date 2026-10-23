package session

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 632 review, item 1: a COOLTIME whose key is 0 is PER ITEM
// (ItemCooldowns::IsReady 0x64c040's key-0 branch reads the per-item map at
// block+0x10); a non-zero key's bytes are groups shared by every item.
func TestItemCooldownKeyZeroIsPerItem(t *testing.T) {
	c := newItemCooldownTracker()
	now := time.Date(2001, 1, 1, 0, 0, 0, 0, time.UTC)
	c.ArmItem(1, 22936, 0, 3*time.Minute, now)
	if c.ReadyItem(1, 22936, 0, now.Add(time.Minute)) {
		t.Error("22936 (key 0) is ready a minute after its 3-minute arm")
	}
	if !c.ReadyItem(1, 22941, 0, now.Add(time.Minute)) {
		t.Error("22941 (key 0) is blocked by 22936's timer -- key 0 is not a group")
	}
	c.ArmItem(1, 23937, 0xC9, 20*time.Minute, now)
	if c.ReadyItem(1, 23944, 0xC9, now.Add(time.Minute)) {
		t.Error("23944 (group 0xC9) is ready while 23937 holds group 0xC9")
	}
	if !c.ReadyItem(1, 23944, 0xC9, now.Add(20*time.Minute)) {
		t.Error("group 0xC9 still running at 20:00")
	}
}

// Through the handler: two key-0 rows do not block each other; the same row
// again inside its delay is refused.
func TestKeyZeroPotionsDoNotCrossBlock(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	slot, _ := f.slotOf(testKeyZeroA)
	if res := f.use(slot); res.Error != "" {
		t.Fatalf("22936: %q", res.Error)
	}
	f.zerk.Add(f.charID, -berserk.Orbs)
	slot, _ = f.slotOf(testKeyZeroB)
	if res := f.use(slot); res.Error != "" {
		t.Errorf("a second key-0 row right after 22936 was refused %q; key 0 must be per item", res.Error)
	}
	if err := f.inv.AddItem(f.ctx, f.charID, testKeyZeroA, 1); err != nil {
		t.Fatal(err)
	}
	f.clock = f.clock.Add(time.Minute)
	slot, _ = f.slotOf(testKeyZeroA)
	if res := f.use(slot); res.Error != reuseDelayRefusal {
		t.Errorf("22936 again a minute later got %+v, want the reuse-delay refusal", res)
	}
}

func (f *berserkPotionFixture) useScroll() (*UseItemResult, *CompositeState) {
	f.t.Helper()
	slot, _ := f.slotOf(testHwanScroll)
	res := f.use(slot)
	if res.Error != "" {
		return res, nil
	}
	p := f.recv()
	if p.Opcode != OpCompositeState {
		f.t.Fatalf("after the scroll: opcode %#x, want the composite state", p.Opcode)
	}
	st, err := DecodeCompositeState(p.Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return res, st
}

func (f *berserkPotionFixture) useFill() (*CompositeUseResult, *CompositeState) {
	f.t.Helper()
	res, st, _ := f.useFillEnds()
	return res, st
}

// useFillEnds spends the fill and returns the result, the state that follows
// it, and any OpCompositeEnd pushed before the result (the last use ends the
// grant inside the use, as vslot_007 ends the job before 0xB15F).
func (f *berserkPotionFixture) useFillEnds() (*CompositeUseResult, *CompositeState, []*CompositeEnd) {
	f.t.Helper()
	var ends []*CompositeEnd
	p := f.send(OpCompositeUse, (&CompositeUseRequest{CharacterName: "Aria", ItemID: testHwanFill}).Encode())
	for p.Opcode == OpCompositeEnd {
		e, err := DecodeCompositeEnd(p.Data)
		if err != nil {
			f.t.Fatal(err)
		}
		ends = append(ends, e)
		p = f.recv()
	}
	if p.Opcode != OpCompositeUseResult {
		f.t.Fatalf("opcode %#x, want the use result", p.Opcode)
	}
	res, err := DecodeCompositeUseResult(p.Data)
	if err != nil {
		f.t.Fatal(err)
	}
	p = f.recv()
	if p.Opcode != OpCompositeState {
		f.t.Fatalf("after the use result: opcode %#x, want the state (sent after a refusal too)", p.Opcode)
	}
	st, err := DecodeCompositeState(p.Data)
	if err != nil {
		f.t.Fatal(err)
	}
	return res, st, ends
}

// Item 3: the Energy of life scroll grants one fill for 3600 s and +5 s of
// berserk; a second scroll meanwhile is 0x1894; the fill fills five orbs,
// ends the grant and the bonus, and arms group 0xC9 for 20 minutes, which
// then blocks the next scroll.
func TestEnergyOfLifeScroll(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	res, st := f.useScroll()
	if res.Error != "" || res.Remaining != 2 {
		t.Fatalf("scroll: %+v, want used with 2 left", res)
	}
	if len(st.Grants) != 1 || st.Grants[0].ItemID != testHwanFill || st.Grants[0].ScrollID != testHwanScroll ||
		st.Grants[0].Remaining != 1 || st.Grants[0].Max != 1 || st.Grants[0].SecondsLeft != 3600 {
		t.Errorf("grants %+v, want one fill of %d from %d, 1/1, 3600 s", st.Grants, testHwanFill, testHwanScroll)
	}
	if st.BonusSeconds != 5 || st.BonusSecondsLeft != 3600 {
		t.Errorf("bonus %d s (%d left), want 5 s for 3600", st.BonusSeconds, st.BonusSecondsLeft)
	}
	f.clock = f.clock.Add(time.Second) // past the scroll's own 1 ms
	if res, _ := f.useScroll(); res.Error != compositeOverlapRefusal {
		t.Errorf("a second scroll while the fill is granted got %q, want 0x1894's text", res.Error)
	}
	if n := f.countOf(testHwanScroll); n != 2 {
		t.Errorf("the refused scroll was spent: %d left", n)
	}
	fill, st := f.useFill()
	if fill.Error != "" || fill.BerserkGauge != berserk.Max || fill.Remaining != 0 {
		t.Fatalf("fill: %+v, want gauge %d, 0 left", fill, berserk.Max)
	}
	if len(st.Grants) != 0 || st.BonusSeconds != 0 {
		t.Errorf("after the last fill: %+v, want no grant and no bonus (FUN_004dd620 ends the 0x706874 job)", st)
	}
	if c, _ := f.chars.GetByID(f.ctx, f.charID); c.HwanCount != berserk.Orbs {
		t.Errorf("persisted orbs %d", c.HwanCount)
	}
	if again, _ := f.useFill(); again.Error != "that cannot be used" {
		t.Errorf("a fill with no grant got %q, want the no-job refusal", again.Error)
	}
	f.zerk.Add(f.charID, -berserk.Orbs)
	f.clock = f.clock.Add(19 * time.Minute)
	if res, _ := f.useScroll(); res.Error != reuseDelayRefusal {
		t.Errorf("a scroll 19 min after the fill got %q, want the 20-minute group 0xC9 refusal", res.Error)
	}
	f.clock = f.clock.Add(time.Minute)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Errorf("a scroll 20 min after the fill: %q", res.Error)
	}
}

// The fill's own refusals, FUN_004a05b0: five orbs (0x183e) and berserk
// (0x18ce); the grant is kept.
func TestEnergyOfLifeFillRefusals(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Fatal(res.Error)
	}
	f.zerk.Add(f.charID, berserk.Orbs)
	if res, _ := f.useFill(); res.Error != compositeCannotUse {
		t.Errorf("fill at five orbs got %q, want 0x183e's text", res.Error)
	}
	if !f.zerk.Activate(f.charID) {
		t.Fatal("activate")
	}
	if res, _ := f.useFill(); res.Error != berserkPotionRefusal {
		t.Errorf("fill during berserk got %q, want %q", res.Error, berserkPotionRefusal)
	}
	if g, ok := f.keeper.get(f.charID, testHwanFill, f.clock); !ok || g.remaining != 1 {
		t.Errorf("the refused fills spent the grant: %+v %v", g, ok)
	}
}

// OURS: a GM's fill arms nothing, so the next scroll goes at once.
func TestEnergyOfLifeNoCooltimeForAGM(t *testing.T) {
	f := newBerserkPotionFixture(t, gm.ParseAccounts("alice"))
	if res, _ := f.useScroll(); res.Error != "" {
		t.Fatal(res.Error)
	}
	if res, _ := f.useFill(); res.Error != "" {
		t.Fatal(res.Error)
	}
	f.zerk.Add(f.charID, -berserk.Orbs)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Errorf("a GM's next scroll right after the fill: %q", res.Error)
	}
	if res, _ := f.useFill(); res.Error != "" {
		t.Errorf("a GM's second fill: %q", res.Error)
	}
}

// Item 4: a potion waits for the berserk turn, so it cannot be spent while an
// activation (or anything else holding the turn) is between its read and its
// write.
func TestBerserkPotionWaitsForTheTurn(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	slot, _ := f.slotOf(testHwanPotion)
	release := f.zerk.Turn(f.charID)
	got := make(chan *proto.Packet, 1)
	go func() {
		got <- f.send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode())
	}()
	select {
	case <-got:
		t.Fatal("the potion was used while the berserk turn was held")
	case <-time.After(150 * time.Millisecond):
	}
	if n := f.countOf(testHwanPotion); n != 3 {
		t.Errorf("a potion was spent under the held turn: %d left", n)
	}
	release()
	select {
	case p := <-got:
		res, _ := DecodeUseItemResult(p.Data)
		if res.Error != "" {
			t.Errorf("after the turn: %q", res.Error)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the potion never ran after the turn was released")
	}
}

func TestParseCompositeDesc(t *testing.T) {
	es, err := parseCompositeDesc("[UIL1:ITEM_ETC_SECOND_HWAN,A,3600,1],[UIU1:ITEM_ETC_INCREASE_HWAN_TIME_01]")
	if err != nil || len(es) != 2 {
		t.Fatalf("%v %+v", err, es)
	}
	if es[0].fourCC != "UIL1" || es[0].code != "ITEM_ETC_SECOND_HWAN" || es[0].flagP || es[0].seconds != 3600 || es[0].count != 1 {
		t.Errorf("UIL1 %+v", es[0])
	}
	if es[1].fourCC != "UIU1" || es[1].code != "ITEM_ETC_INCREASE_HWAN_TIME_01" {
		t.Errorf("UIU1 %+v", es[1])
	}
	if _, err := parseCompositeDesc("[UIL1:X,Q,1,1]"); err == nil {
		t.Error("a UIL1 flag other than A/P parsed")
	}
}

// Composite review, item 1: the last use pushes the grant's end (retail
// 0x315B) before its result; a refused fill is followed by the state.
func TestEnergyOfLifeEndPushOnUse(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Fatal(res.Error)
	}
	res, st, ends := f.useFillEnds()
	if res.Error != "" || len(ends) != 1 || ends[0].ItemID != testHwanFill || ends[0].ScrollID != testHwanScroll {
		t.Fatalf("fill %+v ends %+v, want one end of %d/%d", res, ends, testHwanFill, testHwanScroll)
	}
	if len(st.Grants) != 0 {
		t.Errorf("state after the end still lists %+v", st.Grants)
	}
	refused, st2, _ := f.useFillEnds()
	if refused.Error == "" || st2 == nil {
		t.Errorf("a fill with no grant: %+v, state %+v -- want a refusal followed by the state", refused, st2)
	}
}

// Composite review, item 1: a grant that runs out is ended by its timer and
// pushed, with no request from the client.
func TestCompositeGrantExpiresByTimer(t *testing.T) {
	k := NewCompositeKeeper()
	now := time.Now()
	k.put(7, compositeGrant{fillID: testHwanFill, scrollID: testHwanScroll, remaining: 1, max: 1,
		until: now.Add(50 * time.Millisecond)}, 50*time.Millisecond)
	deadline := time.Now().Add(2 * time.Second)
	for {
		k.mu.Lock()
		_, left := k.grants[7]
		k.mu.Unlock()
		if !left {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the grant was never ended by its timer")
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Through the wire: the timer's end reaches the bound session as OpCompositeEnd.
func TestCompositeGrantExpiryIsPushed(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Fatal(res.Error)
	}
	// Re-arm the grant with a short real timer, as a 1-second row would.
	g, _ := f.keeper.get(f.charID, testHwanFill, f.clock)
	f.keeper.put(f.charID, *g, 50*time.Millisecond)
	p := f.recv()
	if p.Opcode != OpCompositeEnd {
		t.Fatalf("opcode %#x, want OpCompositeEnd", p.Opcode)
	}
	e, _ := DecodeCompositeEnd(p.Data)
	if e.ItemID != testHwanFill || e.ScrollID != testHwanScroll {
		t.Errorf("end %+v", e)
	}
	if _, ok := f.keeper.get(f.charID, testHwanFill, f.clock); ok {
		t.Error("the grant is still held after its end")
	}
}

// Composite review, item 3: logout forgets the session binding, expired
// grants and an empty map; a running grant stays for its timer.
func TestCompositeForget(t *testing.T) {
	k := NewCompositeKeeper()
	now := time.Now()
	k.put(8, compositeGrant{fillID: 1, until: now.Add(-time.Second)}, time.Hour)
	k.put(8, compositeGrant{fillID: 2, until: now.Add(time.Hour)}, time.Hour)
	k.Forget(8, now)
	if _, ok := k.grants[8][1]; ok {
		t.Error("an expired grant survived Forget")
	}
	if _, ok := k.grants[8][2]; !ok {
		t.Error("a running grant was dropped at logout")
	}
	k.Forget(8, now.Add(2*time.Hour))
	if _, ok := k.grants[8]; ok {
		t.Error("the empty per-character map survived Forget")
	}
}

// Composite review, item 4: a store error on the orbs leaves the grant, the
// bonus and the live orbs as they were.
func TestEnergyOfLifeFillStoreErrorChangesNothing(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	if res, _ := f.useScroll(); res.Error != "" {
		t.Fatal(res.Error)
	}
	before := f.zerk.Charges(f.charID)
	if secs, _ := f.zerk.DurationBonus(f.charID, f.clock); secs != 5 {
		t.Fatalf("bonus %d before the fill", secs)
	}
	f.hwanStore.fail = true
	res, st := f.useFill()
	if res.Error == "" {
		t.Fatal("the fill succeeded with a failing store")
	}
	if f.zerk.Charges(f.charID) != before {
		t.Errorf("orbs changed: %d -> %d", before, f.zerk.Charges(f.charID))
	}
	if len(st.Grants) != 1 || st.BonusSeconds != 5 {
		t.Errorf("state after the failed fill %+v, want the grant and the bonus kept", st)
	}
}

// hwanFailStore fails SetHwanCount on demand (the store-error ordering test).
type hwanFailStore struct {
	*character.MemStore
	fail bool
}

func (s *hwanFailStore) SetHwanCount(ctx context.Context, characterID int64, count int) error {
	if s.fail {
		return errors.New("test: store down")
	}
	return s.MemStore.SetHwanCount(ctx, characterID, count)
}

// The bag potion's store error: the potion comes back and the orbs stay.
func TestBerserkPotionStoreErrorChangesNothing(t *testing.T) {
	f := newBerserkPotionFixture(t, nil)
	f.hwanStore.fail = true
	slot, _ := f.slotOf(testHwanPotion)
	if res := f.use(slot); res.Error == "" {
		t.Fatal("the potion succeeded with a failing store")
	}
	if n := f.countOf(testHwanPotion); n != 3 {
		t.Errorf("%d potions left, want 3 (handed back)", n)
	}
	if got := f.zerk.Charges(f.charID); got != 0 {
		t.Errorf("orbs %d after a failed potion", got)
	}
}
