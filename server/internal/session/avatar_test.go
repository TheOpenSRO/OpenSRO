package session

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"math"
	"reflect"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/avatar"
	"github.com/TheOpenSRO/OpenSRO/server/internal/buff"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/magicopt"
	"github.com/TheOpenSRO/OpenSRO/server/internal/pcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The avatar fixtures (OURS: invented ids and values; the kinds and the
// columns are the shapes AVATAR_RESEARCH.md names, no real row).
const (
	avHat        = 501 // a man's hat, 13/1
	avDress      = 502 // a man's dress that takes an attachment, 13/2
	avAttach     = 503 // a man's attachment, 13/3
	avFlag       = 504 // a man's flag, 13/4
	avSpirit     = 505 // a man's devil's spirit, 14/1, 3600 s
	avDressNoAtt = 506 // a man's dress that takes none
	avHatWoman   = 507
	avHelm       = 508 // an armour helm, 3/1/1/1
	avOdd        = 509 // a synthetic 13/5: a fifth distinct type, to fill the storage
	avHatLevel   = 510 // a man's hat asking level 99
	avHatEurope  = 511 // Europe's
	avHat2       = 512 // another man's hat
	avExtension  = 513 // a Nasrun extension 3/3/13/16, 100 s
)

// avatarItemTable is an item table whose stacks are each row's MaxStack
// (stubShopItems stacks everything to 100).
type avatarItemTable map[int64]*refdata.Item

func (s avatarItemTable) GetItem(_ context.Context, id int64) (*refdata.Item, error) {
	if it, ok := s[id]; ok {
		return it, nil
	}
	return nil, refdata.ErrItemNotFound
}

func (s avatarItemTable) GetMaxStack(_ context.Context, id int64) (int, error) {
	if it, ok := s[id]; ok {
		return it.MaxStack, nil
	}
	return 0, nil
}

func avatarItems() avatarItemTable {
	mk := func(id int64, t3, t4, gender int) *refdata.Item {
		return &refdata.Item{ID: id, MaxStack: 1, TypeID1: 3, TypeID2: 1, TypeID3: t3, TypeID4: t4, ReqGender: gender,
			Country: 3, ItemClass: 1, ReqLevelType1: -1, CanUse: true, MaxMagicOptions: 2, CodeName: "ITEM_TEST"}
	}
	items := avatarItemTable{
		avHat: mk(avHat, 13, 1, 1), avDress: mk(avDress, 13, 2, 1), avAttach: mk(avAttach, 13, 3, 1),
		avFlag: mk(avFlag, 13, 4, 1), avSpirit: mk(avSpirit, 14, 1, 1), avDressNoAtt: mk(avDressNoAtt, 13, 2, 1),
		avHatWoman: mk(avHatWoman, 13, 1, 0), avHelm: mk(avHelm, 1, 1, 1), avOdd: mk(avOdd, 13, 5, 1),
		avHatLevel: mk(avHatLevel, 13, 1, 1), avHatEurope: mk(avHatEurope, 13, 1, 1), avHat2: mk(avHat2, 13, 1, 1),
		avExtension: mk(avExtension, 13, 16, 2),
	}
	items[avDress].ChildItemCount = 1
	items[avDress].MaxMagicOptions = 4
	items[avSpirit].Param1 = 3600
	items[avHatLevel].ReqLevelType1, items[avHatLevel].ReqLevel1 = 1, 99
	items[avHatEurope].Country = 1
	items[avExtension].TypeID2 = 3
	items[avExtension].Param1 = 100
	return items
}

type avatarFixture struct {
	ctx   context.Context
	chars *character.MemStore
	c     *character.Character
	items avatarItemTable
	inv   *inventory.MemStore
	av    *inventory.MemStore
	d     AvatarDeps
}

