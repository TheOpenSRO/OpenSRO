package session

import (
	"bufio"
	"context"
	"encoding/binary"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
)

// Round 652: "When I try drag an item from my person into the inventory to a
// slot I want it moves it to the next available slot instead."
//
// The unequip packet here is written by hand -- name, worn slot, then the
// clicked bag slot as a trailing int32, which is what the client sends since
// round 652 -- so this file compiles against the base too, where the trailing
// word is ignored and the item goes to the first free slot. That is the
// negative: on the base, "lands in the clicked slot" FAILs.

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
// holds a potion. It must land in 10, not in the first free slot (1).
func TestUnequipLandsInTheClickedSlot(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	if err := r.inv.AddItem(r.ctx, r.id, 4, 1); err != nil { // slot 0
		t.Fatalf("AddItem: %v", err)
	}
	if got := r.result(r.send(OpUnequip, unequipTo("Aria", equipment.SlotMail, 10))); got != "" {
		t.Fatalf("unequip into slot 10 refused: %q", got)
	}
	bag := r.bag()
	if bag[10] != 4842 {
		t.Errorf("unequipped item is not in the clicked slot 10: bag %v (the first free slot is 1)", bag)
	}
	if _, stray := bag[1]; stray {
		t.Errorf("the first free slot (1) was used instead of the clicked one: bag %v", bag)
	}
	if r.worn(equipment.SlotMail) != -1 {
		t.Errorf("the suit is still worn")
	}
}

// Dropped on a bag slot holding something that goes in the same worn slot:
// the two change places (AttachEquipItem's SwapItem, the other direction).
func TestUnequipOntoAWearableItemSwaps(t *testing.T) {
	r, done := newUnequipRig(t)
	defer done()
	r.wear(4842, equipment.SlotMail)
	for i := 0; i < 4; i++ { // slots 0..3 potions, the second suit in 4
		if err := r.inv.AddItem(r.ctx, r.id, 4, 1); err != nil {
			t.Fatalf("AddItem: %v", err)
		}
	}
	if err := r.inv.AddItem(r.ctx, r.id, 4843, 1); err != nil {
		t.Fatalf("AddItem: %v", err)
	}
	// Potions stack: slot 0 holds all four, so the suit is at slot 1.
	suitAt := -1
	for idx, id := range r.bag() {
		if id == 4843 {
			suitAt = idx
		}
	}
	if suitAt < 0 {
		t.Fatalf("the second suit is not in the bag: %v", r.bag())
	}
	if got := r.result(r.send(OpUnequip, unequipTo("Aria", equipment.SlotMail, suitAt))); got != "" {
		t.Fatalf("unequip onto the second suit refused: %q", got)
	}
	if bag := r.bag(); bag[suitAt] != 4842 {
		t.Errorf("the worn suit did not take the clicked slot %d: bag %v", suitAt, bag)
	}
	if w := r.worn(equipment.SlotMail); w != 4843 {
		t.Errorf("the suit from the clicked slot is not worn now: worn %d", w)
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
