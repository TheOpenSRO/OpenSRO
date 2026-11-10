package session

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/trade"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Equipment opcodes, our own protocol. All take a character name (like
// inventory/world) and require a prior OpLogin.
const (
	OpEquipmentList   uint16 = 0x0040 // client -> server
	OpEquipmentResult uint16 = 0x0041 // server -> client (list, or equip/unequip result)
	OpEquip           uint16 = 0x0042 // client -> server
	OpUnequip         uint16 = 0x0043 // client -> server
)

// EquippedSnapshot is one equipped item, as sent over the wire.
type EquippedSnapshot struct {
	Slot   int
	ItemID int64
	// Plus is the item's effective plus (equipment.Equipped.EffectivePlus,
	// round 735), for the snapshots that show other players. Encode leaves
	// it out -- the own list's items carry their whole instance in Infos --
	// and the entity snapshots send it in their pluses tail (encodePluses).
	Plus uint8
	// Model is the worn item's drawn model (round 838, OURS:
	// inventory.Instance.Model), 0 for its own. Encode leaves it out; the
	// spawn record a client draws another player from carries it in place of
	// the item's own id (displayRef).
	Model int64
}

// displayRef is the item id another player's client is told a worn item is
// (round 838, OURS): the row whose model the item is drawn with when a model
// switcher gave it one, else the item's own. Only the clients that DRAW the
// item hear it -- the 0x3015/0x3019 spawn record (lookOf) and the 0x3038
// broadcast (broadcastWorn) -- and they read nothing from it but the drawing:
// the model, the weapon's glow type (itemoption.txt lists the _SWITCHnn rows
// with their own types, which follow the mesh) and the visual slot, which the
// row's TypeIDs keep. The owner's own lists carry the true id and the model
// beside it (ItemInfo.Model).
func displayRef(itemID, model int64) int64 {
	if model > 0 {
		return model
	}
	return itemID
}

func (e *EquippedSnapshot) Encode() []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, uint32(e.Slot))
	return append(out, encodeInt64(e.ItemID)...)
}

func decodeEquippedSnapshot(data []byte) (*EquippedSnapshot, []byte, error) {
	if len(data) < 4 {
		return nil, nil, errors.New("slot: truncated")
	}
	slot := int(binary.LittleEndian.Uint32(data))
	itemID, rest, err := decodeInt64(data[4:])
	if err != nil {
		return nil, nil, fmt.Errorf("item id: %w", err)
	}
	return &EquippedSnapshot{Slot: slot, ItemID: itemID}, rest, nil
}

// EquipmentResult is the OpEquipmentResult payload: either a list (from
// OpEquipmentList) or just an error/success marker (from OpEquip/OpUnequip
// -- Items is empty on those).
type EquipmentResult struct {
	Error string
	Items []EquippedSnapshot
	// Durabilities is the trailing per-slot durability block (see
	// DurabilitySnapshot): additive, so an older client ignores it.
	Durabilities []DurabilitySnapshot
	// Infos is the trailing item-instance block (round 732, ItemInfo),
	// after the durability block.
	Infos []ItemInfo
}

func (r *EquipmentResult) Encode() []byte {
	out := encodeStrings(r.Error)
	countBuf := make([]byte, 2)
	binary.LittleEndian.PutUint16(countBuf, uint16(len(r.Items)))
	out = append(out, countBuf...)
	for _, it := range r.Items {
		out = append(out, it.Encode()...)
	}
	out = encodeDurabilityBlock(out, r.Durabilities)
	if len(r.Infos) == 0 {
		return out
	}
	return encodeItemInfoBlock(out, fitItemInfos(len(out), r.Infos))
}

