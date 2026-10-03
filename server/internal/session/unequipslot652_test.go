package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
)

// Round 652: "When I try drag an item from my person into the inventory to a
// slot I want it moves it to the next available slot instead."
//
// The user then chose the original's rule over a chosen slot. READ: the
// retail client names the clicked slot (FUN_007950b0, `bag slot + 13`), and
// retail's CGObjPC::DetachEquipItem overwrites it with the first empty bag
// slot (0x5258c6). So the unequip packet here carries the clicked slot -- by
// hand, as the client sends it -- and the server must IGNORE it. Equipping
// over a worn item swaps into the source slot (AttachEquipItem's SwapItem);
// that test is the negative against the base, which used the first free slot.

func unequipTo(name string, slot equipment.Slot, bagSlot int) []byte {
	out := encodeStrings(name)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(slot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(int32(bagSlot)))
	return append(out, buf...)
}

func unequipPlain(name string, slot equipment.Slot) []byte {
	out := encodeStrings(name)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(slot))
	return append(out, buf...)
}

type unequipRig struct {
	t    *testing.T
	ctx  context.Context
	id   int64
	inv  *inventory.MemStore
	eq   *equipment.MemStore
	send func(opcode uint16, data []byte) *proto.Packet
}

// Items: 4842 a man's mail, 4843 a second man's mail, 4 an HP potion.
func newUnequipRig(t *testing.T) (*unequipRig, func()) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	items := refdata.NewMemStore()
	mail := func(id int64) refdata.Item {
		return refdata.Item{ID: id, MaxStack: 1, TypeID1: equipment.TypeItem, TypeID2: equipment.TypeEquipment,
			TypeID3: equipment.FamilyChinaGarment, TypeID4: equipment.PieceMail, Country: equipment.CountryChina,
			ReqGender: equipment.ReqGenderMan, ReqLevelType1: equipment.ReqLevelTypeCharacter, ReqLevel1: 1}
	}
	if err := items.ImportItems(ctx, []refdata.Item{mail(4842), mail(4843),
		{ID: 4, MaxStack: 5000, TypeID1: equipment.TypeItem, TypeID2: 3, TypeID3: 1, TypeID4: 1, Country: equipment.CountryChina},
	}); err != nil {
		t.Fatalf("importing items: %v", err)
	}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)

	handle := gateway.Chain(LoginHandler(accounts), EquipmentHandlerWithRules(chars, eq, inv, items, nil))
	addr, cleanup := startTestServer(t, handle)
	conn := dialTestServer(t, addr)
	r := bufio.NewReader(conn)
	rig := &unequipRig{t: t, ctx: ctx, id: c.ID, inv: inv, eq: eq}
	rig.send = func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	resp := rig.send(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	return rig, func() { conn.Close(); cleanup() }
}

func (r *unequipRig) result(resp *proto.Packet) string {
	res, err := DecodeEquipmentResult(resp.Data)
	if err != nil {
		r.t.Fatalf("DecodeEquipmentResult: %v", err)
	}
	return res.Error
}

// bag maps slot -> item id.
func (r *unequipRig) bag() map[int]int64 {
	list, err := r.inv.List(r.ctx, r.id)
	if err != nil {
		r.t.Fatalf("List: %v", err)
	}
	out := map[int]int64{}
	for _, s := range list {
		out[s.Index] = s.ItemID
	}
	return out
}

func (r *unequipRig) worn(slot equipment.Slot) int64 {
	worn, _ := r.eq.Get(r.ctx, r.id)
	for _, w := range worn {
		if w.Slot == slot {
			return w.ItemID
		}
	}
	return -1
}

// wear puts itemID on through the bag, the real way.
func (r *unequipRig) wear(itemID int64, slot equipment.Slot) {
	if err := r.inv.AddItem(r.ctx, r.id, itemID, 1); err != nil {
		r.t.Fatalf("AddItem: %v", err)
	}
	for idx, id := range r.bag() {
		if id == itemID {
			if err := r.eq.Equip(r.ctx, r.id, slot, idx); err != nil {
				r.t.Fatalf("Equip: %v", err)
			}
			return
		}
	}
	r.t.Fatalf("item %d never reached the bag", itemID)
}

