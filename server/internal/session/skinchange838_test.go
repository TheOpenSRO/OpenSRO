package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 838: the skin change scroll (skinchange.go), end to end -- a
// character in the world uses ITEM_MALL_CHAR_SKIN_CHANGE_SCROLL (3829,
// 3/3/13/9) with a chosen body and scale; the refusals keep the scroll, a
// change spends it, writes the body and, a second later (the test's clock),
// warps the character where it stands.

const (
	fixtureSkinScroll = 3829
	fixtureSkinHelm   = 3637 // a China helm, 3/1/1/1
	// The catalogue's bodies (chargen.csv's rows): CHAR_CH_MAN_FIGHTER 1909 is
	// what MemStore.Create gives, CHAR_CH_MAN_MERCHANT 1910, CHAR_CH_WOMAN_
	// FIGHTER 1923, CHAR_EU_MAN_NOBLE 14875; 1907000 is no body.
	skinManFighter  = 1909
	skinManMerchant = 1910
	skinWoman       = 1923
	skinEurope      = 14875
)

type skinRig struct {
	*scrollRig
	eq *equipment.MemStore
}

func newSkinRig(t *testing.T) *skinRig {
	t.Helper()
	ctx := context.Background()
	SetSkinCatalogue(refdata.NewCreatableSet([]refdata.Creatable{
		{ID: skinManFighter, Code: "CHAR_CH_MAN_FIGHTER", Kind: refdata.CreatableModel, Country: 0, Sex: 1, TypeID1: 1, TypeID2: 1},
		{ID: skinManMerchant, Code: "CHAR_CH_MAN_MERCHANT", Kind: refdata.CreatableModel, Country: 0, Sex: 1, TypeID1: 1, TypeID2: 1},
		{ID: skinWoman, Code: "CHAR_CH_WOMAN_FIGHTER", Kind: refdata.CreatableModel, Country: 0, Sex: 0, TypeID1: 1, TypeID2: 1},
		{ID: skinEurope, Code: "CHAR_EU_MAN_NOBLE", Kind: refdata.CreatableModel, Country: 1, Sex: 1, TypeID1: 1, TypeID2: 1},
		{ID: fixtureSkinHelm, Code: "ITEM_CH_M_HEAVY_01_HA_A_DEF", Kind: refdata.CreatableItem, Country: 0, Sex: 1, TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 1},
	}))
	t.Cleanup(func() { SetSkinCatalogue(nil) })
	items := refdata.NewMemStore()
	if err := items.ImportItems(ctx, []refdata.Item{
		{ID: fixtureSkinScroll, CodeName: "ITEM_MALL_CHAR_SKIN_CHANGE_SCROLL", MaxStack: 1,
			TypeID1: 3, TypeID2: 3, TypeID3: 13, TypeID4: 9, CanUse: true},
		{ID: fixtureSkinHelm, CodeName: "ITEM_CH_M_HEAVY_01_HA_A_DEF", MaxStack: 1,
			TypeID1: 3, TypeID2: 1, TypeID3: 1, TypeID4: 1, ReqGender: 1},
	}); err != nil {
		t.Fatalf("import: %v", err)
	}
	rig := &scrollRig{t: t, chars: character.NewMemStore(), inv: inventory.NewMemStore(items), hub: world.NewHub()}
	accounts := account.NewMemStore()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatal(err)
	}
	acct, _ := accounts.Authenticate(ctx, "alice", "pw")
	c, err := rig.chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	rig.charID = c.ID
	if err := rig.inv.AddItem(ctx, c.ID, fixtureSkinScroll, 1); err != nil {
		t.Fatal(err)
	}
	if err := rig.inv.AddItem(ctx, c.ID, fixtureSkinScroll, 1); err != nil {
		t.Fatal(err)
	}
	if err := rig.inv.AddItem(ctx, c.ID, fixtureSkinHelm, 1); err != nil {
		t.Fatal(err)
	}
	eq := equipment.NewMemStore(rig.inv)
	rig.caster = NewScrollCaster(rig.chars, eq, rig.hub, nil, nil)
	t.Cleanup(func() { activeScrolls.CompareAndSwap(rig.caster, nil) })
	rig.mu = sync.Mutex{}
	rig.caster.after = func(d time.Duration, f func()) {
		if d != skinChangeDelay {
			t.Errorf("the state's delay is %v, want %v", d, skinChangeDelay)
		}
		rig.mu.Lock()
		rig.pending = append(rig.pending, f)
		rig.mu.Unlock()
	}
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(rig.chars, eq, rig.hub),
		TeleportHandler(rig.chars, eq, rig.hub, teleportFixture(t), gm.ParseAccounts(""), false, nil, nil),
		UseItemHandler(rig.chars, rig.inv, items, nil, nil, nil, rig.hub, nil, nil, nil, rig.caster))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	rig.conn = dialTestServer(t, addr)
	t.Cleanup(func() { rig.conn.Close() })
	rig.r = bufio.NewReader(rig.conn)
	if lr, err := DecodeLoginResult(rig.roundTrip(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode()).Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	if ewr, err := DecodeEnterWorldResult(rig.roundTrip(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode()).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %+v %v", ewr, err)
	}
	return &skinRig{scrollRig: rig, eq: eq}
}

