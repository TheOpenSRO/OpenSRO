package session

import (
	"context"
	"encoding/binary"
	"errors"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Retail's item-use broadcast (round 859): every item a player uses
// successfully is told to the players around it, the user included, so each
// client draws the item's use effect on the user (docs/protocol/item_use_effects.md).
//
// READ, SR_GameServer.exe: Item_HandleUseItem (s:0x510980), after the
// success reply 0xB04C {u8 1, u8 slot, u16 count, u16 type word} on the
// accepted use, builds 0x305C (s:0x5110a0 FUN_00430a00(0x305c)) with
//
//	u32 the user's unique id (the PC's +8, read at the top of the handler)
//	u32 the used item's RefItemID (its vslot 1, read before the use)
//
// and sends it through GObjPC::FUN_00484d90, the region-scoped send that
// reaches every PC in the user's 3 x 3 blocks, the user included (round 749).
// Nothing gates it by item kind: any use that answers 1 sends it. A pet's
// potion used from the player's bag goes through the same handler, so its
// 0x305C names the PLAYER, not the pet. GObjPC::COS__UseItem (s:0x4d57b0) sends
// one with the COS's own id after a COS's own 0xB0C5 use, which OpenSRO does
// not have.
//
// READ, sro_client.exe: 0x305C's handler NetProcessInInner::FUN_008735d0
// reads the two u32s, finds the object by id and starts the item's decoration
// on it -- the effect table is the client's, by the item's type (the client's
// ItemUseEffect has the whole reading).
//
// OpenSRO: the uid is the low 32 bits of the character id, as every retail
// message OpenSRO sends names a player (round 710); the receivers are the
// equipment broadcasts' (equipObservers: the 3 x 3 view, the user included),
// and another player is sent it only while its client holds the user's body
// (sendAboutOwner).
const OpItemUseEffect uint16 = 0x305C

// ItemUseEffect is a 0x305C payload.
type ItemUseEffect struct {
	UID       uint32
	RefItemID uint32
}

// Encode writes retail's layout: u32 uid, u32 RefItemID.
func (m *ItemUseEffect) Encode() []byte {
	out := make([]byte, 8)
	binary.LittleEndian.PutUint32(out[0:], m.UID)
	binary.LittleEndian.PutUint32(out[4:], m.RefItemID)
	return out
}

// DecodeItemUseEffect reads a 0x305C payload.
func DecodeItemUseEffect(data []byte) (*ItemUseEffect, error) {
	if len(data) < 8 {
		return nil, errors.New("session: decoding item use effect: truncated")
	}
	return &ItemUseEffect{UID: binary.LittleEndian.Uint32(data), RefItemID: binary.LittleEndian.Uint32(data[4:])}, nil
}

// broadcastItemUse sends the 0x305C of characterID's use of refItemID to
// everyone in view of it, the user included.
func broadcastItemUse(hub *world.Hub, characterID, refItemID int64) {
	to := equipObservers(hub, characterID)
	if len(to) == 0 || refItemID <= 0 {
		return
	}
	msg := &ItemUseEffect{UID: uint32(characterID), RefItemID: uint32(refItemID)}
	sendAboutOwner(to, characterID, OpItemUseEffect, msg.Encode())
}

// useNote is what one OpUseItem's handling learnt: the user and the item at
// the slot it named, once both are known.
type useNote struct {
	characterID int64
	refItemID   int64
}

// announceUses wraps the use-item handler (round 859): it watches the
// handler's own replies to this session (gateway.Session.Tap) and, when the
// use was accepted -- an OpUseItemResult with no error, retail's 0xB04C of 1
// -- sends the 0x305C after it, as Item_HandleUseItem sends it after its
// reply. Every kind's path answers through OpUseItemResult, so none is left
// out.
func announceUses(hub *world.Hub, handle func(context.Context, *gateway.Session, *proto.Packet, *useNote) error) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		note := &useNote{}
		if p.Opcode != OpUseItem || hub == nil {
			return handle(ctx, sess, p, note)
		}
		accepted := false
		untap := sess.Tap(func(op uint16, payload []byte) {
			if op != OpUseItemResult || accepted {
				return
			}
			if r, err := DecodeUseItemResult(payload); err == nil && r.Error == "" {
				accepted = true
			}
		})
		err := handle(ctx, sess, p, note)
		untap()
		if accepted && note.characterID != 0 && note.refItemID > 0 {
			broadcastItemUse(hub, note.characterID, note.refItemID)
		}
		return err
	}
}