func DecodeEquipmentResult(data []byte) (*EquipmentResult, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EquipmentResult: %w", err)
	}
	if len(rest) < 2 {
		return nil, errors.New("session: decoding EquipmentResult: truncated count")
	}
	count := int(binary.LittleEndian.Uint16(rest))
	rest = rest[2:]

	result := &EquipmentResult{Error: fields[0]}
	for i := 0; i < count; i++ {
		var snap *EquippedSnapshot
		snap, rest, err = decodeEquippedSnapshot(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding EquipmentResult: item %d: %w", i, err)
		}
		result.Items = append(result.Items, *snap)
	}
	result.Durabilities = decodeDurabilityBlock(rest)
	if skip := 2 + 12*len(result.Durabilities); len(rest) >= skip {
		rest = rest[skip:]
		infos, err := decodeItemInfoBlock(rest)
		if err != nil {
			return nil, fmt.Errorf("session: decoding EquipmentResult: %w", err)
		}
		result.Infos = infos
	}
	return result, nil
}

// EquipRequest is the OpEquip payload: which character, which equipment
// slot, and which inventory slot to equip from.
type EquipRequest struct {
	CharacterName string
	Slot          equipment.Slot
	InventorySlot int
}

func (r *EquipRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 8)
	binary.LittleEndian.PutUint32(buf[0:4], uint32(r.Slot))
	binary.LittleEndian.PutUint32(buf[4:8], uint32(r.InventorySlot))
	return append(out, buf...)
}

func DecodeEquipRequest(data []byte) (*EquipRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding EquipRequest: %w", err)
	}
	if len(rest) < 8 {
		return nil, errors.New("session: decoding EquipRequest: truncated")
	}
	slot := equipment.Slot(binary.LittleEndian.Uint32(rest[0:4]))
	invSlot := int(binary.LittleEndian.Uint32(rest[4:8]))
	return &EquipRequest{CharacterName: fields[0], Slot: slot, InventorySlot: invSlot}, nil
}

// UnequipRequest is the OpUnequip payload: which character, which slot,
// and (since round 652) which bag slot the item was dropped on.
//
// InventorySlot is the retail client's destination (FUN_007950b0 sends
// `bag slot + 13` for a worn item dropped on the bag, READ), an optional
// trailing int32. The server parses it and, as retail's
// CGObjPC::DetachEquipItem does, does not use it: the item goes to the first
// free slot (see equipment/placement.go).
type UnequipRequest struct {
	CharacterName string
	Slot          equipment.Slot
	// Targeted says InventorySlot was sent: a zero value is "no target", not
	// bag slot 0.
	Targeted      bool
	InventorySlot int
}

func (r *UnequipRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	buf := make([]byte, 4)
	binary.LittleEndian.PutUint32(buf, uint32(r.Slot))
	out = append(out, buf...)
	if r.Targeted {
		to := make([]byte, 4)
		binary.LittleEndian.PutUint32(to, uint32(int32(r.InventorySlot)))
		out = append(out, to...)
	}
	return out
}

func DecodeUnequipRequest(data []byte) (*UnequipRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding UnequipRequest: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding UnequipRequest: truncated")
	}
	slot := equipment.Slot(binary.LittleEndian.Uint32(rest))
	req := &UnequipRequest{CharacterName: fields[0], Slot: slot, InventorySlot: -1}
	if len(rest) >= 8 {
		req.InventorySlot = int(int32(binary.LittleEndian.Uint32(rest[4:8])))
		req.Targeted = req.InventorySlot >= 0
	}
	return req, nil
}

// EquipmentHandler returns a gateway.Handler implementing
// OpEquipmentList/OpEquip/OpUnequip against store, resolving character
// names against whichever account authenticated on the connection. With
// no inventory or item reference data it applies no wearing rules -- what
// the tests that only care about the slot mechanics want. No trade hub
// either, so nothing is locked by a trade.
func EquipmentHandler(chars character.Store, store equipment.Store) gateway.Handler {
	return EquipmentHandlerWithRules(chars, store, nil, nil, nil)
}

