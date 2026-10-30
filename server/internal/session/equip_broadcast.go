package session

import (
	"context"
	"encoding/binary"
	"errors"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Retail's equipment-change broadcasts (round 735; docs/protocol/weapon_glow.md
// lane B): the server tells the players around a character what it put on or
// took off, so their clients redress it.
//
// READ, both binaries:
//
//	0x3038  u32 uid, u8 slot, u32 RefItemID, u8 plus (equipment only)
//	0x3039  u32 uid, u8 slot, u32 RefItemID
//
// Server: the inventory-move handler builds them at 0x4e9de2 (0x3038) and
// 0x4e9f98 / 0x4e9d03 (0x3039). Each writes the mover's u32 unique id
// ([ebp+8]) and the slot byte of the move (the destination, [edi+4], for an
// equip; the source, [edi+3], for an unequip). 0x3038 then serializes the
// item with its vslot 294 at mode 2, which reaches CInstanceItem::vslot_010
// (0x42e230): u32 RefItemID (FUN_004958c0 of +0x28), then -- for an
// equipment item, !(w&2) && (b&0x1c)==0xc && (b&0x60)==0x20 -- one byte,
// OptLevel (+0x2c) plus the advanced elixir's sum (CInstanceItem::FUN_00846200).
// 0x3039 writes the RefItemID alone (the item's vslot 1 at +4). They go out
// through GObjPC::FUN_00484d90, a region-scoped send from the mover's own
// object.
//
// Which items (READ, round 735's review): the equip (0x4e9de2) and the
// type-0 unequip (0x4e9f98) are gated by FUN_00490390 on the ITEM: vslot
// +0x84 CGObj::IsEquip (0x483210: TypeID1 3, TypeID2 1), then either
// +0x454 (0x483b70: TypeID3 13, the avatars) or +0x470 (0x483cc0: TypeID3
// 14, the devil's spirit) or ResolveEquipSlotForItem 0..8 (armour, weapon,
// shield, job suit; never an accessory). The move-type-7 path's 0x3039
// (0x4e9d03: [edi] 7, source [edi+3] below 0xd) is NOT gated and covers every
// equip slot 0..12; OpenSRO has no such move. OpenSRO has no avatar slots, so
// its gate is slots 0..8.
//
// Client: FUN_008a9260 (0x3038) reads u32 uid, u8, u32 RefItemID and, for an
// equipment item by the same type-word test, u8 plus; it reads its slot byte
// into a variable the RefItemID then overwrites and redresses through the
// visual slot the item's type resolves to (ResolveVisualSlotForItem).
// FUN_008a9560 (0x3039) reads u32 uid, u8 slot, u32 RefItemID and, for a
// non-avatar item, clears THE MESSAGE'S SLOT (FUN_009daf70(slot, 0, 0, 0) ->
// InstallEquipVisual). Both then, for the player's own uid (DAT_00eef5e8,
// written only by CICPlayer::vslot_018), update the character window and its
// preview -- so retail tells the mover too.
//
// OpenSRO's side:
//   - uid is the low 32 bits of the character id, the u32 every retail
//     message OpenSRO sends names a player by (round 710).
//   - slot is OpenSRO's equipment.Slot, which is retail's equip slot index
//     (equipment.go's WearableSlots doc).
//   - The receivers are every character in the mover's zone, the mover
//     included, as retail's own-uid branch shows (round 735's review,
//     finding 5). The zone is OpenSRO's visibility scope (players spawn
//     zone-wide), where retail's send is by region: a DEPARTURE in scope only.
//     The mover's client has already redrawn its window and preview from its
//     equipment result (0x0041) and skips its own uid.
//   - A plus change on a worn item (the GM's /item worn, OURS -- retail
//     changes no worn item's plus) is sent as a 0x3038 of the same item.
const (
	OpEquipBroadcast   uint16 = 0x3038
	OpUnequipBroadcast uint16 = 0x3039
)

// BroadcastSlotMax is the highest equip slot that is broadcast
// (FUN_00490390's `8 < slot` refusal, READ; its avatar arms do not apply).
const BroadcastSlotMax = equipment.SlotJobSuit

// EquipBroadcast is a 0x3038 or 0x3039 payload.
type EquipBroadcast struct {
	UID       uint32
	Slot      uint8
	RefItemID uint32
	// Plus is written by Encode only when HasPlus: a 0x3038 of an
	// equipment item. A 0x3039 never carries it.
	Plus    uint8
	HasPlus bool
	// Own is the worn item's own RefItemID when RefItemID is the row a model
	// switcher has it drawn as (round 843, OURS: inventory.Instance.Model,
	// displayRef), else 0. Encode writes it after the plus, the message's
	// last field, only then -- every other 0x3038 is retail's bytes. The
	// observer's client draws the mesh from RefItemID and, where that row
	// has no glow or seal rows of its own, the item's own glow and seal
	// effects (docs/protocol/item_switchers.md section 3).
	Own uint32
}

// Encode writes the retail layout, and Own after it when set.
func (b *EquipBroadcast) Encode() []byte {
	out := make([]byte, 9, 14)
	binary.LittleEndian.PutUint32(out[0:], b.UID)
	out[4] = b.Slot
	binary.LittleEndian.PutUint32(out[5:], b.RefItemID)
	if b.HasPlus {
		out = append(out, b.Plus)
		if b.Own != 0 && b.Own != b.RefItemID {
			out = binary.LittleEndian.AppendUint32(out, b.Own)
		}
	}
	return out
}

// switchedOwn is the Own a 0x3038 of a worn item carries: its own id when a
// model switcher has it drawn as another row (round 843, OURS), else 0.
func switchedOwn(itemID, model int64) uint32 {
	if model > 0 && model != itemID {
		return uint32(itemID)
	}
	return 0
}

// DecodeEquipBroadcast reads either message; the plus is whatever byte
// follows the RefItemID (the client decides by the item's type).
func DecodeEquipBroadcast(data []byte) (*EquipBroadcast, error) {
	if len(data) < 9 {
		return nil, errors.New("session: decoding equip broadcast: truncated")
	}
	b := &EquipBroadcast{UID: binary.LittleEndian.Uint32(data), Slot: data[4], RefItemID: binary.LittleEndian.Uint32(data[5:])}
	if len(data) >= 10 {
		b.Plus, b.HasPlus = data[9], true
	}
	if len(data) >= 14 {
		b.Own = binary.LittleEndian.Uint32(data[10:])
	}
	return b, nil
}

// isEquipmentItem reports whether the client reads a plus after itemID: an
// item of TypeID1 3, TypeID2 1 (the type word's (b&0x1c)==0xc,
// (b&0x60)==0x20). With no item table, or an id it does not know, the item
// is taken as equipment: only equipment is worn (equipRefusal).
func isEquipmentItem(ctx context.Context, items ItemLookup, itemID int64) bool {
	if items == nil {
		return true
	}
	it, err := items.GetItem(ctx, itemID)
	if err != nil || it == nil {
		return true
	}
	return it.TypeID1 == 3 && it.TypeID2 == 1
}

// equipObservers is who hears characterID's equipment change: everyone in
// view of it (round 737: the 3 x 3 blocks, as retail's region-scoped
// GObjPC::FUN_00484d90 send; the zone until then), the mover included
// (retail's own-uid branch). The send itself reaches another player only
// while its client holds the mover's body (sendAboutOwner). Empty when there
// is no hub or the character is not in it.
func equipObservers(hub *world.Hub, characterID int64) []world.Entity {
	if hub == nil {
		return nil
	}
	var out []world.Entity
	for _, other := range hub.ViewOfCharacter(characterID) {
		if other.Session != nil {
			out = append(out, other)
		}
	}
	return out
}

// sendPlusesAsBroadcasts tells one arriving client the pluses a result had
// to leave out (EncodeFitting): a retail 0x3038 for every worn item with a
// plus, slots 0..8, of every other in the list. Only reached when the list
// with its pluses tail would not fit one frame.
func sendPlusesAsBroadcasts(sess interface{ Send(*proto.Packet) error }, others []EntitySnapshot) {
	for _, o := range others {
		for _, it := range o.Equipped {
			if it.Plus == 0 || equipment.Slot(it.Slot) > BroadcastSlotMax {
				continue
			}
			msg := &EquipBroadcast{UID: uint32(o.CharacterID), Slot: uint8(it.Slot), RefItemID: uint32(displayRef(it.ItemID, it.Model)), Plus: it.Plus, HasPlus: true,
				Own: switchedOwn(it.ItemID, it.Model)}
			_ = sess.Send(&proto.Packet{Opcode: OpEquipBroadcast, Data: msg.Encode()})
		}
	}
}

// broadcastWorn sends a 0x3038 of what characterID wears in slot: after an
// equip, and after a plus change on a worn item. Nothing for an empty slot
// or one past BroadcastSlotMax.
func broadcastWorn(ctx context.Context, hub *world.Hub, store equipment.Store, items ItemLookup, characterID int64, slot equipment.Slot) {
	invalidateLook(characterID) // round 737: the spawn record's cached look
	if slot > BroadcastSlotMax || store == nil {
		return
	}
	to := equipObservers(hub, characterID)
	if len(to) == 0 {
		return
	}
	worn, err := store.Get(ctx, characterID)
	if err != nil {
		return
	}
	for _, w := range worn {
		if w.Slot != slot {
			continue
		}
		// Round 838: a model switcher's choice is drawn (displayRef).
		msg := &EquipBroadcast{UID: uint32(characterID), Slot: uint8(slot), RefItemID: uint32(displayRef(w.ItemID, w.Model))}
		if isEquipmentItem(ctx, items, w.ItemID) {
			msg.Plus, msg.HasPlus = w.EffectivePlus(), true
			// Round 843: the item's own id beside the model's (OURS).
			msg.Own = switchedOwn(w.ItemID, w.Model)
		}
		sendAboutOwner(to, characterID, OpEquipBroadcast, msg.Encode())
		return
	}
}

// broadcastUnworn sends a 0x3039: characterID took itemID out of slot.
func broadcastUnworn(hub *world.Hub, characterID int64, slot equipment.Slot, itemID int64) {
	invalidateLook(characterID) // round 737: the spawn record's cached look
	if slot > BroadcastSlotMax {
		return
	}
	to := equipObservers(hub, characterID)
	if len(to) == 0 {
		return
	}
	msg := &EquipBroadcast{UID: uint32(characterID), Slot: uint8(slot), RefItemID: uint32(itemID)}
	sendAboutOwner(to, characterID, OpUnequipBroadcast, msg.Encode())
}

// wornIn is the item id characterID wears in slot, or 0.
func wornIn(ctx context.Context, store equipment.Store, characterID int64, slot equipment.Slot) int64 {
	worn, err := store.Get(ctx, characterID)
	if err != nil {
		return 0
	}
	for _, w := range worn {
		if w.Slot == slot {
			return w.ItemID
		}
	}
	return 0
}
