package session

// The action window's emotes (round 781): the Action Emoticon section's
// buttons, on the retail opcode both ways.
//
// READ, SR_GameServer.exe:
//
//   - 0x3091 is request handler index 0x091: FUN_004b0b70 stores the thunk
//     0x4b23d0 (`jmp [eax+0x600]`) at 0xccf598 = 0xccf110 + 0x91*8
//     (0x4b0cfc), and CGObjPC's vtable (0x00af59fc) holds 0x4b1630 at +0x600.
//   - GObjPC::FUN_004b1630 reads one u8 and sends 0x3091 {u32 the
//     character's unique id (+8), u8 that byte} through FUN_00484d90 -- no
//     state test, no range test on the byte: the server echoes it.
//
// READ, sro_client.exe:
//
//   - The sender is the action dispatcher 0x793b00: action 4000 sends
//     0x3091 [00], 4001 [06], 4002 [01], 4003 [05], 4004 [02], 4005 [03],
//     4006 [04] (and 0xfab, an id no actionwnddata row carries, [00]).
//   - The handler FUN_008a7950 reads {u32 id, u8 emote} and puts the object in
//     state 7 with the emote byte (state 0xd under a flag, DAT_00ef1bc0, not
//     read); state 0xd's entry (0xa59bc0) plays animation type 0x32 + the
//     byte, ANI_EMOTION01.. in the body's .bsr. Nothing animates on the
//     press: the client plays its own emote on this broadcast, so the
//     requester is among those it reaches (INFERRED from that, as 0x30bf).
//
// OURS, disclosed:
//
//   - A dead character's request is dropped, as every OpenSRO handler drops
//     a dead character's (the engine's handler tests nothing).
//   - "Everyone" is the players in view that hold the character
//     (sendAboutPlayerPacket, round 737), as broadcastMotion's.
//   - The u32 id is OpenSRO's character id in the retail field.

import (
	"context"
	"encoding/binary"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// OpEmote is the retail emote opcode, the request (u8) and the broadcast
// ({u32 id, u8 emote}) alike.
const OpEmote uint16 = 0x3091

// Emote is the OpEmote broadcast: whose body plays which emote.
type Emote struct {
	ObjectID uint32
	Emote    byte
}

func (e *Emote) Encode() []byte {
	out := make([]byte, 5)
	binary.LittleEndian.PutUint32(out[0:4], e.ObjectID)
	out[4] = e.Emote
	return out
}

// DecodeEmote decodes an OpEmote broadcast; false when it is short.
func DecodeEmote(data []byte) (*Emote, bool) {
	if len(data) < 5 {
		return nil, false
	}
	return &Emote{ObjectID: binary.LittleEndian.Uint32(data[0:4]), Emote: data[4]}, true
}

// EmoteHandler answers OpEmote: GObjPC::FUN_004b1630, the byte echoed to
// the character's watchers and to the character.
func EmoteHandler(hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		// Round 869: the session's own world (gameworlds.go).
		hub := hub.For(sess)
		if p.Opcode != OpEmote {
			return nil
		}
		if len(p.Data) < 1 || hub == nil {
			return nil
		}
		e, ok := hub.EntityBySession(sess.ID())
		if !ok || e.Life != world.LifeAlive {
			return nil
		}
		msg := (&Emote{ObjectID: uint32(e.CharacterID), Emote: p.Data[0]}).Encode()
		sendAboutPlayerPacket(hub, e.CharacterID, true, OpEmote, msg)
		return nil
	}
}