func newAvatarFixture(t *testing.T) *avatarFixture {
	t.Helper()
	f := &avatarFixture{ctx: context.Background(), chars: character.NewMemStore(), items: avatarItems()}
	c, err := f.chars.Create(f.ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	f.c = c
	f.inv = inventory.NewMemStore(f.items)
	f.av = avatar.NewMem(f.items)
	f.d = AvatarDeps{Chars: f.chars, Inv: f.inv, Avatars: f.av, Items: f.items}
	return f
}

// bag puts ids into the bag, one a slot, from slot 0; awake spirits.
func (f *avatarFixture) bag(t *testing.T, ids ...int64) {
	t.Helper()
	for _, id := range ids {
		inst := inventory.Instance{}
		if id == avSpirit {
			inst.Durability = int(time.Now().Unix() + 3600)
		}
		if err := f.inv.AddItemInstance(f.ctx, f.c.ID, id, 1, inst); err != nil {
			t.Fatal(err)
		}
	}
}

// wear places ids into the avatar slots from 0.
func (f *avatarFixture) wear(t *testing.T, ids ...int64) {
	t.Helper()
	held, _ := f.av.List(f.ctx, f.c.ID)
	for i, id := range ids {
		if err := f.av.PlaceItemInstance(f.ctx, f.c.ID, len(held)+i, id, 1, inventory.Instance{}); err != nil {
			t.Fatal(err)
		}
	}
}

func (f *avatarFixture) slots(t *testing.T, st inventory.Store) map[int]int64 {
	t.Helper()
	list, err := st.List(f.ctx, f.c.ID)
	if err != nil {
		t.Fatal(err)
	}
	out := map[int]int64{}
	for _, s := range list {
		out[s.Index] = s.ItemID
	}
	return out
}

func (f *avatarFixture) put(t *testing.T, src, dst byte) (*AvatarMoveResult, []movedAvatar, uint16) {
	t.Helper()
	res, moved, err := bagToAvatar(f.ctx, f.d, f.c.ID, f.c, &AvatarMove{Type: ItemMoveBagToAvatar, Src: src, Dst: dst})
	code, refused := avatarRefusal(err)
	if err != nil && !refused {
		t.Fatalf("bagToAvatar: %v", err)
	}
	return res, moved, code
}

func (f *avatarFixture) take(t *testing.T, src, dst byte) (*AvatarMoveResult, []movedAvatar, uint16) {
	t.Helper()
	res, moved, err := avatarToBag(f.ctx, f.d, f.c.ID, &AvatarMove{Type: ItemMoveAvatarToBag, Src: src, Dst: dst})
	code, refused := avatarRefusal(err)
	if err != nil && !refused {
		t.Fatalf("avatarToBag: %v", err)
	}
	return res, moved, code
}

// 0x24's refusals, each in s:0x525950's order (AVATAR_RESEARCH.md 1.3), and
// an item that breaks two rules gets the earlier one's code.
func TestAvatarPutRefusalsInOrder(t *testing.T) {
	cases := []struct {
		name string
		bag  []int64 // bag slot 0, 1, ...
		worn []int64
		src  byte
		dst  byte
		want uint16
	}{
		{"source below the bag", nil, nil, 12, 0, avatar.CodeInvalidTarget},
		{"source past 0x6f", nil, nil, 0x70, 0, avatar.CodeInvalidTarget},
		{"empty source", nil, nil, 13, 0, avatar.CodeEmpty},
		{"position past 12, even for armour", []int64{avHelm}, nil, 13, 13, avatar.CodeWrongPosition},
		{"the other gender", []int64{avHatWoman}, []int64{avHat}, 13, 0, avatar.CodeGender},
		{"level", []int64{avHatLevel}, nil, 13, 0, avatar.CodeLevel},
		{"country", []int64{avHatEurope}, nil, 13, 0, avatar.CodeCountry},
		{"not an avatar", []int64{avHelm}, nil, 13, 0, avatar.CodeEquipItem},
		{"the same type worn, no swap", []int64{avHat2}, []int64{avHat}, 13, 1, avatar.CodeEquipItem},
		{"an attachment with no dress", []int64{avAttach}, []int64{avHat}, 13, 1, avatar.CodeEquipItem},
		{"an attachment on a dress that takes none", []int64{avAttach}, []int64{avDressNoAtt}, 13, 1, avatar.CodeEquipItem},
		{"position 5..12 is the storage's 3", []int64{avHat}, nil, 13, 5, avatar.CodeInvalidTarget},
		{"full", []int64{avOdd}, []int64{avHat, avDress, avAttach, avFlag, avSpirit}, 13, 0, avatar.CodeFull},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			f := newAvatarFixture(t)
			f.bag(t, tc.bag...)
			f.wear(t, tc.worn...)
			_, _, code := f.put(t, tc.src, tc.dst)
			if code != tc.want {
				t.Fatalf("code 0x%x, want 0x%x", code, tc.want)
			}
		})
	}
	// A devil's spirit never awakened: 0x18f9.
	f := newAvatarFixture(t)
	if err := f.inv.AddItemInstance(f.ctx, f.c.ID, avSpirit, 1, inventory.Instance{Durability: -1}); err != nil {
		t.Fatal(err)
	}
	if _, _, code := f.put(t, 13, 4); code != avatar.CodeNotAwake {
		t.Fatalf("a sleeping spirit: 0x%x", code)
	}
	// Str and Int, after the level and before the country.
	f = newAvatarFixture(t)
	f.items[avHat].ReqStr = 9999
	f.bag(t, avHat)
	if _, _, code := f.put(t, 13, 0); code != avatar.CodeStr {
		t.Fatalf("Str: 0x%x", code)
	}
	f.items[avHat].ReqStr, f.items[avHat].ReqInt = 0, 9999
	if _, _, code := f.put(t, 13, 0); code != avatar.CodeInt {
		t.Fatalf("Int: 0x%x", code)
	}
}