// EquipmentHandlerWithRules is EquipmentHandler plus the item table's own
// rules for who may wear what (see equipment.Refusal): before an item is
// moved into a slot, the item in the named inventory slot is looked up in
// items, and refused if it is not something that goes in that slot, or is
// for another race, the other gender, or a level the character has not
// reached. inv and items may both be nil, which disables the rules.
//
// An equip or unequip during an ACCEPTED trade is refused
// (tradeEquipLockedReason, tradebusy.go); a pending request does not lock
// equipment. trades may be nil, which locks nothing.
func EquipmentHandlerWithRules(chars character.Store, store equipment.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub) gateway.Handler {
	return EquipmentHandlerWithBroadcast(chars, store, inv, items, trades, nil)
}

// EquipmentHandlerWithBroadcast is EquipmentHandlerWithRules plus the
// world hub the change is told to: a successful equip sends retail 0x3038
// and an unequip 0x3039 to the other characters in the zone
// (equip_broadcast.go, round 735). A nil hub tells no one.
func EquipmentHandlerWithBroadcast(chars character.Store, store equipment.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub, hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		switch p.Opcode {
		case OpEquipmentList:
			return handleEquipmentList(ctx, sess, p, chars, store, items)
		case OpEquip:
			return handleEquip(ctx, sess, p, chars, store, inv, items, trades, hub)
		case OpUnequip:
			return handleUnequip(ctx, sess, p, chars, store, items, trades, hub)
		default:
			return nil
		}
	}
}

// ItemLookup is the slice of reference data the wearing rules need.
type ItemLookup interface {
	GetItem(ctx context.Context, id int64) (*refdata.Item, error)
}

// equipRefusal applies equipment.Refusal to the item sitting in
// characterID's inventorySlot. Returns "" when the item may be worn -- or
// when there is no way to tell: no inventory or item data wired, no
// reference row for the item, or a character that cannot be read.
func equipRefusal(ctx context.Context, chars character.Store, store equipment.Store, inv inventory.Store, items ItemLookup, characterID int64, slot equipment.Slot, inventorySlot int) string {
	if inv == nil || items == nil {
		return ""
	}
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return ""
	}
	var itemID int64 = -1
	for _, sl := range slots {
		if sl.Index == inventorySlot {
			itemID = sl.ItemID
			break
		}
	}
	if itemID == -1 {
		// The store reports the empty slot itself.
		return ""
	}
	item, err := items.GetItem(ctx, itemID)
	if err != nil || item == nil {
		// Reference data IS wired (checked at the top), so an item those
		// tables do not know cannot be shown to belong in a typed slot --
		// refuse it. This used to return "" ("nothing known" is not a
		// refusal), which is how an HP potion came to be equipped: on a
		// server whose refdata lacked the ETC consumables the lookup missed
		// and the equip sailed through. See equipment.Refusal.
		return refusalMessage(equipment.ErrNotEquippable)
	}
	c, err := chars.GetByID(ctx, characterID)
	if err != nil {
		c = nil
	}
	// Round 877: the masteries count (CheckEquipRequirements, READ
	// s:0x491b25), worded as the original words every unmet requirement
	// (0x186c, MEASURED: "The selected item is unusable because your
	// character's level is too low." for a robe a Warrior/Cleric 100 tries
	// on, and for a level-81 garment at level 69).
	if err := equipment.Refusal(c, item, slot, gearMastery(ctx, gearSkills(), c)); err != nil {
		return equipRefusalText(err, c)
	}
	// Round 877: then AttachEquipItem's armour-and-cloth test (0x1832).
	if store != nil {
		if worn, err := store.Get(ctx, characterID); err == nil {
			bySlot := make(map[equipment.Slot]*refdata.Item, len(worn))
			for _, w := range worn {
				if it, err := items.GetItem(ctx, w.ItemID); err == nil && it != nil {
					bySlot[w.Slot] = it
				}
			}
			if err := equipment.ArmourMixRefusal(item, slot, bySlot); err != nil {
				return equipRefusalText(err, c)
			}
		}
	}
	return ""
}

