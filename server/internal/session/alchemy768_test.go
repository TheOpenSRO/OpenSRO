package session

import (
	"bufio"
	"context"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/alchemy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	alcSword  = 9101
	alcElixir = 9102
	alcPowder = 9103
	alcStone  = 9104
	alcAttr   = 9105
	alcShield = 9106
	// opAlcEnter is the test's own: it puts the session's character in the
	// hub, which the alchemy handler finds the character through.
	opAlcEnter uint16 = 0x7ff0
)

// alcScript is a rand() from a list.
type alcScript struct{ vals []int }

func (s *alcScript) Intn(n int) int {
	if len(s.vals) == 0 {
		return 0
	}
	v := s.vals[0] % n
	s.vals = s.vals[1:]
	return v
}

type alchemyFixture struct {
	t      *testing.T
	ctx    context.Context
	inv    inventory.Store
	charID int64
	rng    *alcScript
	send   func(op uint16, data []byte) *proto.Packet
	sendNo func(op uint16, data []byte)
	recv   func() *proto.Packet
}

// recvResult reads the next reply, which must be the alchemy result named.
func (f *alchemyFixture) recvResult(reinforce bool) *AlchemyResult {
	f.t.Helper()
	p := f.recv()
	res, err := DecodeAlchemyResult(p.Data, reinforce)
	if err != nil {
		f.t.Fatalf("%#04x: %v", p.Opcode, err)
	}
	return res
}