// The slot choice (s:0x523f70): the client's slot when empty, else the first
// empty one; the instance moves with the item.
func TestAvatarPutSlotChoice(t *testing.T) {
	f := newAvatarFixture(t)
	f.bag(t, avHat, avDress, avSpirit)
	inst := inventory.Instance{OptLevel: 7, Variance: 0x1234, MagParams: []uint64{inventory.MagParam(246, 1)}}
	if err := f.inv.SetInstance(f.ctx, f.c.ID, 0, inst); err != nil {
		t.Fatal(err)
	}
	res, moved, code := f.put(t, 13, 3)
	if code != 0 || res.Dst != 3 || len(moved) != 1 || !moved[0].on || moved[0].avatarSlot != 3 || moved[0].plus != 7 {
		t.Fatalf("an empty slot kept: %+v %+v 0x%x", res, moved, code)
	}
	held, _ := f.av.List(f.ctx, f.c.ID)
	if len(held) != 1 || held[0].Index != 3 || held[0].OptLevel != 7 || held[0].Variance != 0x1234 || len(held[0].MagParams) != 1 {
		t.Fatalf("the instance did not move with it: %+v", held)
	}
	// The dress asks for slot 3, taken: the first empty, 0.
	res, _, code = f.put(t, 14, 3)
	if code != 0 || res.Dst != 0 {
		t.Fatalf("an occupied slot: %+v 0x%x", res, code)
	}
	// The awake spirit to the client's 4.
	res, moved, code = f.put(t, 15, 4)
	if code != 0 || res.Dst != 4 || moved[0].spiritData <= 0 {
		t.Fatalf("the spirit: %+v %+v 0x%x", res, moved, code)
	}
	if got := f.slots(t, f.inv); len(got) != 0 {
		t.Fatalf("the bag kept %v", got)
	}
	want := (&AvatarMoveResult{OK: true, Type: ItemMoveBagToAvatar, Src: 15, Dst: 4, Subs: []AvatarSubOp{}}).Encode()
	if !bytes.Equal(res.Encode(), want) {
		t.Fatalf("reply % x, want % x", res.Encode(), want)
	}
}

// 0x23: the first free bag slot whatever the client named; a dress worn with
// an attachment brings it along as a sub-op into the next free slot, which
// needs two free slots; the refusals.
func TestAvatarTakeOff(t *testing.T) {
	f := newAvatarFixture(t)
	f.wear(t, avDress, avHat, avAttach)
	if _, _, code := f.take(t, 4, 20); code != avatar.CodeEmpty {
		t.Fatalf("an empty avatar slot: 0x%x", code)
	}
	// The hat: the client named bag slot 7 (wire 20); the first free is 0.
	res, moved, code := f.take(t, 1, 20)
	if code != 0 || res.Dst != 13 || len(res.Subs) != 0 || len(moved) != 1 || moved[0].on || moved[0].avatarSlot != 1 || moved[0].itemID != avHat {
		t.Fatalf("the hat: %+v %+v 0x%x", res, moved, code)
	}
	// Fill the bag but one slot: the dress with its attachment needs two.
	capacity := inventory.PlacementCapacityOf(f.ctx, f.inv, f.c.ID)
	for i := 1; i < capacity-1; i++ {
		if err := f.inv.AddItemInstance(f.ctx, f.c.ID, avHelm, 1, inventory.Instance{}); err != nil {
			t.Fatal(err)
		}
	}
	if _, _, code := f.take(t, 0, 13); code != avatar.CodeFull {
		t.Fatalf("one free slot for a dress and its attachment: 0x%x", code)
	}
	if err := f.inv.RemoveItem(f.ctx, f.c.ID, 5, 1); err != nil {
		t.Fatal(err)
	}
	res, moved, code = f.take(t, 0, 13)
	// Free: 5 and capacity-1. The dress to 5, the attachment (slot 2) to the next.
	wantSub := AvatarSubOp{Type: ItemMoveAvatarToBag, Src: 2, Dst: byte(capacity - 1 + 13)}
	if code != 0 || res.Dst != 5+13 || !reflect.DeepEqual(res.Subs, []AvatarSubOp{wantSub}) {
		t.Fatalf("the dress: %+v 0x%x", res, code)
	}
	// The broadcasts: the sub-op's first (s:0x50f1f0).
	if len(moved) != 2 || moved[0].avatarSlot != 2 || moved[0].itemID != avAttach || moved[1].avatarSlot != 0 || moved[1].itemID != avDress {
		t.Fatalf("moved %+v", moved)
	}
	if got := f.slots(t, f.av); len(got) != 0 {
		t.Fatalf("the avatar slots kept %v", got)
	}
	// The bag is full now; a flag worn: 0x1807.
	f.wear(t, avFlag)
	if _, _, code := f.take(t, 0, 13); code != avatar.CodeFull {
		t.Fatalf("a full bag: 0x%x", code)
	}
}

