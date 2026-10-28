package session

import (
	"bufio"
	"context"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/berserk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skilljob"
)

// Round 838: the skill items (UseByKind cases 1-3) and the visuals' rule.
// Synthetic rows with the SHAPE of the archive's (itemskill.go's header): a
// 3/3/13/1 item whose Desc128_1 names a 'cbuf' + 'dura' skill; the ids are
// made up, no row is copied.
const (
	tsBoots      = 98301 // ITEM_SPEED_105's shape: Desc128_1 a 'hste' skill, Param1 11
	tsDrug       = 98302 // a movement drug: another 'hste' skill, overlap byte 6
	tsWing       = 98303 // a Godbless wing: Desc128_1 a visual skill, overlap 'rcur'
	tsHorns      = 98304 // a VSROEDITORCOM horn scroll: 3/3/13/14 [USU1:...]
	tsAbsorb     = 98305 // the 10 % absorption scroll: 'odar' 15,10
	tsNoCbuf     = 98306 // a bound skill without 'cbuf': the context path, not modelled
	tsSkBoots    = 98401
	tsSkDrug     = 98402
	tsSkWing     = 98403
	tsSkHorns    = 98404
	tsSkAbsorb   = 98405
	tsSkNoCbuf   = 98406
	tsOverlapRun = 6        // the speed rows' Action_Overlap
	tsOverlapRcu = 0x637572 // 'rcur' & 0xffffff
)

type skillItemFixture struct {
	t      *testing.T
	ctx    context.Context
	inv    *inventory.MemStore
	charID int64
	clock  time.Time
	use    func(slot int) *UseItemResult
	recv   func() *proto.Packet
}

// freshSkillJobs gives the test its own job store (the store is process-wide).
func freshSkillJobs(t *testing.T) *skilljob.MemStore {
	t.Helper()
	saved := skillJobs.Load()
	m := skilljob.NewMemStore()
	SetSkillJobStore(m)
	t.Cleanup(func() { skillJobs.Store(saved) })
	return m
}

