package session

// The town gates' "Designate as return/recall point" (round 686), and the
// return point it sets: where option 1 of the dead window (deadstate.go), the
// flag-off respawn and a dead character's logout send a character.
//
// READ (docs/protocol/teleport_network.md, "The return point (round 686)"):
//
//   - The client. The gate's talk line (item 9, UIIT_CTL_RECALL_POSITION,
//     CIF_NPCTalk::FUN_007020c0 case 9 at 0x702777) opens message box kind 5
//     (0x7027b5 push 0x5; 0x6ec5d0) with the talked-to object's id. Kind 5
//     (UI_SILKMALL::FUN_00644c90, jump-table entry 0x644f93) is titled
//     UIIT_STT_AGREEMENT_BOX and reads UIIT_MSG_MSGBOX_SETREBIRTH_CURPOS ("The
//     current position : [%s]", the player's current region's textzonename
//     entry) over UIIT_MSG_MSGBOX_SETREBIRTH_ASKCERTIFY ("Will you designate
//     the place to be returned /resurrected?"). Its OK (FUN_00797d90 case 5,
//     param_3 == 1) sends 0x7059 with the u32 object id (0x797fc5..0x798014).
//   - The server. Dispatch 0x059, GObjPC_HandleDesignateRecallMsg_059
//     (0x513410): the object id; then GObjPC::IsWithinInteractionRange (0x4a8e10) with the type mask 0x30
//     (`mov WORD PTR [esp+0x20],0x30` at 0x513450: TypeID1 4, TypeID2 1, a
//     structure) -- anything but 1 is answered with that code; then the
//     object's ref object must hold interaction id 7 (`mov BYTE PTR
//     [esp+0x17],0x7` at 0x513491, the set at refobj +0x90, which
//     RefTeleport_ExtractData fills from teleportdata column 10 -- Point.
//     Interaction7) and the object must answer IGObj::IsTeleportGate (vslot
//     37, `call [eax+0x94]` at 0x5134a5), else code 3 (0x51354d). Then, when
//     the object's GetRefObjID (vslot 1) differs from charData +0xa4
//     (`_CHAR.AppointedTeleport`), CharData_SetAppointedTeleport writes it and marks the row
//     dirty (+0x8 |= 0x80). The reply is 0xb059 {u8 1} (0x5134fc..0x513528);
//     a refusal is Msg_SendTwoFieldReply's {u8 2, u16 code} (0x4e7250). No
//     fee, no level, no life-state test in the handler.
//   - The answer on the client (Client_OnDesignateRecallResult, registered for 0xb059): on 1,
//     UIIT_MSG_STATE_REBIRTH_POINT_APPOINT ("Resurrection spawn point has
//     changed.") to the system window as type 5 (`FUN_007781b0(5, ...)`) and
//     to GDR_WARNING_WND (FUN_0077b580); on 2 it reads the code and shows
//     nothing.
//   - The return point. CGObjPC::ResolveRevivePoint (0x4e08a0) looks
//     AppointedTeleport up as a ref object and takes its teleport record's
//     region, x/y/z and world (FUN_004e0a40 -> FUN_00407760) -- the arrival a
//     gate teleport to that gate makes (0x513779). An unknown id logs
//     "someone designated unknown teleport gate: %d" and falls back to
//     LatestRegion/Pos/WorldID.
//   - The default. SR_ShardManager's FUN_0042bb20 (the server package's
//     SR_ShardManager.exe) reads the new body's Country byte (`movzx edi,BYTE
//     PTR [eax+0x88]` at 0x42bb78), looks up "STORE_CH_GATE" (0x783d04) for 0
//     and "STORE_EU_GATE" (0x783d14) for 1 (0x42bb81..0x42bb97), asserts the
//     object has a teleport record (+0x190, 0x42bbd8) and returns its id
//     (+0x8, 0x42bbe5), which goes to `_AddNewChar` with the start spawn
//     (docs/protocol/charselect.md: its 9th parameter, INFERRED to be
//     AppointedTeleport by position). So a China character's return point is
//     Jangan's gate and a Europe character's Constantinople's until one
//     designates another.
//
// OURS, disclosed:
//
//   - The placeholder pair (OpRecallDesignate / OpRecallDesignateResult) and
//     its request, the gate's teleportdata id as TeleportUseRequest names it;
//     the reply is retail's 0xb059 shape exactly.
//   - The store's 0 for "none designated" (character.RecallStore): resolved to
//     the race's gate by code when it is needed.
//   - An unknown or unusable designated gate (a table re-exported without it,
//     a point OpenSRO cannot place) falls back to the race's gate, not to
//     retail's LatestRegion/Pos (which would put a dead character back where
//     it fell); without a teleport network (-teleport-dir) a China character
//     returns to spawnZone's arrival, the pre-686 point, and a Europe one to
//     Constantinople's zone arrival.
//   - The range test is session.reach's (IsWithinInteractionRange read in
//     round 642, its height left out). A requester not in the world, or a
//     server with no network, is answered code 0.