// An avatar never goes into an equipment slot (CheckEquipsetIntegrity:
// "Equiped Avatar Item!!", s:0x4bb020): the equip refuses it.
func TestAvatarNotInEquipmentSlots(t *testing.T) {
	items := avatarItems()
	for _, id := range []int64{avHat, avDress, avSpirit} {
		for slot := equipment.Slot(0); slot < equipment.MaxEquipSlots; slot++ {
			if err := equipment.Refusal(nil, items[id], slot, nil); !errors.Is(err, equipment.ErrNotEquippable) {
				t.Fatalf("item %d in slot %d: %v", id, slot, err)
			}
		}
	}
}

// The stats: an avatar's options through the READ table, a sleeping or
// expired devil's spirit nothing, no set bonus; the character's totals and
// bonus follow the avatar store (charTotals, buffBonus).
func TestAvatarStats(t *testing.T) {
	kinds := []magicopt.Kind{{TypeID3: 13}, {TypeID3: 14}}
	table := magicopt.New([]*magicopt.Row{
		{ID: 246, Code: "MATTR_AVATAR_STR", Level: 1, Tag: magicopt.PackTag("stra"), Params: [4]uint32{1, 1, 1}, Kinds: kinds},
		{ID: 250, Code: "MATTR_AVATAR_HP", Level: 1, Tag: magicopt.PackTag("hpa"), Params: [4]uint32{1, 150, 150}, Kinds: kinds},
		{ID: 249, Code: "MATTR_AVATAR_ER", Level: 1, Tag: magicopt.PackTag("era"), Params: [4]uint32{6, 5, 5}, Kinds: kinds},
		{ID: 253, Code: "MATTR_AVATAR_DARA", Level: 1, Tag: magicopt.PackTag("dara"), Params: [4]uint32{6, 5, 5}, Kinds: kinds},
		{ID: 355, Code: "MATTR_NASRUN_MPNA", Level: 1, Tag: magicopt.PackTag("mpna"), Params: [4]uint32{6, 1, 100}, Kinds: kinds},
	})
	items := avatarItems()
	now := time.Unix(2_000_000, 0)
	held := []avatar.Held{
		{Slot: inventory.Slot{Index: 0, ItemID: avHat, MagParams: []uint64{inventory.MagParam(246, 1), inventory.MagParam(246, 1), inventory.MagParam(249, 5)}}, Item: items[avHat]},
		{Slot: inventory.Slot{Index: 1, ItemID: avDress, MagParams: []uint64{inventory.MagParam(250, 150), inventory.MagParam(253, 5)}}, Item: items[avDress]},
		{Slot: inventory.Slot{Index: 4, ItemID: avSpirit, Durability: 2_000_100, MagParams: []uint64{inventory.MagParam(355, 30)}}, Item: items[avSpirit]},
	}
	got := AvatarParamTotals(held, table, now)
	if got[buff.ParamStr].Flat != 2 || got[buff.ParamMaxHP].Flat != 150 || got[buff.ParamParry].Pct != 5 || got[53].Pct != 30 {
		t.Fatalf("totals %+v", got)
	}
	if m := got[buff.ParamDefenderMult]; !m.HasMult || math.Abs(m.Mult-0.95) > 1e-9 {
		t.Fatalf("dara: %+v, want x0.95 on the blow taken", m)
	}
	// The spirit asleep, then expired: its options gone.
	for _, data := range []int{0, 1_999_999} {
		held[2].Slot.Durability = data
		if _, ok := AvatarParamTotals(held, table, now)[53]; ok {
			t.Fatalf("a spirit with Data %d still counts", data)
		}
	}

	// Through the registry: the character's totals and its Str/HP bonus.
	f := newAvatarFixture(t)
	SetMagicOptions(table)
	SetAvatarStore(f.av, f.inv, f.items, nil)
	t.Cleanup(func() { SetMagicOptions(nil); SetAvatarStore(nil, nil, nil, nil) })
	str0, hp0 := f.c.TotalStr(), f.c.MaxHP()
	if err := f.av.PlaceItemInstance(f.ctx, f.c.ID, 0, avHat, 1, inventory.Instance{MagParams: []uint64{inventory.MagParam(246, 1)}}); err != nil {
		t.Fatal(err)
	}
	if err := f.av.PlaceItemInstance(f.ctx, f.c.ID, 1, avDress, 1, inventory.Instance{MagParams: []uint64{inventory.MagParam(250, 150)}}); err != nil {
		t.Fatal(err)
	}
	invalidateAvatarStats(f.c.ID)
	if b := buffBonus(f.c.ID); b.Str != 1 || b.HP != 150 {
		t.Fatalf("bonus %+v", b)
	}
	c, _ := f.chars.GetByID(f.ctx, f.c.ID)
	if c.TotalStr() != str0+1 || c.MaxHP() <= hp0 {
		t.Fatalf("Str %d -> %d, MaxHP %d -> %d", str0, c.TotalStr(), hp0, c.MaxHP())
	}
	// Taken off: gone once the move invalidates.
	if _, _, err := f.av.TakeItem(f.ctx, f.c.ID, 0, 1, avHat); err != nil {
		t.Fatal(err)
	}
	invalidateAvatarStats(f.c.ID)
	if b := buffBonus(f.c.ID); b.Str != 0 || b.HP != 150 {
		t.Fatalf("after the hat came off: %+v", b)
	}
}