// clientSkinUse is OpUseItem as the client's UseItemNet.encode_use_skin builds
// it: the plain use, UseOptionSkinChange, u32 ref, u8 scale.
func clientSkinUse(name string, slot int, ref uint32, scale byte) []byte {
	out := clientUse(name, slot, 0, 0)
	out = append(out, UseOptionSkinChange)
	out = binary.LittleEndian.AppendUint32(out, ref)
	return append(out, scale)
}

func (rig *skinRig) useSkin(ref uint32, scale byte) *UseItemResult {
	rig.t.Helper()
	slot, _ := rig.slot(fixtureSkinScroll)
	if slot < 0 {
		rig.t.Fatal("no skin change scroll in the bag")
	}
	p := rig.roundTrip(OpUseItem, clientSkinUse("Aria", slot, ref, scale))
	for p != nil && p.Opcode != OpUseItemResult {
		rig.seen = append(rig.seen, p)
		p = rig.read(2 * time.Second)
	}
	if p == nil {
		rig.t.Fatal("no OpUseItemResult")
	}
	res, err := DecodeUseItemResult(p.Data)
	if err != nil {
		rig.t.Fatal(err)
	}
	return res
}

func (rig *skinRig) scrolls() int {
	n := 0
	slots, _ := rig.inv.List(context.Background(), rig.charID)
	for _, s := range slots {
		if s.ItemID == fixtureSkinScroll {
			n += s.Quantity
		}
	}
	return n
}

func (rig *skinRig) model() (int64, int, string) {
	c, err := rig.chars.GetByID(context.Background(), rig.charID)
	if err != nil {
		rig.t.Fatal(err)
	}
	return c.RefObjID, c.Scale, c.Gender
}

func TestRound838SkinChangeRefusalsKeepTheScroll(t *testing.T) {
	rig := newSkinRig(t)
	for _, tc := range []struct {
		name string
		ref  uint32
		code uint16
	}{
		{"not a body", 1907000, SkinErrRefused},
		{"another race", skinEurope, SkinErrRefused},
	} {
		if res := rig.useSkin(tc.ref, 0x22); res.Error == "" || res.Code != tc.code {
			t.Errorf("%s: got %+v, want code 0x%x", tc.name, res, tc.code)
		}
	}
	// Another sex with a helm worn: 0x1892.
	helm, _ := rig.slot(fixtureSkinHelm)
	if err := rig.eq.Equip(context.Background(), rig.charID, equipment.SlotHelm, helm); err != nil {
		t.Fatalf("wear the helm: %v", err)
	}
	if res := rig.useSkin(skinWoman, 0x22); res.Code != SkinErrArmor {
		t.Errorf("another sex with a helm: got %+v, want 0x1892", res)
	}
	// A plain use with no choice (the item right-clicked without the window).
	slot, _ := rig.slot(fixtureSkinScroll)
	p := rig.roundTrip(OpUseItem, clientUse("Aria", slot, 0, 0))
	if res, _ := DecodeUseItemResult(p.Data); res == nil || res.Code != SkinErrRefused {
		t.Errorf("a use with no choice: got %+v, want code 2", res)
	}
	if n := rig.scrolls(); n != 2 {
		t.Errorf("refusals spent scrolls: %d left, want 2", n)
	}
	if ref, _, _ := rig.model(); ref != skinManFighter {
		t.Errorf("a refusal changed the body to %d", ref)
	}
	rig.noArrival()
}