func newAlchemyFixture(t *testing.T, opts *magicopt.Table) *alchemyFixture {
	t.Helper()
	f := &alchemyFixture{t: t, ctx: context.Background(), rng: &alcScript{}}
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(f.ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	f.charID = c.ID
	items := refdata.NewMemStore()
	if err := items.ImportItems(f.ctx, []refdata.Item{
		{ID: alcSword, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 6, TypeID4: 2, ItemClass: 1, MaxMagicOptions: 9,
			DurabilityMin: 20, DurabilityMax: 30, CanUse: true, CanPick: true},
		{ID: alcShield, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: 4, TypeID4: 1, ItemClass: 1, MaxMagicOptions: 9,
			DurabilityMin: 20, DurabilityMax: 30, CanUse: true, CanPick: true},
		{ID: alcElixir, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 10, TypeID4: 1, Param1: 0x06000000, Param5: 0xffffffff,
			ReinforceRate1: 0x19140F0A, ReinforceRate2: 0x0A0A0A0A, ReinforceRate3: 0x0A050505},
		{ID: alcPowder, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 10, TypeID4: 2, Param1: 1, Param5: 0xffffffff,
			ReinforceRate1: 0x2323190f, ReinforceRate2: 0x0f010101, ReinforceRate3: 0x01010101},
		{ID: alcStone, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 11, TypeID4: 1, Param1: 1, ReinforceRate3: 50, Desc1: "MATTR_STR"},
		{ID: alcAttr, MaxStack: 50, TypeID1: 3, TypeID2: 3, TypeID3: 11, TypeID4: 2, Param1: 1, ReinforceRate3: 50,
			Desc1: "NATTR_PA", Desc4: "weapon"},
	}); err != nil {
		t.Fatal(err)
	}
	f.inv = inventory.NewMemStore(items)
	for _, add := range []struct {
		id  int64
		qty int
	}{{alcSword, 1}, {alcElixir, 5}, {alcPowder, 5}, {alcStone, 5}, {alcAttr, 5}, {alcShield, 1}} {
		if err := f.inv.AddItem(f.ctx, c.ID, add.id, add.qty); err != nil {
			t.Fatalf("add %d: %v", add.id, err)
		}
	}
	savedAfter, savedRand := alchemyAfter, alchemyRand
	t.Cleanup(func() { alchemyAfter, alchemyRand = savedAfter, savedRand })
	alchemyAfter = func(_ time.Duration, fn func()) { fn() }
	alchemyRand = f.rng

	hub := world.NewHub()
	enter := func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != opAlcEnter {
			return nil
		}
		hub.Enter(sess, f.charID, "Aria", 1, "jangan", world.Position{})
		return sess.Send(&proto.Packet{Opcode: opAlcEnter})
	}
	handle := gateway.Chain(LoginHandler(accounts), enter,
		AlchemyHandler(AlchemyDeps{Hub: hub, Inv: f.inv, Items: items, Options: opts}))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	write := func(op uint16, data []byte) {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	f.send = func(op uint16, data []byte) *proto.Packet {
		t.Helper()
		write(op, data)
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	f.recv = func() *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		return resp
	}
	// sendNo writes and checks nothing comes back before a following probe.
	f.sendNo = func(op uint16, data []byte) {
		t.Helper()
		write(op, data)
		if p := f.send(opAlcEnter, nil); p.Opcode != opAlcEnter {
			t.Fatalf("an answer came back: %#04x % x", p.Opcode, p.Data)
		}
	}
	if lr, err := DecodeLoginResult(f.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	f.send(opAlcEnter, nil)
	return f
}

func (f *alchemyFixture) slot(id int64) inventory.Slot {
	f.t.Helper()
	slots, err := f.inv.List(f.ctx, f.charID)
	if err != nil {
		f.t.Fatal(err)
	}
	for _, s := range slots {
		if s.ItemID == id {
			return s
		}
	}
	return inventory.Slot{Index: -1}
}

func (f *alchemyFixture) wire(id int64) int { return f.slot(id).Index + AlchemyFirstBagSlot }

func (f *alchemyFixture) start(op int, ids ...int64) *AlchemyResult {
	f.t.Helper()
	req := &AlchemyRequest{Action: AlchemyActionStart, Op: op}
	for _, id := range ids {
		req.Slots = append(req.Slots, f.wire(id))
	}
	p := f.send(OpAlchemy, req.Encode())
	if p.Opcode != alchemyResultOp(op) {
		f.t.Fatalf("answered on %#04x, want %#04x", p.Opcode, alchemyResultOp(op))
	}
	res, err := DecodeAlchemyResult(p.Data, p.Opcode == OpAlchemyReinforceResult)
	if err != nil {
		f.t.Fatal(err)
	}
	return res
}

func TestAlchemyOpcodesArePinned(t *testing.T) {
	if OpAlchemy != 0x0113 || OpAlchemyReinforceResult != 0x0114 || OpAlchemyStoneResult != 0x0115 {
		t.Fatal("the alchemy opcodes moved; client/scripts/net/alchemy.gd pins them")
	}
}

func TestAlchemyReinforceSucceeds(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	f.rng.vals = []int{0} // +0 reads 25 %: 0 wins
	res := f.start(AlchemyOpReinforce, alcSword, alcElixir)
	if !res.OK || !res.Success || res.Record == nil || res.Record.OptLevel != 1 || res.Slot != f.wire(alcSword) {
		t.Fatalf("got %+v", res)
	}
	if s := f.slot(alcSword); s.OptLevel != 1 {
		t.Errorf("the bag's sword is +%d, want +1", s.OptLevel)
	}
	if q := f.slot(alcElixir).Quantity; q != 4 {
		t.Errorf("elixirs left %d, want 4", q)
	}
}

func TestAlchemyReinforceFailureSpendsTheElixirAndPowder(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	f.rng.vals = []int{99}
	res := f.start(AlchemyOpReinforce, alcSword, alcElixir, alcPowder)
	if !res.OK || res.Success || res.Destroyed || res.Record == nil {
		t.Fatalf("got %+v", res)
	}
	if f.slot(alcElixir).Quantity != 4 || f.slot(alcPowder).Quantity != 4 {
		t.Errorf("elixir %d powder %d, want one of each spent", f.slot(alcElixir).Quantity, f.slot(alcPowder).Quantity)
	}
}

func TestAlchemyReinforceDestroysAtFive(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	sw := f.slot(alcSword)
	inst := sw.Instance()
	inst.OptLevel = 6
	if err := f.inv.SetInstance(f.ctx, f.charID, sw.Index, inst); err != nil {
		t.Fatal(err)
	}
	f.rng.vals = []int{99, 0}
	res := f.start(AlchemyOpReinforce, alcSword, alcElixir)
	if !res.OK || res.Success || !res.Destroyed || res.Record != nil {
		t.Fatalf("got %+v", res)
	}
	if f.slot(alcSword).Index != -1 {
		t.Error("the destroyed sword is still in the bag")
	}
}

func TestAlchemyRequestRefusals(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	for _, c := range []struct {
		name string
		op   int
		req  *AlchemyRequest
		want uint16
	}{
		{"slot out of range", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{5}}, AlchemyErrInvalidSlot},
		{"an empty slot", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{100}}, AlchemyErrEmptySlot},
		{"the first slot is no equipment", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcElixir), f.wire(alcSword)}}, alchemy.ErrOnlyEquipCanBeReinforced},
		{"a stone in a reinforce", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcSword), f.wire(alcStone)}}, alchemy.ErrNotReinforceStuff},
		{"two pieces of equipment", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcSword), f.wire(alcShield)}}, alchemy.ErrStuffLoadedTwice},
		{"an elixir in a stone op", AlchemyOpMagic, &AlchemyRequest{Action: 2, Op: 4, Slots: []int{f.wire(alcSword), f.wire(alcElixir)}}, alchemy.ErrNotReinforceStuff},
		{"the weapon elixir on a shield", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcShield), f.wire(alcElixir)}}, alchemy.ErrRecipeMismatch},
		{"no elixir at all", AlchemyOpReinforce, &AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcSword)}}, alchemy.ErrRecipeNotLoaded},
	} {
		p := f.send(OpAlchemy, c.req.Encode())
		res, err := DecodeAlchemyResult(p.Data, p.Opcode == OpAlchemyReinforceResult)
		if err != nil || res.OK || res.Code != c.want || p.Opcode != alchemyResultOp(c.op) {
			t.Errorf("%s: %#04x %+v %v, want refusal %#x", c.name, p.Opcode, res, err, c.want)
		}
	}
	if f.slot(alcElixir).Quantity != 5 || f.slot(alcStone).Quantity != 5 {
		t.Error("a refusal spent something")
	}
}