// The grant (_BlessItem gs:0x505810): append, re-roll in place, the cap, the
// name, the degree and the kind, the clamp.
func TestBlessAvatar(t *testing.T) {
	helmMail := []magicopt.Kind{{TypeID3: 13, TypeID4: 1}, {TypeID3: 13, TypeID4: 2}}
	mail := []magicopt.Kind{{TypeID3: 13, TypeID4: 2}}
	table := magicopt.New([]*magicopt.Row{
		{ID: 246, Code: "MATTR_AVATAR_STR", Level: 1, Tag: magicopt.PackTag("stra"), Params: [4]uint32{1, 1, 1}, Kinds: helmMail},
		{ID: 249, Code: "MATTR_AVATAR_ER", Level: 1, Tag: magicopt.PackTag("era"), Params: [4]uint32{6, 5, 5}, Kinds: helmMail},
		{ID: 250, Code: "MATTR_AVATAR_HP", Level: 1, Tag: magicopt.PackTag("hpa"), Params: [4]uint32{1, 150, 150}, Kinds: mail},
		{ID: 900, Code: "MATTR_TEST_BIG", Level: 1, Tag: magicopt.PackTag("hpa"), Params: [4]uint32{1, 5000, 5000}, Kinds: helmMail},
		{ID: 901, Code: "MATTR_TEST_ZERO", Level: 1, Tag: magicopt.PackTag("mpa"), Params: [4]uint32{1, 0, 0}, Kinds: helmMail},
	})
	rng := fixedRand(0)
	items := avatarItems()
	hat := items[avHat] // MaxMagicOptions 2
	p, code := BlessAvatar(hat, nil, "MATTR_AVATAR_STR", table, rng)
	if code != 0 || !reflect.DeepEqual(p, []uint64{inventory.MagParam(246, 1)}) {
		t.Fatalf("append: %v 0x%x", p, code)
	}
	if p2, code := BlessAvatar(hat, p, "mattr_avatar_str", table, rng); code != 0 || !reflect.DeepEqual(p2, p) {
		t.Fatalf("re-roll in place, the name case-insensitive: %v 0x%x", p2, code)
	}
	p, _ = BlessAvatar(hat, p, "MATTR_AVATAR_ER", table, rng)
	if len(p) != 2 {
		t.Fatalf("second option: %v", p)
	}
	if _, code := BlessAvatar(hat, p, "MATTR_TEST_BIG", table, rng); code != GrantErrCapNew {
		t.Fatalf("a new option at the cap: 0x%x", code)
	}
	if _, code := BlessAvatar(hat, append(p, inventory.MagParam(250, 1)), "MATTR_AVATAR_STR", table, rng); code != GrantErrOverCap {
		t.Fatalf("over the cap: 0x%x", code)
	}
	for _, name := range []string{"", "MATTR_NOPE", "MATTR_AVATAR_HP"} {
		if _, code := BlessAvatar(hat, nil, name, table, rng); code != GrantErrWrongOption {
			t.Fatalf("%q on a hat: 0x%x", name, code)
		}
	}
	deg2 := *hat
	deg2.ItemClass = 4 // degree 2: no record
	if _, code := BlessAvatar(&deg2, nil, "MATTR_AVATAR_STR", table, rng); code != GrantErrWrongOption {
		t.Fatalf("no record at the degree: 0x%x", code)
	}
	if p, _ := BlessAvatar(hat, nil, "MATTR_TEST_BIG", table, rng); inventory.MagParamValue(p[0]) != 1700 {
		t.Fatalf("clamped to 1700: %v", p)
	}
	if p, _ := BlessAvatar(hat, nil, "MATTR_TEST_ZERO", table, rng); inventory.MagParamValue(p[0]) != 1 {
		t.Fatalf("0 becomes 1: %v", p)
	}
}