// The client's words for the refusals round 877 enforces (READ, the error
// switch c:0x7b8b40: 0x186c, and 0x1832 by the player's Country; each raises
// the warning banner and the system line, c:0x7b8ccc). A reply whose error
// starts with UIIT_ is shown as the archive's text (World3D).
const (
	keyRequirementNotMet = "UIIT_MSG_STRGERR_HIGHER_LEVEL_REQUIRED_TO_USE_THISITEM"
	keyArmourMixChina    = "UIIT_MSG_STRGERR_CANT_MIX_EXCLUSIVE_ARMOR_TYPE"
	keyArmourMixEurope   = "UIIT_MSG_STRGERR_EU_CANT_MIX_EXCLUSIVE_ARMOR_TYPE"
)

// equipRefusalText is refusalMessage with the client's own key where round 877
// has one: every unmet level or mastery requirement, and the armour mix by
// the character's Country.
func equipRefusalText(err error, c *character.Character) string {
	switch {
	case errors.Is(err, equipment.ErrLevelTooLow), errors.Is(err, equipment.ErrRequirementNotMet):
		return keyRequirementNotMet
	case errors.Is(err, equipment.ErrArmourMix):
		if characterCountry(c) == equipment.CountryEurope {
			return keyArmourMixEurope
		}
		return keyArmourMixChina
	}
	return refusalMessage(err)
}

// twoHandedDisplaced is the worn slot an equip must clear first: a
// two-handed weapon put in slot 6 while a shield is worn takes the shield
// off, and a shield put in slot 7 under a two-handed weapon takes the
// weapon off (round 829). INFERRED from the original server's
// CGObjPC::AttachEquipItem (0x524cd0, the meanings of its item calls not
// READ): the other hand goes to the first empty bag slot; with no room the
// weapon case answers 0x1807, which ours answers as before ("both hands are
// on your weapon"). Before round 829 ours refused both, so a weapon or
// shield on a quick slot could not swap a two-hander out. Not built (OPEN):
// the original's fallback to the weapon's own source slot, and the bow's
// arrows moved into slot 7 (FindItemHasSameTID).
func twoHandedDisplaced(ctx context.Context, store equipment.Store, inv inventory.Store, items ItemLookup,
	characterID int64, slot equipment.Slot, inventorySlot int) (equipment.Slot, bool) {
	if store == nil || inv == nil || items == nil || (slot != equipment.SlotWeapon && slot != equipment.SlotShield) {
		return 0, false
	}
	slots, err := inv.List(ctx, characterID)
	if err != nil {
		return 0, false
	}
	var incoming *equipment.ItemStats
	for _, sl := range slots {
		if sl.Index == inventorySlot {
			if it, err := items.GetItem(ctx, sl.ItemID); err == nil && it != nil {
				// Round 838: the arrows or bolts slot 7 takes are not a
				// shield; they go on beside the bow that needs them.
				if it.TypeID2 == equipment.TypeExpendable {
					return 0, false
				}
				incoming = &equipment.ItemStats{TwoHanded: it.TwoHanded}
			}
			break
		}
	}
	if incoming == nil {
		return 0, false
	}
	worn, err := store.Get(ctx, characterID)
	if err != nil {
		return 0, false
	}
	byslot := map[equipment.Slot]*equipment.ItemStats{}
	for _, w := range worn {
		it, err := items.GetItem(ctx, w.ItemID)
		if err != nil || it == nil {
			// An unknown worn item cannot be shown to be two-handed, but it
			// still occupies its slot, which is what the shield case needs.
			byslot[w.Slot] = &equipment.ItemStats{}
			continue
		}
		if it.TypeID2 == equipment.TypeExpendable {
			continue // worn ammunition (round 838) holds no hand
		}
		byslot[w.Slot] = &equipment.ItemStats{TwoHanded: it.TwoHanded}
	}
	if !equipment.TwoHandedConflict(byslot, slot, incoming) {
		return 0, false
	}
	if slot == equipment.SlotWeapon {
		return equipment.SlotShield, true
	}
	return equipment.SlotWeapon, true
}