func newSkillItemFixture(t *testing.T) *skillItemFixture {
	t.Helper()
	f := &skillItemFixture{t: t, ctx: context.Background()}
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(f.ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	f.charID = c.ID
	items := refdata.NewMemStore()
	item := func(id int64, t4 int, desc string, extra func(*refdata.Item)) refdata.Item {
		it := refdata.Item{ID: id, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: t4, CanUse: true, Desc1: desc}
		if extra != nil {
			extra(&it)
		}
		return it
	}
	if err := items.ImportItems(f.ctx, []refdata.Item{
		item(tsBoots, 1, "SKILL_TEST_SPEED_105", func(it *refdata.Item) { it.Param1 = 11 }),
		item(tsDrug, 1, "SKILL_TEST_POTION_SPEED", nil),
		item(tsWing, 1, "SKILL_NEW_GODBLESS_TEST", nil),
		item(tsHorns, 14, "????(?)", func(it *refdata.Item) { it.CompositeDesc = "[USU1:SKILL_VSROEDITORCOM_VISUAL_TEST]" }),
		item(tsAbsorb, 1, "SKILL_TEST_DAMAGE_ABS_10P", nil),
		item(tsNoCbuf, 1, "SKILL_TEST_NO_CBUF", nil),
	}); err != nil {
		t.Fatal(err)
	}
	skill := func(id int64, code string, dura int, overlap int64, runs ...[]any) refdata.Skill {
		s := refdata.Skill{ID: id, GroupID: id, BasicCode: code, BasicGroup: code, BasicLevel: 1, ActionKind: 3,
			DuraMs: dura, Cbuf: true, ActionOverlap: overlap}
		if len(runs) > 0 {
			s.ParamWords = words(3, runs...)
		}
		return s
	}
	hste := func(s refdata.Skill, v string) refdata.Skill { s.BuffParams = "hste:" + v; return s }
	noCbuf := skill(tsSkNoCbuf, "SKILL_TEST_NO_CBUF", 1800000, 0)
	noCbuf.Cbuf = false
	if err := items.ImportSkills(f.ctx, []refdata.Skill{
		hste(skill(tsSkBoots, "SKILL_TEST_SPEED_105", 604800000, tsOverlapRun), "115"),
		hste(skill(tsSkDrug, "SKILL_TEST_POTION_SPEED", 1800000, tsOverlapRun), "100"),
		skill(tsSkWing, "SKILL_NEW_GODBLESS_TEST", -1875767296, tsOverlapRcu),
		skill(tsSkHorns, "SKILL_VSROEDITORCOM_VISUAL_TEST", -1875767296, 0x949b31),
		skill(tsSkAbsorb, "SKILL_TEST_DAMAGE_ABS_10P", 1800000, 0x090a, run("odar", 15, 10)),
		noCbuf,
	}); err != nil {
		t.Fatal(err)
	}
	f.inv = inventory.NewMemStore(items)
	for _, id := range []int64{tsBoots, tsDrug, tsWing, tsHorns, tsAbsorb, tsNoCbuf} {
		if err := f.inv.AddItem(f.ctx, c.ID, id, 2); err != nil {
			t.Fatal(err)
		}
	}
	t.Cleanup(func() { buffBooks.EndAll(f.charID) })
	savedItems := itemCooldowns
	t.Cleanup(func() { itemCooldowns = savedItems })
	itemCooldowns = newItemCooldownTracker()
	f.clock = time.Now()
	saved := useItemClock
	t.Cleanup(func() { useItemClock = saved })
	useItemClock = func() time.Time { return f.clock }
	keeper := NewCompositeKeeper()
	// The composite path (the horn scroll's USU1) needs a berserk tracker.
	handle := gateway.Chain(LoginHandler(accounts),
		UseItemHandler(chars, f.inv, items, nil, nil, nil, nil, berserk.NewTracker(), nil, keeper, nil))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	f.recv = func() *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	send := func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
		return f.recv()
	}
	if lr, err := DecodeLoginResult(send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	f.use = func(slot int) *UseItemResult {
		t.Helper()
		res, err := DecodeUseItemResult(send(OpUseItem, (&UseItemRequest{CharacterName: "Aria", InventorySlot: int32(slot)}).Encode()).Data)
		if err != nil {
			t.Fatalf("decode: %v", err)
		}
		return res
	}
	return f
}

func (f *skillItemFixture) slotOf(id int64) (int, int) {
	f.t.Helper()
	slots, err := f.inv.List(f.ctx, f.charID)
	if err != nil {
		f.t.Fatal(err)
	}
	for _, sl := range slots {
		if sl.ItemID == id {
			return sl.Index, sl.Quantity
		}
	}
	return -1, 0
}

func (f *skillItemFixture) record(skillID int64) (buff.Record, bool) {
	for _, r := range buffBooks.Active(f.charID) {
		if r.SkillID == skillID {
			return r, true
		}
	}
	return buff.Record{}, false
}

// The boots cast their Desc128_1 skill: a 'cbuf' + 'dura' row becomes a
// type-0 job lasting dura / 1000 s, the run speed rises, the item is spent;
// the same skill again, and a drug on the same overlap byte, are refused and
// kept.
func TestSkillItemCastsItsBoundSkill(t *testing.T) {
	freshSkillJobs(t)
	f := newSkillItemFixture(t)
	slot, _ := f.slotOf(tsBoots)
	if res := f.use(slot); res.Error != "" || res.Remaining != 1 {
		t.Fatalf("boots: %+v, want used with 1 left", res)
	}
	rec, ok := f.record(tsSkBoots)
	if !ok {
		t.Fatal("no boots buff on the book")
	}
	if rec.Dura != 604800*time.Second {
		t.Errorf("boots buff lasts %v, want 604,800 s", rec.Dura)
	}
	if got := buffBooks.RunSpeed(f.charID); got <= uint32(PlayerRunSpeed) {
		t.Errorf("run speed %d after the boots, want above the base %v", got, PlayerRunSpeed)
	}
	if res := f.use(slot); res.Error != compositeOverlapRefusal {
		t.Errorf("second boots: %q, want the overlap refusal", res.Error)
	}
	if _, n := f.slotOf(tsBoots); n != 1 {
		t.Errorf("the refused boots were spent: %d left", n)
	}
	ds, _ := f.slotOf(tsDrug)
	if res := f.use(ds); res.Error != overlapRefusal {
		t.Errorf("a drug on the boots' overlap byte: %q, want 0x300c's text", res.Error)
	}
	if _, n := f.slotOf(tsDrug); n != 2 {
		t.Errorf("the refused drug was spent: %d left", n)
	}
	jobs, _ := jobStore().List(f.ctx, f.charID)
	if len(jobs) != 1 || jobs[0].SkillID != tsSkBoots {
		t.Errorf("jobs %+v, want the boots' alone", jobs)
	}
}

// A bound skill without 'cbuf' takes FUN_0059b8d0's other branch, which is
// not modelled: refused, not spent.
func TestSkillItemWithoutCbufIsRefused(t *testing.T) {
	freshSkillJobs(t)
	f := newSkillItemFixture(t)
	slot, _ := f.slotOf(tsNoCbuf)
	if res := f.use(slot); res.Error != "that cannot be used" {
		t.Errorf("got %q, want refused", res.Error)
	}
	if _, n := f.slotOf(tsNoCbuf); n != 2 {
		t.Errorf("spent: %d left", n)
	}
}

// OURS, the visuals' rule: a VSROEDITORCOM scroll is refused while a
// Godbless wing runs (other overlap bytes), and kept.
func TestOneCharacterVisualAtATime(t *testing.T) {
	freshSkillJobs(t)
	f := newSkillItemFixture(t)
	ws, _ := f.slotOf(tsWing)
	if res := f.use(ws); res.Error != "" {
		t.Fatalf("wing: %q", res.Error)
	}
	if rec, ok := f.record(tsSkWing); !ok || rec.Dura != 2419200*time.Second {
		t.Fatalf("wing buff %+v %v, want 28 days", rec, ok)
	}
	hs, _ := f.slotOf(tsHorns)
	if res := f.use(hs); res.Error != compositeOverlapRefusal {
		t.Errorf("horns while a wing runs: %q, want refused", res.Error)
	}
	if _, n := f.slotOf(tsHorns); n != 2 {
		t.Errorf("the refused horns were spent: %d left", n)
	}
	if _, ok := f.record(tsSkHorns); ok {
		t.Error("the horns' buff started")
	}
}

// The absorption scroll's 'odar' 15,10 makes a player's blows taken x0.9.
func TestAbsorptionScrollCutsDamageTaken(t *testing.T) {
	freshSkillJobs(t)
	f := newSkillItemFixture(t)
	if got := applyPlayerTaken(f.charID, false, 1000); got != 1000 {
		t.Fatalf("before the scroll: %d, want 1000", got)
	}
	slot, _ := f.slotOf(tsAbsorb)
	if res := f.use(slot); res.Error != "" {
		t.Fatalf("scroll: %q", res.Error)
	}
	if got := applyPlayerTaken(f.charID, false, 1000); got != 900 {
		t.Errorf("physical 1000 taken -> %d, want 900", got)
	}
	if got := applyPlayerTaken(f.charID, true, 1000); got != 900 {
		t.Errorf("magical 1000 taken -> %d, want 900 (mask 15)", got)
	}
	if got := applyPlayerTaken(f.charID, false, 1); got != 1 {
		t.Errorf("1 taken -> %d, want at least 1", got)
	}
}

// The job outlives the book: a logout's EndAll, then the entry's restore puts
// the buff back with what is left; a death keeps it; a cancel forgets it.
func TestSkillJobOutlivesTheBook(t *testing.T) {
	freshSkillJobs(t)
	f := newSkillItemFixture(t)
	slot, _ := f.slotOf(tsWing)
	if res := f.use(slot); res.Error != "" {
		t.Fatalf("wing: %q", res.Error)
	}
	buffBooks.EndAll(f.charID)
	later := f.clock.Add(time.Hour)
	if n := restoreSkillJobs(f.ctx, f.charID, later); n != 1 {
		t.Fatalf("restored %d, want 1", n)
	}
	rec, ok := f.record(tsSkWing)
	if !ok {
		t.Fatal("not restored")
	}
	if left := rec.Remaining(later); left != 2419200*time.Second-time.Hour {
		t.Errorf("restored with %v left, want 28 days less an hour", left)
	}
	// A second entry while it runs adds nothing.
	if n := restoreSkillJobs(f.ctx, f.charID, later); n != 0 {
		t.Errorf("a second restore started %d", n)
	}
	// A death keeps it (OURS).
	endBuffsOf(nil, f.charID)
	if _, ok := f.record(tsSkWing); !ok {
		t.Error("a death ended the job's buff")
	}
	// Past its end, nothing comes back and the job is dropped.
	buffBooks.EndAll(f.charID)
	if n := restoreSkillJobs(f.ctx, f.charID, f.clock.Add(2419201*time.Second)); n != 0 {
		t.Errorf("an ended job restored %d", n)
	}
	if jobs, _ := jobStore().List(f.ctx, f.charID); len(jobs) != 0 {
		t.Errorf("ended jobs kept: %+v", jobs)
	}
}

// An ordinary buff still ends at a death.
func TestDeathEndsBuffsWithoutAJob(t *testing.T) {
	freshSkillJobs(t)
	const owner = 987654
	t.Cleanup(func() { buffBooks.EndAll(owner) })
	buffBooks.Start(owner, buff.Spec{SkillID: 1234, CasterID: owner, DuraMs: 60000}, time.Now())
	endBuffsOf(nil, owner)
	if n := len(buffBooks.Active(owner)); n != 0 {
		t.Errorf("%d buffs survived the death", n)
	}
}