type fixedRand int

func (r fixedRand) Intn(n int) int { return int(r) % n }

// The spawn record's avatar block and the lobby's: storage order, the plus,
// only avatar items.
func TestAvatarSpawnAndLobby(t *testing.T) {
	f := newAvatarFixture(t)
	SetAvatarStore(f.av, f.inv, f.items, nil)
	t.Cleanup(func() { SetAvatarStore(nil, nil, nil, nil) })
	for slot, id := range map[int]int64{3: avHat, 0: avDress, 4: avSpirit} {
		inst := inventory.Instance{OptLevel: byte(slot), AdvElixir: 1}
		if err := f.av.PlaceItemInstance(f.ctx, f.c.ID, slot, id, 1, inst); err != nil {
			t.Fatal(err)
		}
	}
	got := avatarSpawnItems(f.ctx, f.c.ID)
	want := []avatarSpawnItem{{avDress, 1}, {avHat, 4}, {avSpirit, 5}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("spawn avatars %+v, want %+v", got, want)
	}
	r := pcspawn.Record{RefObjID: 1907, InventorySize: 45, AvatarSize: pcAvatarSize, Name: "Aria", Team: pcspawn.TeamNone, JobState: pcspawn.JobStateNone,
		Avatars: []pcspawn.Item{{RefItemID: avDress, Plus: 1, HasPlus: true}, {RefItemID: avHat, Plus: 4, HasPlus: true}}}
	b, err := pcspawn.Append(nil, r)
	if err != nil {
		t.Fatal(err)
	}
	back, rest, err := pcspawn.Decode(b, nil)
	if err != nil || len(rest) != 0 || !reflect.DeepEqual(back.Avatars, r.Avatars) {
		t.Fatalf("decode %+v (%d left), %v", back.Avatars, len(rest), err)
	}
	d := &LobbyDeps{Avatars: f.av}
	rec := d.record(f.ctx, f.c, time.Now())
	wantLobby := []LobbyItem{{RefItemID: avDress, Plus: 0}, {RefItemID: avHat, Plus: 3}, {RefItemID: avSpirit, Plus: 4}}
	if !reflect.DeepEqual(rec.Avatars, wantLobby) {
		t.Fatalf("lobby avatars %+v, want %+v", rec.Avatars, wantLobby)
	}
}

// The world entry's integrity check: a failing item goes to the bag (OURS);
// with no room the entry is refused (retail refuses the login).
func TestAvatarIntegrityAtEntry(t *testing.T) {
	f := newAvatarFixture(t)
	SetAvatarStore(f.av, f.inv, f.items, nil)
	t.Cleanup(func() { SetAvatarStore(nil, nil, nil, nil) })
	f.wear(t, avHat, avHatWoman, avHelm, avHat2)
	if err := mendAvatarsAtEntry(f.ctx, f.c); err != nil {
		t.Fatal(err)
	}
	if got := f.slots(t, f.av); !reflect.DeepEqual(got, map[int]int64{0: avHat}) {
		t.Fatalf("avatar slots %v", got)
	}
	if got := f.slots(t, f.inv); len(got) != 3 {
		t.Fatalf("bag %v", got)
	}
	// No room: refused, the item kept where it was.
	capacity := inventory.PlacementCapacityOf(f.ctx, f.inv, f.c.ID)
	for i := 3; i < capacity; i++ {
		_ = f.inv.AddItemInstance(f.ctx, f.c.ID, avHelm, 1, inventory.Instance{})
	}
	f.wear(t, avHatWoman)
	if err := mendAvatarsAtEntry(f.ctx, f.c); !errors.Is(err, errAvatarIntegrity) {
		t.Fatalf("a full bag: %v", err)
	}
	if got := f.slots(t, f.av); len(got) != 2 {
		t.Fatalf("avatar slots after a refusal %v", got)
	}
}