func TestAlchemyMagicStone(t *testing.T) {
	tbl, err := magicopt.LoadCSV(strings.NewReader("69,MATTR_STR,1,1,7566450,65538,196608,0,0,weapon|armor|shield|accessory\n"))
	if err != nil {
		t.Fatal(err)
	}
	f := newAlchemyFixture(t, tbl)
	// A lost roll: 0x5423 on the stone reply, the stone spent.
	f.rng.vals = []int{51}
	res := f.start(AlchemyOpMagic, alcSword, alcStone)
	if res.OK || res.Code != alchemy.ErrEnchantFailed || f.slot(alcStone).Quantity != 4 {
		t.Fatalf("lost roll: %+v, stones %d", res, f.slot(alcStone).Quantity)
	}
	// A won roll writes STR 3 (the third of {1, 2, 3}).
	f.rng.vals = []int{50, 2}
	res = f.start(AlchemyOpMagic, alcSword, alcStone)
	if !res.OK || !res.Success || res.Record == nil || len(res.Record.MagParams) != 1 ||
		inventory.MagParamOption(res.Record.MagParams[0]) != 69 || inventory.MagParamValue(res.Record.MagParams[0]) != 3 {
		t.Fatalf("won: %+v", res)
	}
	if f.slot(alcStone).Quantity != 3 || len(f.slot(alcSword).MagParams) != 1 {
		t.Error("the stone was not spent or the option not stored")
	}
}

func TestAlchemyMagicStoneWithoutTheTableIsNotSpent(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	f.rng.vals = []int{0}
	res := f.start(AlchemyOpMagic, alcSword, alcStone)
	if res.OK || res.Code != alchemy.NothingWritten || f.slot(alcStone).Quantity != 5 {
		t.Fatalf("%+v stones %d, want code 2 and the stone kept", res, f.slot(alcStone).Quantity)
	}
}

func TestAlchemyAttrStone(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	f.rng.vals = []int{0, 5, 5, 5, 5} // win; the minimum of four draws 5 -> 31
	res := f.start(AlchemyOpAttr, alcSword, alcAttr)
	if !res.OK || !res.Success || res.Record == nil || (res.Record.Variance>>(5*4))&0x1f != 31 {
		t.Fatalf("%+v", res)
	}
}