// refusalMessage turns an equipment.Refusal error into the text the client
// shows.
func refusalMessage(err error) string {
	switch {
	case errors.Is(err, equipment.ErrNotEquippable):
		return "that cannot be equipped"
	case errors.Is(err, equipment.ErrWrongSlot):
		return "that does not go in that slot"
	case errors.Is(err, equipment.ErrWrongRace):
		return "that is for another race"
	case errors.Is(err, equipment.ErrWrongGender):
		return "that is for the other gender"
	case errors.Is(err, equipment.ErrLevelTooLow):
		return "your level is too low"
	case errors.Is(err, equipment.ErrTwoHandedShield):
		return "both hands are on your weapon"
	default:
		return "operation failed"
	}
}

func resolveCharacterID(ctx context.Context, sess *gateway.Session, chars character.Store, name string) (int64, string) {
	accountID, ok := AuthenticatedAccountID(sess)
	if !ok {
		return -1, errNotAuthenticated
	}
	list, err := chars.ListByAccount(ctx, accountID)
	if err != nil {
		return -1, "lookup failed"
	}
	for _, c := range list {
		if c.Name == name {
			return c.ID, ""
		}
	}
	return -1, "no such character on this account"
}

func handleEquipmentList(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store, items ItemLookup) error {
	req, err := DecodeCharacterNameRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}

	return sendWornList(ctx, sess, store, items, characterID)
}

// sendWornList answers with everything the character has on. It is the
// reply to a list AND to a successful equip or unequip: those used to answer
// with an empty EquipmentResult{}, which on the wire is identical to "wearing
// nothing", and the client redrew its paper doll bare from it while the body
// stayed dressed. Answering with the real list removes the ambiguity the same
// way OpInventoryMoveResult carries the whole bag.
func sendWornList(ctx context.Context, sess *gateway.Session, store equipment.Store, lookup ItemLookup, characterID int64) error {
	worn, err := store.Get(ctx, characterID)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "list failed"}).Encode()})
	}
	snaps := make([]EquippedSnapshot, len(worn))
	for i, it := range worn {
		snaps[i] = EquippedSnapshot{Slot: int(it.Slot), ItemID: it.ItemID}
	}
	return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Items: snaps, Durabilities: equipmentDurabilities(ctx, worn, lookup),
		Infos: wornItemInfos(ctx, worn, lookup)}).Encode()})
}

func handleEquip(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store, inv inventory.Store, items ItemLookup, trades *trade.Hub, hub *world.Hub) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	req, err := DecodeEquipRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}
	// CGObjPC::AttachEquipItem (0x00524cd0): 0x1811 at INTERACTMODE 2.
	if trades.Established(characterID) {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: tradeEquipLockedReason}).Encode()})
	}
	// Round 800: a pending suit change, and slot 8 already worn (jobsuit.go).
	if storageOpDuringChange(sess, hub, characterID) {
		return nil
	}
	if req.Slot == equipment.SlotJobSuit && slot8Taken(ctx, store, characterID) {
		return suitRefusal(sess, suitErrSwap)
	}

	if refusal := equipRefusal(ctx, chars, store, inv, items, characterID, req.Slot, req.InventorySlot); refusal != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: refusal}).Encode()})
	}
	// Round 829: the other hand comes off first (twoHandedDisplaced).
	if other, ok := twoHandedDisplaced(ctx, store, inv, items, characterID, req.Slot, req.InventorySlot); ok {
		removed := wornIn(ctx, store, characterID, other)
		if err := store.Unequip(ctx, characterID, other); err != nil {
			return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: refusalMessage(equipment.ErrTwoHandedShield)}).Encode()})
		}
		gearSlotChanged(characterID, other) // round 877
		broadcastUnworn(hub, characterID, other, removed)
		gearChanged(ctx, hub, characterID) // round 882: the re-check (gearreqs.go)
	}
	// Round 800: a job suit goes on over 10 seconds (jobsuit.go).
	if req.Slot == equipment.SlotJobSuit {
		d := suitDeps{ctx: ctx, store: store, inv: inv, items: items, hub: hub}
		if handled, err := jobSuitEquip(ctx, sess, d, characterID, req.InventorySlot); handled {
			return err
		}
	}
	if err := store.Equip(ctx, characterID, req.Slot, req.InventorySlot); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
	}
	gearSlotChanged(characterID, req.Slot) // round 877: an attached item passed the test
	character.InvalidateBonus(characterID) // round 769: the worn options changed
	// Round 882: the re-check after a worn item changed (s:0x50f53f ->
	// FUN_0059f0e0, gearreqs.go): the passives are counted again and the
	// character's own buffs whose list fails end, before the move's answer.
	gearChanged(ctx, hub, characterID)
	clampHP(ctx, chars, characterID) // a swap can lower the max (review F2)
	err = sendWornList(ctx, sess, store, items, characterID)
	// The zone sees it put on (0x3038, round 735). A swap is one 0x3038 of
	// the incoming item, as retail's: the client's handler replaces the slot.
	broadcastWorn(ctx, hub, store, items, characterID, req.Slot)
	return err
}