// A devil's spirit in the bag carries its period word in every list.
func TestSpiritPeriodWordInLists(t *testing.T) {
	items := avatarItems()
	exp := int(time.Now().Unix() + 600)
	ii, ok := itemInfoFor(context.Background(), items, 2, avSpirit, inventory.Instance{Durability: exp})
	if !ok || ii.Durability&(1<<31) == 0 || ii.Durability&0x7fffffff < 590 || ii.Durability&0x7fffffff > 600 {
		t.Fatalf("awake: %#x", ii.Durability)
	}
	if ii, _ := itemInfoFor(context.Background(), items, 2, avSpirit, inventory.Instance{Durability: -1}); ii.Durability != 0 {
		t.Fatalf("asleep: %#x", ii.Durability)
	}
}

// End to end on the wire: the list, a put-on and a take-off with the
// broadcasts before the 0xB034, the dead and blocked framings, the grant,
// the dead avatar enchant.
func TestAvatarWireFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	f := newAvatarFixture(t)
	hub := world.NewHub()
	f.d.Hub = hub
	kinds := []magicopt.Kind{{TypeID3: 13, TypeID4: 1}, {TypeID3: 13, TypeID4: 2}}
	SetMagicOptions(magicopt.New([]*magicopt.Row{
		{ID: 246, Code: "MATTR_AVATAR_STR", Level: 1, Tag: magicopt.PackTag("stra"), Params: [4]uint32{1, 1, 1}, Kinds: kinds},
	}))
	SetAvatarStore(f.av, f.inv, f.items, hub)
	var pushed []int64
	savedPush := avatarStatsPush
	avatarStatsPush = func(id int64) { pushed = append(pushed, id) }
	t.Cleanup(func() { SetMagicOptions(nil); SetAvatarStore(nil, nil, nil, nil); avatarStatsPush = savedPush })
	f.bag(t, avDress, avAttach, avHelm)

	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(f.chars, nil, hub),
		ItemOpHandler(ItemOpDeps{Hub: hub, Inv: f.inv, Avatars: f.av, Items: f.items, Chars: f.chars}), AvatarHandler(f.d))
	addr, cleanup := startTestServer(t, handle)
	defer cleanup()
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	write := func(op uint16, data []byte) {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("write: %v", err)
		}
	}
	// readUntil returns every packet up to and including the first of op.
	readUntil := func(op uint16) []*proto.Packet {
		t.Helper()
		var out []*proto.Packet
		for {
			conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("read waiting for %#04x: %v (after %d)", op, err, len(out))
			}
			out = append(out, p)
			if p.Opcode == op {
				return out
			}
		}
	}
	write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	readUntil(OpLoginResult)
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(readUntil(OpEnterWorldResult)[0].Data); err != nil || !ewr.OK {
		// readUntil's last is the result; the first may be other traffic.
		_ = ewr
	}
	onlyOps := func(ps []*proto.Packet, keep ...uint16) []*proto.Packet {
		var out []*proto.Packet
		for _, p := range ps {
			for _, k := range keep {
				if p.Opcode == k {
					out = append(out, p)
				}
			}
		}
		return out
	}

	// The list: empty.
	write(OpAvatarList, (&CharacterNameRequest{Name: "Aria"}).Encode())
	if p := readUntil(OpAvatarListResult); !bytes.Equal(p[len(p)-1].Data, []byte{5, 0}) {
		t.Fatalf("empty list % x", p[len(p)-1].Data)
	}
	// The dress on (bag slot 0 -> client's 2): 0x3038 {uid, 2, ref, plus} then 0xB034.
	write(OpItemMove, []byte{ItemMoveBagToAvatar, 13, 2})
	ps := onlyOps(readUntil(OpItemMoveResult), OpEquipBroadcast, OpUnequipBroadcast, OpItemMoveResult)
	wantOn := (&EquipBroadcast{UID: uint32(f.c.ID), Slot: 2, RefItemID: avDress, HasPlus: true}).Encode()
	if len(ps) != 2 || ps[0].Opcode != OpEquipBroadcast || !bytes.Equal(ps[0].Data, wantOn) ||
		!bytes.Equal(ps[1].Data, []byte{1, 0x24, 13, 2, 0, 0, 0}) {
		t.Fatalf("put on: %v", ps)
	}
	// The attachment to the client's 2, taken: the first empty, 0.
	write(OpItemMove, []byte{ItemMoveBagToAvatar, 14, 2})
	ps = onlyOps(readUntil(OpItemMoveResult), OpEquipBroadcast, OpItemMoveResult)
	if len(ps) != 2 || ps[0].Data[4] != 0 || !bytes.Equal(ps[1].Data, []byte{1, 0x24, 14, 0, 0, 0, 0}) {
		t.Fatalf("attachment: %v", ps)
	}
	// The list now: slot 0 the attachment, 2 the dress.
	write(OpAvatarList, nil)
	l, err := DecodeAvatarList(readUntil(OpAvatarListResult)[0].Data)
	if err != nil || len(l.Items) != 2 || l.Items[0].Slot != 0 || l.Items[0].Info.RefItemID != avAttach || l.Items[1].Slot != 2 {
		t.Fatalf("list %+v %v", l, err)
	}
	// The dress off: the attachment's 0x3039 first, the dress's, then 0xB034
	// with the sub-op. The bag: slot 0 and 1 free (the helm is at 2).
	write(OpItemMove, []byte{ItemMoveAvatarToBag, 2, 40})
	ps = onlyOps(readUntil(OpItemMoveResult), OpEquipBroadcast, OpUnequipBroadcast, OpItemMoveResult)
	off := func(slot byte, ref uint32) []byte {
		return (&EquipBroadcast{UID: uint32(f.c.ID), Slot: slot, RefItemID: ref}).Encode()
	}
	if len(ps) != 3 || ps[0].Opcode != OpUnequipBroadcast || !bytes.Equal(ps[0].Data, off(0, avAttach)) ||
		ps[1].Opcode != OpUnequipBroadcast || !bytes.Equal(ps[1].Data, off(2, avDress)) ||
		!bytes.Equal(ps[2].Data, []byte{1, 0x23, 2, 13, 0, 0, 1, 0x23, 0, 14, 0, 0}) {
		t.Fatalf("take off: %v", ps)
	}
	if len(pushed) != 3 {
		t.Fatalf("stats pushed %d times, want one a move", len(pushed))
	}

	// The grant: the hat is not in the bag; the helm (slot 2) is not an
	// avatar (8); a slot past 111 (9); an empty one (3); the dress takes STR.
	grant := func(slot byte, code string) []byte {
		write(OpAvatarGrant, (&AvatarGrantRequest{Slot: slot, Code: code}).Encode())
		p := readUntil(OpAvatarGrantResult)
		return p[len(p)-1].Data
	}
	if got := grant(15, "MATTR_AVATAR_STR"); !bytes.Equal(got, []byte{2, 8, 0}) {
		t.Fatalf("grant on armour % x", got)
	}
	if got := grant(112, "MATTR_AVATAR_STR"); !bytes.Equal(got, []byte{2, 9, 0}) {
		t.Fatalf("grant past 111 % x", got)
	}
	if got := grant(30, "MATTR_AVATAR_STR"); !bytes.Equal(got, []byte{2, 3, 0}) {
		t.Fatalf("grant on an empty slot % x", got)
	}
	got, err := DecodeAvatarGrantResult(grant(13, "MATTR_AVATAR_STR"))
	if err != nil || !got.OK || got.Flag != 1 || got.Slot != 13 || got.Item.RefItemID != avDress ||
		!reflect.DeepEqual(got.Item.MagParams, []uint64{inventory.MagParam(246, 1)}) {
		t.Fatalf("grant: %+v %v", got, err)
	}
	// The avatar enchant: dead, 2, whatever it is given.
	write(OpAvatarEnchant, []byte{2, 1, 13})
	if p := readUntil(OpAvatarEnchantResult); !bytes.Equal(p[len(p)-1].Data, []byte{2, 2, 0}) {
		t.Fatalf("enchant % x", p[len(p)-1].Data)
	}

	// Dead: 2, before any rule.
	if !hub.SetLifeState(f.c.ID, world.LifeAlive, world.LifeDead, time.Now()) {
		t.Fatal("could not kill the fixture")
	}
	write(OpItemMove, []byte{ItemMoveBagToAvatar, 13, 0})
	if p := readUntil(OpItemMoveResult); !bytes.Equal(p[len(p)-1].Data, []byte{2, 2, 0}) {
		t.Fatalf("dead: % x", p[len(p)-1].Data)
	}
	_ = ctx
}