import (
	"context"
	"encoding/binary"
	"fmt"
	"log/slog"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/teleport"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The designate pair, OpenSRO's own placeholders (PROTOCOL_DECISION.md).
// 0x0111/0x0112 were free on 2026-10-02: the highest ops in server/internal
// and client/scripts/net were OpUniqueNotice 0x0110 and the composite ops
// 0x0104..0x0108, and neither feat/lobby682 nor feat/appear683 uses them. The
// client half pins them (client/scripts/net/recall.gd). Retail's are
// 0x7059 / 0xb059.
const (
	OpRecallDesignate       uint16 = 0x0111 // client -> server: u16 gate teleportdata id
	OpRecallDesignateResult uint16 = 0x0112 // server -> the requester: u8 1, or u8 2 + u16 code
)

// RecallDesignateOK and RecallDesignateRefused are the reply's first byte,
// retail's result envelope (GObjPC_HandleDesignateRecallMsg_059: 1 at
// 0x513513; Msg_SendTwoFieldReply writes 2 at 0x4e726d).
const (
	RecallDesignateOK      byte = 1
	RecallDesignateRefused byte = 2
)

// RecallErrNoTarget is the refusal for a gate that is not there: retail's
// IsWithinInteractionRange answers 0 when the object lookup (FUN_00485d90)
// fails, and the handler sends that 0 as the code (0x513562..0x513576).
const RecallErrNoTarget uint16 = 0

// RecallDesignateRequest is the OpRecallDesignate payload: the teleportdata id
// of the gate the player is talking to.
type RecallDesignateRequest struct {
	Gate uint16
}

// DecodeRecallDesignateRequest reads exactly the two bytes the client sends
// (RecallNet.encode_designate).
func DecodeRecallDesignateRequest(data []byte) (*RecallDesignateRequest, error) {
	if len(data) != 2 {
		return nil, fmt.Errorf("session: decoding RecallDesignateRequest: %d bytes, want 2", len(data))
	}
	return &RecallDesignateRequest{Gate: binary.LittleEndian.Uint16(data)}, nil
}

// RecallDesignateResult is the OpRecallDesignateResult payload, 0xb059's
// shape: u8 1 on success; u8 2 then a u16 LE code on a refusal.
type RecallDesignateResult struct {
	OK   bool
	Code uint16
}

func (r *RecallDesignateResult) Encode() []byte {
	if r.OK {
		return []byte{RecallDesignateOK}
	}
	out := []byte{RecallDesignateRefused, 0, 0}
	binary.LittleEndian.PutUint16(out[1:], r.Code)
	return out
}

func DecodeRecallDesignateResult(data []byte) (*RecallDesignateResult, error) {
	switch {
	case len(data) == 1 && data[0] == RecallDesignateOK:
		return &RecallDesignateResult{OK: true}, nil
	case len(data) == 3 && data[0] == RecallDesignateRefused:
		return &RecallDesignateResult{Code: binary.LittleEndian.Uint16(data[1:])}, nil
	}
	return nil, fmt.Errorf("session: decoding RecallDesignateResult: % x", data)
}

// designate answers one OpRecallDesignate, in
// GObjPC_HandleDesignateRecallMsg_059's order: the gate, the interaction range
// with the structure mask, the gate's interaction 7, then the write -- only
// when it changes the value -- and {1}.
func (t *teleporter) designate(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
	username, _ := AuthenticatedUsername(sess)
	refuse := func(code uint16, reason string, attrs ...any) error {
		if t.logger != nil {
			// Debug, not Info (round 686's review): a client repeating the
			// request must not flood the log.
			t.logger.Debug("recall designate refused", append([]any{"account", username, "code", code, "reason", reason}, attrs...)...)
		}
		return sess.Send(&proto.Packet{Opcode: OpRecallDesignateResult, Data: (&RecallDesignateResult{Code: code}).Encode()})
	}
	req, err := DecodeRecallDesignateRequest(p.Data)
	if err != nil {
		return refuse(RecallErrNoTarget, "malformed request")
	}
	if t.network == nil {
		return refuse(RecallErrNoTarget, "no teleport network on this server")
	}
	current, ok := t.hub.EntityBySession(sess.ID())
	if !ok {
		return refuse(RecallErrNoTarget, "not in the world")
	}
	gatePoint, ok := t.network.PointByID(int(req.Gate))
	if !ok {
		return refuse(RecallErrNoTarget, "no such gate", "gate", req.Gate)
	}
	gateCode, ok := gateObject(t.network, gatePoint)
	if !ok {
		return refuse(RecallErrNoTarget, "no such gate", "gate", gatePoint.Code)
	}
	// The type mask 0x30 is a structure's (TypeID1 4, TypeID2 1): an NPC
	// standing for a point -- a ferry seller -- fails FUN_004a8d90 and
	// IsWithinInteractionRange answers 3 before it measures.
	if _, isBuilding := t.network.BuildingByID(gatePoint.ObjectID); !isBuilding {
		return refuse(teleport.ErrInteractionTarget, "not a gate structure", "gate", gateCode)
	}
	if code, measured := t.reach(current, gatePoint); code != 1 {
		return refuse(uint16(code), teleportRefusalReason(uint16(code)), "gate", gateCode, "measured", measured)
	}
	// Interaction id 7 on the gate's ref object (teleportdata column 10), and
	// a point OpenSRO can return a character to. A gate in an instance
	// (the two Roc gates' worlds) could not be returned to here; retail would
	// accept it (OURS, the latter test).
	if !gatePoint.Interaction7 {
		return refuse(teleport.ErrInteractionTarget, "this gate offers no return point", "gate", gateCode)
	}
	if _, _, _, _, ok := recallArrival(gatePoint); !ok {
		return refuse(teleport.ErrInteractionTarget, "OpenSRO cannot return a character to that gate yet", "gate", gateCode)
	}
	rs, ok := t.chars.(character.RecallStore)
	if !ok {
		return refuse(RecallErrNoTarget, "this server keeps no return points")
	}
	was, err := rs.AppointedTeleport(ctx, current.CharacterID)
	if err != nil {
		return refuse(RecallErrNoTarget, "lookup failed")
	}
	if was != int64(gatePoint.ObjectID) {
		if err := rs.SetAppointedTeleport(ctx, current.CharacterID, int64(gatePoint.ObjectID)); err != nil {
			return refuse(RecallErrNoTarget, "saving the return point failed")
		}
	}
	if t.logger != nil {
		t.logger.Info("recall designated", "account", username, "character_id", current.CharacterID,
			"gate", gateCode, "point", gatePoint.Code, "object", gatePoint.ObjectID, "was", was)
	}
	return sess.Send(&proto.Packet{Opcode: OpRecallDesignateResult, Data: (&RecallDesignateResult{OK: true}).Encode()})
}

// recallNetwork is the teleport network the return point is resolved
// against: cmd/server's -teleport-dir (SetRecallNetwork), nil without one.
var recallNetwork atomic.Pointer[teleport.Table]

// SetRecallNetwork gives the return point the teleport network. cmd/server
// calls it once at boot, before the gateway serves; nil keeps the fallbacks.
func SetRecallNetwork(t *teleport.Table) { recallNetwork.Store(t) }

// The race gates, READ: SR_ShardManager FUN_0042bb20's two codes (0x783d04,
// 0x783d14), chosen by the body's Country byte -- 1 Europe, anything else
// China (`sub eax,0x1; jne` at 0x42bb8b).
const (
	RaceGateChina  = "STORE_CH_GATE"
	RaceGateEurope = "STORE_EU_GATE"
)

// RaceGate is the gate a character of Country `country` returns to until it
// designates one.
func RaceGate(country int) string {
	if country == equipment.CountryEurope {
		return RaceGateEurope
	}
	return RaceGateChina
}

// recallFallbackZone is where a character of `country` returns when no
// teleport network is loaded (OURS): spawnZone, where every character entered
// before round 682 and every return point was before round 686, and
// Constantinople's zone for Europe.
func recallFallbackZone(country int) string {
	if country == equipment.CountryEurope {
		return "constantinople"
	}
	return spawnZone
}

// recallArrival is where a return to gate point p lands: the arrival a gate
// teleport to it makes (teleportArrival -- ResolveRevivePoint reads the same
// record fields as HandleTeleportUse), when it is a point OpenSRO can put a
// player at (the open world, an overworld region).
func recallArrival(p teleport.Point) (zone, bucket string, pos world.Position, frame string, ok bool) {
	if !inOpenWorld(p) {
		return "", "", world.Position{}, "", false
	}
	return teleportArrival(p)
}

// returnPointFor is where characterID's return takes it: its designated gate
// (character.RecallStore), else its race's gate (characterCountry, the body's
// race since round 682), as zone label, hub bucket, position and frame -- each
// an arrival warpTo makes. chars may be any Store; one that is not a
// RecallStore has nothing designated. The fallbacks are in the file's header.
//
// A failed read is logged with the character's id, never passed over (round
// 686's review): a character that cannot be read has no known race, so it
// returns to its designated gate if that still reads, else to spawnZone's
// arrival -- the point a return used before round 686 and the one used with no
// network -- with an error naming it, so a Europe character sent to Jangan
// that way shows in the log. A designated gate that cannot be read falls to
// the race's gate, also logged.
func returnPointFor(ctx context.Context, chars character.Store, characterID int64) (zone, bucket string, pos world.Position, frame string) {
	var c *character.Character
	readable := false
	if chars != nil {
		var err error
		c, err = chars.GetByID(ctx, characterID)
		if err != nil || c == nil {
			slog.Error("return point: reading the character failed; its race is unknown",
				"character_id", characterID, "err", err)
		} else {
			readable = true
		}
	}
	country := characterCountry(c)
	network := recallNetwork.Load()
	if network != nil {
		if rs, ok := chars.(character.RecallStore); ok {
			id, err := rs.AppointedTeleport(ctx, characterID)
			switch {
			case err != nil:
				slog.Error("return point: reading the designated gate failed",
					"character_id", characterID, "err", err)
			case id != 0:
				p, ok := network.PointByObject(int(id))
				if ok {
					if zone, bucket, pos, frame, ok := recallArrival(p); ok {
						return zone, bucket, pos, frame
					}
				}
				slog.Warn("return point: the designated gate is not a point OpenSRO can return to; using the race's gate",
					"character_id", characterID, "gate_object", id, "known", ok)
			}
		}
		if readable {
			if p, ok := network.PointByBuildingCode(RaceGate(country)); ok {
				if zone, bucket, pos, frame, ok := recallArrival(p); ok {
					return zone, bucket, pos, frame
				}
			}
		}
	}
	if !readable && chars != nil {
		slog.Error("return point: the character could not be read; returning it to the zone arrival",
			"character_id", characterID, "zone", spawnZone)
		zone = spawnZone
	} else {
		zone = recallFallbackZone(country)
	}
	bucket, pos, frame, _ = arrival(zone)
	return zone, bucket, pos, frame
}