func TestAlchemyCancelBeforeTheRun(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	var pending func()
	alchemyAfter = func(_ time.Duration, fn func()) { pending = fn }
	f.sendNo(OpAlchemy, (&AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcSword), f.wire(alcElixir)}}).Encode())
	p := f.send(OpAlchemy, (&AlchemyRequest{Action: AlchemyActionCancel}).Encode())
	res, err := DecodeAlchemyResult(p.Data, true)
	if err != nil || !res.OK || !res.Cancelled || p.Opcode != OpAlchemyReinforceResult {
		t.Fatalf("cancel: %#04x %+v %v", p.Opcode, res, err)
	}
	pending() // the timer firing after the cancel does nothing
	f.sendNo(OpAlchemy, (&AlchemyRequest{Action: AlchemyActionCancel}).Encode())
	if f.slot(alcElixir).Quantity != 5 {
		t.Error("a cancelled reinforce spent the elixir")
	}
}

// A spent Lucky charge is saved with the item (FUN_00505e50 through the
// commit's write).
func TestAlchemyLuckChargeIsSaved(t *testing.T) {
	tbl, err := magicopt.LoadCSV(strings.NewReader("32,MATTR_LUCK,1,1,1819632491,65538,196612,327686,0,weapon\n"))
	if err != nil {
		t.Fatal(err)
	}
	f := newAlchemyFixture(t, tbl)
	sw := f.slot(alcSword)
	inst := sw.Instance()
	inst.MagParams = []uint64{inventory.MagParam(32, 3)}
	if err := f.inv.SetInstance(f.ctx, f.charID, sw.Index, inst); err != nil {
		t.Fatal(err)
	}
	f.rng.vals = []int{0}
	if res := f.start(AlchemyOpReinforce, alcSword, alcElixir); !res.OK || !res.Success {
		t.Fatalf("%+v", res)
	}
	got := f.slot(alcSword).MagParams
	if len(got) != 1 || inventory.MagParamValue(got[0]) != 2 {
		t.Fatalf("options %v, want Lucky down to 2", got)
	}
}

// An item moved while the attempt waits cancels it, and nothing is spent.
func TestAlchemyMovedItemCancels(t *testing.T) {
	f := newAlchemyFixture(t, nil)
	var pending func()
	alchemyAfter = func(_ time.Duration, fn func()) { pending = fn }
	f.sendNo(OpAlchemy, (&AlchemyRequest{Action: 2, Op: 3, Slots: []int{f.wire(alcSword), f.wire(alcElixir)}}).Encode())
	from := f.slot(alcElixir).Index
	if err := f.inv.MoveItem(f.ctx, f.charID, from, 20); err != nil {
		t.Fatal(err)
	}
	pending()
	res := f.recvResult(true)
	if !res.OK || !res.Cancelled || f.slot(alcElixir).Quantity != 5 || f.slot(alcSword).OptLevel != 0 {
		t.Fatalf("%+v elixirs %d", res, f.slot(alcElixir).Quantity)
	}
}

// A flaw writes its MATTR_DEC_MAXDUR option with the table loaded.
func TestAlchemyFlawIsSaved(t *testing.T) {
	tbl, err := magicopt.LoadCSV(strings.NewReader("20,MATTR_DEC_MAXDUR,3,0.125,1685418593,0,36,50,0,weapon|armor|shield\n"))
	if err != nil {
		t.Fatal(err)
	}
	f := newAlchemyFixture(t, tbl)
	sw := f.slot(alcSword)
	inst := sw.Instance()
	inst.OptLevel = 5
	if err := f.inv.SetInstance(f.ctx, f.charID, sw.Index, inst); err != nil {
		t.Fatal(err)
	}
	f.rng.vals = []int{99, 50, 0} // lost, the flaw half, the range's bottom 36
	res := f.start(AlchemyOpReinforce, alcSword, alcElixir)
	if !res.OK || res.Success || res.Destroyed || res.Record == nil || res.Record.OptLevel != 0 {
		t.Fatalf("%+v", res)
	}
	got := f.slot(alcSword).MagParams
	if len(got) != 1 || inventory.MagParamOption(got[0]) != 20 || inventory.MagParamValue(got[0]) != 36 {
		t.Fatalf("options %v, want MATTR_DEC_MAXDUR 36", got)
	}
}
