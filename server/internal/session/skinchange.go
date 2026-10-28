package session

// The character skin change scroll (round 838): ITEM_MALL_CHAR_SKIN_CHANGE_SCROLL
// and its event twins, TypeID 3/3/13/9. "When you use this item, the skin
// change window will open. Select the skin you want and click the confirm
// button."
//
// READ (SR_GameServer):
//
//   - CGItemExpendable::DoJob (0x49aca0) sends TypeID3 13 to UseByKind
//     (0x49c2b0), whose case 9 (0x49c623) reads a u32 RefObjID and a u8 scale
//     from the use's stream and answers GObjPC::UpdateCharRefObjIDAndScale
//     (0x4efe50). On 1 DoJob spends one (LAB_0049af45); on anything else the
//     item is kept.
//   - UpdateCharRefObjIDAndScale, in order: the ref must exist (2); it must be
//     a player character, bionic with TypeID1/TypeID2 1/1 (2); its Country
//     (+0x88) must be the current body's (2: a Chinese cannot take a European
//     body); and only when its sex (+0x199) differs from the current body's,
//     equip slots 0..5 and 8 and all five avatar slots must be empty (0x1892,
//     UIIT_MSG_CHAR_SKIN_ERR_ARMOR). The scale byte is not validated. Then
//     chardata RefObjID and Scale are set and `UPDATE _CHAR SET REFOBJID = %d,
//     SCALE = %d WHERE CHARID = %d` (0xaf5858) runs, and the teleport state
//     starts: FUN_004e0b50(1, 3, 1.0f, 4) -- 0x30BF {id, 0xb, 1} -- whose job
//     (AJStateChanger::vslot_002 case 0xb, option 4) warps the character to
//     its own region and x/y/z a second later (vslot 0x378) and sets the state
//     back to 0. That warp is how every client, its own included, redraws the
//     body: no dedicated broadcast is sent.
//   - The reply is the plain success; the client (Item_OnUseItemResult
//     0x87afef) shows no text for it. UIIT_MSG_CHAR_SKIN_CHANGE_SUCCESS is
//     only the 0x3207 handler's, which the server sends for a skill transform,
//     never for this scroll -- so OpenSRO shows none either.
//
// OURS, disclosed:
//
//   - The use rides OpUseItem (OURS framing) with UseOptionSkinChange, the
//     ref id and the scale, as retail's 0x704C carries {u32 ref, u8 scale}
//     after the slot and type word.
//   - "A player character" is told from the creatable catalogue (the
//     -chargen-csv; SetSkinCatalogue): its 52 bodies are the client's list
//     (usableresobjiddata.txt, MEASURED: the same 52 ids) and every 1/1 row of
//     this archive. A server with no catalogue refuses every use with 2.
//   - The current body's race and sex come from the catalogue too, or from
//     the Gender string for a model it does not hold (a migrated character).
//   - 0x186b (the logout state) is not modelled: OpenSRO has no logout state.
//   - The item is taken before the model is written and handed back when the
//     write fails (useExpansion's order: the store calls can fail).
//   - A cast already working is replaced: FUN_004e0b50 sets the state over it
//     (INFERRED; its job table holds one 0xb job).