// The user's case: the worn suit is dropped on bag slot 10 while slot 0
// holds a potion. Retail's server ignores the 10 and uses the first free
// slot, 1 (DetachEquipItem, 0x5258c6).
func TestUnequipIgnoresTheClickedSlotAsRetailDoes(t *testing.T) {
	req, err := DecodeUnequipRequest(unequipTo("Aria", equipment.SlotMail, 10))
	if err != nil || !req.Targeted || req.InventorySlot != 10 {
		t.Fatalf("the clicked slot is still parsed (the packet stays compatible): %+v, %v", req, err)
	}
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	if err := r.inv.AddItem(r.ctx, r.id, 4, 1); err != nil { // slot 0
		t.Fatalf("AddItem: %v", err)
	}
	if got := r.result(r.send(OpUnequip, unequipTo("Aria", equipment.SlotMail, 10))); got != "" {
		t.Fatalf("unequip refused: %q", got)
	}
	bag := r.bag()
	if bag[1] != 4842 {
		t.Errorf("the unequipped suit is not in the first free slot 1: bag %v", bag)
	}
	if _, used := bag[10]; used {
		t.Errorf("the clicked slot 10 was used; retail's server ignores it: bag %v", bag)
	}
	if r.worn(equipment.SlotMail) != -1 {
		t.Errorf("the suit is still worn")
	}
}

// Dropped on a bag slot holding something that goes in the same worn slot:
// no swap -- the worn item goes to the first free slot and the bag item stays.
func TestUnequipOntoAWearableItemGoesToTheFirstFreeSlot(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	if err := r.inv.AddItem(r.ctx, r.id, 4, 1); err != nil { // slot 0, a potion
		t.Fatalf("AddItem: %v", err)
	}
	if err := r.inv.AddItem(r.ctx, r.id, 4843, 1); err != nil { // slot 1, the second suit
		t.Fatalf("AddItem: %v", err)
	}
	if got := r.result(r.send(OpUnequip, unequipTo("Aria", equipment.SlotMail, 1))); got != "" {
		t.Fatalf("unequip onto the second suit refused: %q", got)
	}
	bag := r.bag()
	if bag[1] != 4843 || bag[2] != 4842 {
		t.Errorf("want the second suit kept in 1 and the worn one in the first free slot 2: bag %v", bag)
	}
	if w := r.worn(equipment.SlotMail); w != -1 {
		t.Errorf("nothing should be worn after an unequip (no swap): worn %d", w)
	}
}

// Dropped on a slot holding something that cannot be worn there: retail's
// own placement, the first free slot. Nothing is refused, nothing lost.
func TestUnequipOntoAnUnwearableItemGoesToTheFirstFreeSlot(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	if err := r.inv.AddItem(r.ctx, r.id, 4, 1); err != nil { // slot 0, a potion
		t.Fatalf("AddItem: %v", err)
	}
	if got := r.result(r.send(OpUnequip, unequipTo("Aria", equipment.SlotMail, 0))); got != "" {
		t.Fatalf("unequip onto the potion refused: %q", got)
	}
	bag := r.bag()
	if bag[0] != 4 || bag[1] != 4842 {
		t.Errorf("want the potion kept in 0 and the suit in the first free slot 1: bag %v", bag)
	}
}

// Without a target (an older client) the server places it, first free.
func TestUnequipWithoutATargetGoesToTheFirstFreeSlot(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	if got := r.result(r.send(OpUnequip, unequipPlain("Aria", equipment.SlotMail))); got != "" {
		t.Fatalf("plain unequip refused: %q", got)
	}
	if bag := r.bag(); bag[0] != 4842 {
		t.Errorf("want the suit in the first free slot 0: bag %v", bag)
	}
}

// Equipping over a worn item swaps: the displaced one goes to the bag slot
// the new one came from, not to the first free slot.
func TestEquipOverAWornItemSwapsIntoTheSourceSlot(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	for _, id := range []int64{4, 4843} { // 0 potion, 1 the second suit
		if err := r.inv.AddItem(r.ctx, r.id, id, 1); err != nil {
			t.Fatalf("AddItem: %v", err)
		}
	}
	// Leave a hole at 0 so "first free" and "the source slot" differ.
	if err := r.inv.RemoveItem(r.ctx, r.id, 0, 1); err != nil {
		t.Fatalf("RemoveItem: %v", err)
	}
	resp := r.send(OpEquip, (&EquipRequest{CharacterName: "Aria", Slot: equipment.SlotMail, InventorySlot: 1}).Encode())
	if got := r.result(resp); got != "" {
		t.Fatalf("equip refused: %q", got)
	}
	bag := r.bag()
	if bag[1] != 4842 {
		t.Errorf("the displaced suit is not in the source slot 1: bag %v", bag)
	}
	if _, stray := bag[0]; stray {
		t.Errorf("the displaced suit went to the first free slot 0: bag %v", bag)
	}
	if w := r.worn(equipment.SlotMail); w != 4843 {
		t.Errorf("worn %d, want 4843", w)
	}
}