func handleUnequip(ctx context.Context, sess *gateway.Session, p *proto.Packet, chars character.Store, store equipment.Store, items ItemLookup, trades *trade.Hub, hub *world.Hub) error {
	// Round 869: the session's own world (gameworlds.go).
	hub = hub.For(sess)
	req, err := DecodeUnequipRequest(p.Data)
	if err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: "malformed request"}).Encode()})
	}
	characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
	if errStr != "" {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: errStr}).Encode()})
	}
	// CGObjPC::DetachEquipItem (0x005255e0): 0x1811 at INTERACTMODE 2.
	if trades.Established(characterID) {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: tradeEquipLockedReason}).Encode()})
	}
	// Round 800: a pending suit change; a job suit comes off over 10 seconds.
	if storageOpDuringChange(sess, hub, characterID) {
		return nil
	}
	if req.Slot == equipment.SlotJobSuit {
		d := suitDeps{ctx: ctx, store: store, inv: jobDepsNow().inv, items: items, hub: hub}
		if handled, err := jobSuitUnequip(ctx, sess, d, characterID); handled {
			return err
		}
	}

	// The first free bag slot, whatever slot the client named: retail's
	// CGObjPC::DetachEquipItem overwrites the request's destination with
	// CGStorage::FindFirstEmptySlot(13) (0x5258c6, READ). req.InventorySlot
	// is parsed and not used (round 652, the user's choice: the original's
	// rule).
	removed := wornIn(ctx, store, characterID, req.Slot)
	if err := store.Unequip(ctx, characterID, req.Slot); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpEquipmentResult, Data: (&EquipmentResult{Error: equipErrorMessage(err)}).Encode()})
	}
	gearSlotChanged(characterID, req.Slot) // round 877: nothing held there now
	character.InvalidateBonus(characterID) // round 769: the worn options changed
	gearChanged(ctx, hub, characterID)     // round 882: the re-check (gearreqs.go)
	clampHP(ctx, chars, characterID)       // taking it off can lower the max (review F2)
	err = sendWornList(ctx, sess, store, items, characterID)
	// The zone sees it taken off (0x3039, round 735).
	broadcastUnworn(hub, characterID, req.Slot, removed)
	return err
}

func equipErrorMessage(err error) string {
	switch {
	case errors.Is(err, equipment.ErrInvalidSlot):
		return "invalid slot"
	case errors.Is(err, equipment.ErrSlotEmpty):
		return "slot is empty"
	case errors.Is(err, equipment.ErrInventorySlotEmpty):
		return "inventory slot is empty"
	default:
		return "operation failed"
	}
}