import (
	"context"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// UseOptionSkinChange is the skin change's use (OURS, like UseOptionCOSTarget):
// after the option, a u32 RefObjID (UseItemRequest.Target) and a u8 scale
// (UseItemRequest.Scale).
const UseOptionSkinChange byte = 0xFC

// The skin change's refusals (READ, UpdateCharRefObjIDAndScale).
const (
	SkinErrRefused uint16 = 2      // no such body, not a player's, another race
	SkinErrArmor   uint16 = 0x1892 // UIIT_MSG_CHAR_SKIN_ERR_ARMOR
)

// skinOptionInPlace is the teleport state's option the skin change starts
// with: AJStateChanger::vslot_002 case 0xb's option 4, the character's own
// place (READ). Kept here as 0xFC (OURS): the cast's option is internal, and
// 4 is the special reverse return scroll's party member (scroll.go).
const skinOptionInPlace byte = 0xFC

// skinChangeDelay is the state's 1.0 s (FUN_004e0b50's third argument, READ).
const skinChangeDelay = time.Second

// skinChangeKind is 3/3/13/9.
const skinChangeKind = 9

// isSkinChangeScroll reports whether it is a skin change scroll, 3/3/13/9.
func isSkinChangeScroll(it *refdata.Item) bool {
	return it != nil && it.TypeID1 == equipment.TypeItem && it.TypeID2 == equipment.TypeExpendable &&
		it.TypeID3 == 13 && it.TypeID4 == skinChangeKind
}

var skinCatalogue atomic.Pointer[refdata.CreatableSet]

// SetSkinCatalogue installs the bodies a skin change may pick (cmd/server's
// creatable catalogue). nil refuses every skin change.
func SetSkinCatalogue(c *refdata.CreatableSet) { skinCatalogue.Store(c) }

// skinBody is a body's race and sex from the catalogue; ok is false for an id
// that is not one of its models.
func skinBody(id int64) (race, sex int, ok bool) {
	cat := skinCatalogue.Load()
	if cat == nil {
		return 0, 0, false
	}
	m, found := cat.Get(id)
	if !found || m.Kind != refdata.CreatableModel {
		return 0, 0, false
	}
	return m.Country, m.Sex, true
}

// skinGearWorn reports whether characterID wears anything in equip slots 0..5
// or 8, or holds anything in its avatar slots -- what a change of sex needs
// empty (READ: the inventory's slots 0..5 and 8, the avatar storage's 0..4).
func skinGearWorn(ctx context.Context, eq equipment.Store, characterID int64) (bool, error) {
	if eq != nil {
		worn, err := eq.Get(ctx, characterID)
		if err != nil {
			return false, err
		}
		for _, e := range worn {
			if e.ItemID > 0 && (e.Slot <= equipment.SlotBoots || e.Slot == equipment.SlotJobSuit) {
				return true, nil
			}
		}
	}
	if reg := avatarRegistryOf(); reg != nil && reg.store != nil {
		held, err := reg.store.List(ctx, characterID)
		if err != nil {
			return false, err
		}
		for _, h := range held {
			if h.ItemID > 0 && h.Quantity > 0 {
				return true, nil
			}
		}
	}
	return false, nil
}

// skinChange runs one skin change: the refusals in UpdateCharRefObjIDAndScale's
// order, the item spent, the model written and the in-place warp scheduled.
func (s *ScrollCaster) skinChange(ctx context.Context, sess *gateway.Session, inv inventory.Store, characterID int64,
	it *refdata.Item, held inventory.Slot, have int, req *UseItemRequest) error {
	refuse := func(code uint16, reason string) error {
		if s.logger != nil {
			s.logger.Info("skin change refused", "character_id", characterID, "ref", req.Target, "code", code)
		}
		return scrollRefusal(sess, code, reason)
	}
	if req.Option != UseOptionSkinChange {
		return refuse(SkinErrRefused, "choose the new skin in the skin change window")
	}
	race, sex, ok := skinBody(int64(req.Target))
	if !ok {
		return refuse(SkinErrRefused, "that is not a character's body")
	}
	c, err := s.chars.GetByID(ctx, characterID)
	if err != nil || c == nil {
		return refuse(SkinErrRefused, "lookup failed")
	}
	curRace, curSex, known := skinBody(c.RefObjID)
	if !known {
		curRace, curSex = character.RaceOf(c.Gender), character.SexOf(c.Gender)
	}
	if race != curRace {
		return refuse(SkinErrRefused, "that body is another race's")
	}
	if sex != curSex {
		worn, err := skinGearWorn(ctx, s.eq, characterID)
		if err != nil {
			return refuse(SkinErrRefused, "lookup failed")
		}
		if worn {
			return refuse(SkinErrArmor, "take off your armour and empty your avatar slots first")
		}
	}
	models, ok := s.chars.(character.ModelStore)
	if !ok {
		return refuse(SkinErrRefused, "the skin cannot be changed here")
	}
	if s.hub == nil {
		return refuse(SkinErrRefused, "not in the world")
	}
	if _, inWorld := s.hub.EntityByCharacterID(characterID); !inWorld {
		return refuse(SkinErrRefused, "not in the world")
	}
	if err := inv.RemoveItem(ctx, characterID, held.Index, 1); err != nil {
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "using failed"}).Encode()})
	}
	gender := character.GenderFor(race, sex)
	if err := models.SetModel(ctx, characterID, int64(req.Target), int(req.Scale), gender); err != nil {
		if backErr := inv.AddItemInstance(ctx, characterID, held.ItemID, 1, held.Instance()); backErr != nil {
			return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "using failed, and the item could not be returned"}).Encode()})
		}
		return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{Error: "using failed"}).Encode()})
	}
	// The spawn records built from now on carry the new body.
	invalidateLook(characterID)
	if s.logger != nil {
		s.logger.Info("skin changed", "character_id", characterID, "from", c.RefObjID, "to", req.Target,
			"scale", req.Scale, "gender", gender)
	}
	// The state and its job: FUN_004e0b50(1, 3, 1.0f, 4). It takes the place
	// of a cast already working (OURS, the header).
	cast := &scrollCast{sess: sess, option: skinOptionInPlace, value: 1}
	s.mu.Lock()
	s.casting[characterID] = cast
	s.mu.Unlock()
	broadcastScrollState(s.hub, characterID, cast.value)
	s.after(skinChangeDelay, func() { s.complete(characterID, cast) })
	return sess.Send(&proto.Packet{Opcode: OpUseItemResult, Data: (&UseItemResult{
		Remaining: int32(have - 1), ItemID: uint32(it.ID),
	}).Encode()})
}

// inPlaceArrival is option 4's destination: where the character stands now --
// its region and x/y/z (+0x84..+0x90, READ) -- placed as any stored point is.
func (s *ScrollCaster) inPlaceArrival(characterID int64) (zone, bucket string, pos world.Position, frame string, ok bool) {
	e, found := s.hub.EntityByCharacterID(characterID)
	if !found {
		return "", "", world.Position{}, "", false
	}
	p, found := placeOfEntity(e)
	if !found {
		return "", "", world.Position{}, "", false
	}
	return placeArrival(p.Region, p.X, p.Y, p.Z, teleport.MainWorld)
}