func TestRound838SkinChangeSameSexWithGearOn(t *testing.T) {
	rig := newSkinRig(t)
	helm, _ := rig.slot(fixtureSkinHelm)
	if err := rig.eq.Equip(context.Background(), rig.charID, equipment.SlotHelm, helm); err != nil {
		t.Fatalf("wear the helm: %v", err)
	}
	region, lx, lz := rig.localOf()
	// The same sex needs nothing taken off (READ: the gear test is only on a
	// change of sex).
	res := rig.useSkin(skinManMerchant, 0x41)
	if res.Error != "" || res.Remaining != 0 || res.ItemID != fixtureSkinScroll || res.CastMs != 0 {
		t.Fatalf("the change: got %+v, want success, 0 left in the slot, no casting bar", res)
	}
	if n := rig.scrolls(); n != 1 {
		t.Errorf("%d scrolls left, want 1 (one spent)", n)
	}
	if ref, scale, gender := rig.model(); ref != skinManMerchant || scale != 0x41 || gender != character.GenderChinaMan {
		t.Errorf("stored %d 0x%x %s, want %d 0x41 %s", ref, scale, gender, skinManMerchant, character.GenderChinaMan)
	}
	// The state's 0x30BF {id, 0xb, 1} came before the reply.
	var state *StateChange
	for _, p := range rig.seen {
		if p.Opcode == OpStateChange {
			if sc, ok := DecodeStateChange(p.Data); ok && sc.Kind == StateKindTeleport {
				state = sc
			}
		}
	}
	if state == nil || state.Value != 1 {
		t.Fatalf("no teleport state 1 before the reply: %+v", state)
	}
	if !rig.caster.Casting(rig.charID) {
		t.Error("no state working after the change")
	}
	// A second later: the warp to where the character stands.
	rig.fire()
	czr := rig.arrival()
	if czr == nil {
		t.Fatal("no arrival")
	}
	if r2, x2, z2 := rig.localOf(); r2 != region || !near778(x2, lx) || !near778(z2, lz) {
		t.Errorf("landed at %d (%.2f, %.2f), want where it stood, %d (%.2f, %.2f)", r2, x2, z2, region, lx, lz)
	}
	if rig.caster.Casting(rig.charID) {
		t.Error("the state still works after the warp")
	}
}

func TestRound838SkinChangeOfSexWithGearOff(t *testing.T) {
	rig := newSkinRig(t)
	res := rig.useSkin(skinWoman, 0x22)
	if res.Error != "" {
		t.Fatalf("a change of sex with nothing worn: refused %+v", res)
	}
	if ref, _, gender := rig.model(); ref != skinWoman || gender != character.GenderChinaWoman {
		t.Errorf("stored %d %s, want %d %s", ref, gender, skinWoman, character.GenderChinaWoman)
	}
	rig.fire()
	rig.arrival()
}

func TestRound838SkinUseWire(t *testing.T) {
	req := &UseItemRequest{CharacterName: "Aria", InventorySlot: 4, Option: UseOptionSkinChange, Target: skinWoman, Scale: 0x34}
	if got := req.Encode(); string(got) != string(clientSkinUse("Aria", 4, skinWoman, 0x34)) {
		t.Fatalf("Encode % x, want the client's % x", got, clientSkinUse("Aria", 4, skinWoman, 0x34))
	}
	back, err := DecodeUseItemRequest(clientSkinUse("Aria", 4, skinWoman, 0x34))
	if err != nil || back.Option != UseOptionSkinChange || back.Target != skinWoman || back.Scale != 0x34 {
		t.Fatalf("decoded %+v %v", back, err)
	}
	_ = proto.Packet{}
}
