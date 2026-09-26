package session

// The town teleporters' MOVE (round 576): a player at a Dimensional Gate asks
// to go to one of its destinations; the server checks the link, charges its
// fee and moves the player there through the zone change's own arrival
// (warpTo, world.go), so the client reloads the zone behind the loading screen
// exactly as it does for a zone change.
//
// GROUNDED (internal/teleport, round 575; docs/protocol/teleport_network.md):
// the link's fee and its waiver below level 21 (GObjPC::HandleTeleportUse,
// 0x513590), the restriction triples and their refusal codes (FUN_00513a70),
// and the engine's order around them -- CMainProcess::FUN_004f2b50's teleport
// path runs the evaluator (call 0x4f2e24) BEFORE the fee, and
// HandleTeleportUse refuses 0x1c07 on the 64-bit gold compare (0x513749)
// before it sets the teleport state (CGObjPC::FUN_004e0a40), so nothing moves
// a character who cannot pay. A missing link is the engine's own code 2
// (HandleTeleportUse's `uStack_2c = 2` when Gate_LinkForTeleportUse returns
// nothing, 0x513910).
//
// OWN DESIGN, disclosed:
//
//   - The placeholder pair and its layout (docs/protocol/PROTOCOL_DECISION.md).
//     The retail request is 0x705a, written by CIF_NPCTalk::FUN_0081ddf0 --
//     {u32 gate object, u8 kind, kind 2: u32 target} -- and its reply 0xb05a
//     is read by FUN_008809d0 (FUN_0086fbb0 registers it for 0xb05a): a u8
//     result, and on 2 a u16 code the client shows through its category-0xd
//     message table (FUN_00778190(0xd, code, ...)). Recorded, not copied: the
//     placeholder names teleportdata ids, which the client resolves from the
//     clicked building itself, and the server re-validates both.
//   - The arrival spot: the destination's teleportdata point (region + local
//     x/z), the only position a destination row carries. The retail arrival
//     (the completion stage CGObjPC::vslot_309 0x4ef480 /
//     CMainProcess::FUN_004f2b50) is unread. The height is spawnPos's 0: the
//     client stands the player on its walkable graph there
//     (World3D._land_teleport_arrival).
//   - The zone label the arrival is kept under (teleportZoneFor).
//   - No interaction-range test (retail's GObjPC::IsWithinInteractionRange,
//     0x4a8e10, was not read into a distance srrevamp could apply; the client
//     only offers a gate's destinations after a click on the gate) and no
//     "already teleporting" state (0x1c14, IGObj::GetTeleportState: a
//     srrevamp teleport completes inside one request, so there is no state
//     to be in).
//   - A gate point with no building is refused with code 2 as well; the
//     engine answers nothing when its gate lookup (FUN_00485d90) fails -- a
//     bare `return` -- and srrevamp does not leave a client waiting.
//   - The GM and -teleport-free waivers (teleport.QuoteFee), the refusal
//     reasons' wording, and the refusals that carry code 0 (not in the
//     world, dead, no network loaded, a destination srrevamp cannot place).

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"

	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/gm"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/teleport"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// The teleport pair, srrevamp's own placeholders. 0x00F3/0x00F4 were free on
// 2026-09-26: the highest op in server/internal/session and
// client/scripts/net was 0x00F2 (OpGMCommandResult), and no file under
// server/, client/scripts or docs/ named either. The client half pins them
// (client/scripts/net/teleport.gd).
const (
	OpTeleportUse    uint16 = 0x00F3 // client -> server
	OpTeleportResult uint16 = 0x00F4 // server -> the requester
)

// teleportNoLink is the engine's refusal for a link that does not exist:
// GObjPC::HandleTeleportUse sets `uStack_2c = 2` when Gate_LinkForTeleportUse
// returns no link or one with no target (0x513910), and refuses with it.
const teleportNoLink uint16 = 2

// TeleportUseRequest is the OpTeleportUse payload: two u16 LE teleportdata
// ids, the gate the player is at and the destination it chose -- nothing
// else. The server re-validates both against its own tables.
type TeleportUseRequest struct {
	Gate        uint16
	Destination uint16
}

// DecodeTeleportUseRequest reads exactly the four bytes the client sends
// (TeleportNet.encode_use).
func DecodeTeleportUseRequest(data []byte) (*TeleportUseRequest, error) {
	if len(data) != 4 {
		return nil, fmt.Errorf("session: decoding TeleportUseRequest: %d bytes, want 4", len(data))
	}
	return &TeleportUseRequest{
		Gate:        binary.LittleEndian.Uint16(data[0:2]),
		Destination: binary.LittleEndian.Uint16(data[2:4]),
	}, nil
}

// TeleportResult is the OpTeleportResult payload, always the full layout:
//
//	u8 OK, u16 Code, u8 Waiver, u64 Fee, string Destination, string Reason
//
// (strings u16-length-prefixed UTF-8, as everywhere in this protocol). On
// success Code is 0, Fee is the gold charged, Waiver says why it is 0 when
// the link has a fee (teleport.Waiver: 0 none, 1 level, 2 GM, 3 the testing
// flag), and Destination is the destination point's zone-name token
// (SN_ZONE_22002 for Donwhang's gate), which the client resolves through its
// own textdata_object; the OpChangeZoneResult that moves the player follows
// it. On a refusal OK is 0, Code is the engine's refusal code (2, 0x1c07,
// 0x1c10, 0x1c15, 0x1c19, 0x1c23, 0x1c24) or 0 for a refusal of srrevamp's
// own, Reason is the server's own wording (the client's fallback), and
// nothing moved or was charged.
type TeleportResult struct {
	OK          bool
	Code        uint16
	Waiver      teleport.Waiver
	Fee         int64
	Destination string
	Reason      string
}

func (r *TeleportResult) Encode() []byte {
	out := make([]byte, 12, 16+len(r.Destination)+len(r.Reason))
	if r.OK {
		out[0] = 1
	}
	binary.LittleEndian.PutUint16(out[1:3], r.Code)
	out[3] = byte(r.Waiver)
	binary.LittleEndian.PutUint64(out[4:12], uint64(r.Fee))
	return append(out, encodeStrings(r.Destination, r.Reason)...)
}

func DecodeTeleportResult(data []byte) (*TeleportResult, error) {
	if len(data) < 12 {
		return nil, fmt.Errorf("session: decoding TeleportResult: %d bytes, want at least 12", len(data))
	}
	fields, err := decodeStrings(data[12:], 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding TeleportResult: %w", err)
	}
	return &TeleportResult{
		OK:          data[0] != 0,
		Code:        binary.LittleEndian.Uint16(data[1:3]),
		Waiver:      teleport.Waiver(data[3]),
		Fee:         int64(binary.LittleEndian.Uint64(data[4:12])),
		Destination: fields[0],
		Reason:      fields[1],
	}, nil
}

// TeleportHandler answers OpTeleportUse. network is cmd/server's -teleport-dir
// (nil without it: every request is refused); gate is the GM account list, the
// same gm.Gate the GM console uses (nil: nobody is a GM); free is
// -teleport-free. logger may be nil.
func TeleportHandler(chars character.Store, eq equipment.Store, hub *world.Hub, network *teleport.Table, gate *gm.Gate, free bool, logger *slog.Logger) gateway.Handler {
	t := &teleporter{chars: chars, eq: eq, hub: hub, network: network, gate: gate, free: free, logger: logger}
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpTeleportUse {
			return nil
		}
		return t.use(ctx, sess, p)
	}
}

// teleporter is TeleportHandler's state: the stores and the switches.
type teleporter struct {
	chars   character.Store
	eq      equipment.Store
	hub     *world.Hub
	network *teleport.Table
	gate    *gm.Gate
	free    bool
	logger  *slog.Logger
}

// use runs one OpTeleportUse, in the engine's order where it has one: the
// character, the gate, the link, the link's restrictions (FUN_00513a70, before
// the fee on CMainProcess::FUN_004f2b50's path), the fee and its waiver
// (teleport.QuoteFee), the charge -- refused 0x1c07 with nothing moved, as
// HandleTeleportUse refuses before it sets the teleport state -- then the
// receipt and the move.
func (t *teleporter) use(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
	username, _ := AuthenticatedUsername(sess)
	refuse := func(code uint16, reason string, attrs ...any) error {
		if t.logger != nil {
			t.logger.Info("teleport refused", append([]any{"account", username, "code", fmt.Sprintf("0x%x", code), "reason", reason}, attrs...)...)
		}
		return sess.Send(&proto.Packet{Opcode: OpTeleportResult, Data: (&TeleportResult{Code: code, Reason: reason}).Encode()})
	}

	req, err := DecodeTeleportUseRequest(p.Data)
	if err != nil {
		return refuse(0, "malformed request")
	}
	if t.network == nil {
		return refuse(0, "teleporting is not available on this server")
	}
	current, ok := t.hub.EntityBySession(sess.ID())
	if !ok {
		return refuse(0, "not in the world")
	}
	// A dead character does not teleport: handleChangeZone's rule (round 549,
	// own design -- no retail life-state test on this path was read).
	if current.Life == world.LifeDead {
		return refuse(0, deadRefusal)
	}
	gatePoint, ok := t.network.PointByID(int(req.Gate))
	if !ok {
		return refuse(teleportNoLink, "no such gate", "gate", req.Gate)
	}
	building, ok := gateBuilding(t.network, gatePoint)
	if !ok {
		return refuse(teleportNoLink, "no such gate", "gate", gatePoint.Code)
	}
	link, ok := t.network.LinkBetween(gatePoint.ID, int(req.Destination))
	if !ok {
		return refuse(teleportNoLink, "no such destination", "gate", building.Code, "dest", req.Destination)
	}
	// teleport.Read refuses a link whose end is not a point, so this holds.
	dest, _ := t.network.PointByID(link.To)
	zone, bucket, pos, frame, ok := teleportArrival(dest)
	if !ok {
		return refuse(0, "that destination is not a place srrevamp can put a player yet", "gate", building.Code, "dest", dest.Code)
	}
	c, err := t.chars.GetByID(ctx, current.CharacterID)
	if err != nil || c == nil {
		return refuse(0, "lookup failed")
	}
	// The PvP state is a DISCLOSED STAND-IN: srrevamp models none (no PK
	// system; internal/duel's own-design duel sets none), so every character
	// is PvPSTATE_NEUTRAL here. It decides only rule type 3, which no retail
	// link carries (0 of 1,460 slots, round 575) -- no current outcome turns
	// on it.
	if code := teleport.CheckRestrictions(link, c.Level, teleport.PvPNeutral); code != 0 {
		return refuse(code, teleportRefusalReason(code), "gate", building.Code, "dest", dest.Code, "level", c.Level)
	}
	isGM := t.gate.Allows(username)
	fee, waiver := teleport.QuoteFee(link, c.Level, isGM, t.free)
	if fee > 0 {
		if err := t.chars.DeductGold(ctx, c.ID, fee); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return refuse(teleport.ErrNotEnoughMoney, teleportRefusalReason(teleport.ErrNotEnoughMoney),
					"gate", building.Code, "dest", dest.Code, "fee", fee)
			}
			return refuse(0, "charging the fee failed")
		}
	}
	if t.logger != nil {
		t.logger.Info("teleport", "account", username, "character", c.Name,
			"gate", building.Code, "from", gatePoint.Code, "dest", dest.Code, "zone", zone, "frame", frame,
			"x", pos.X, "z", pos.Z, "fee", fee, "waiver", waiver, "gm", isGM, "free_flag", t.free)
	}
	// The receipt goes first: the client marks the OpChangeZoneResult that
	// follows as this teleport's arrival (World3D._on_teleport_result).
	if err := sess.Send(&proto.Packet{Opcode: OpTeleportResult, Data: (&TeleportResult{
		OK: true, Waiver: waiver, Fee: fee, Destination: dest.ZoneName,
	}).Encode()}); err != nil {
		return err
	}
	moved, err := warpTo(ctx, sess, t.eq, t.chars, t.hub, zone, bucket, pos, frame)
	if !moved && fee > 0 {
		// The session left the world between the check above and the move;
		// nothing moved, so nothing is owed.
		if rerr := t.chars.AddGold(ctx, c.ID, fee); rerr != nil && t.logger != nil {
			t.logger.Error("teleport: refunding a fee after a failed move", "character", c.Name, "fee", fee, "err", rerr)
		}
	}
	return err
}

// gateBuilding is the Dimensional Gate structure a teleport point belongs to:
// the teleportbuilding row whose id is the point's associated object and whose
// own point, looked up by its code, is this point (GATE_CH -> 2094
// STORE_CH_GATE -> GATE_CH). ok is false for a point whose object is not a
// building -- a ferry, whose object is an NPC (GATE_NPC_CH_FERRY -> 2011
// NPC_CH_FERRY), or one with none -- which is not a gate a player clicks.
func gateBuilding(network *teleport.Table, p teleport.Point) (teleport.Building, bool) {
	for _, b := range network.Buildings {
		if b.ID != p.ObjectID {
			continue
		}
		if owner, ok := network.PointByBuildingCode(b.Code); ok && owner.ID == p.ID {
			return b, true
		}
	}
	return teleport.Building{}, false
}

// teleportArrival is where a teleport to point p lands: the zone label
// (teleportZoneFor), the hub bucket and FrameRegion arrival gives that label
// -- its own centre, or worldmap.WorldOrigin under -single-frame -- and the
// point named in that frame by worldmap.ToWorld (region y drives world X,
// region x drives world Z, Z mirrored: AGENTS.md, worldmap's measured
// columns), at spawnPos's height. ok is false for a dungeon point (a negative
// region id: worldmap has no frame for one).
func teleportArrival(p teleport.Point) (zone, bucket string, pos world.Position, frame string, ok bool) {
	if p.Region < 0 {
		return "", "", world.Position{}, "", false
	}
	rx, ry := worldmap.RegionXY(p.Region)
	zone = teleportZoneFor(rx, ry)
	bucket, _, frame, _ = arrival(zone)
	fx, fy, ok := worldmap.ParseRegionLabel(frame)
	if !ok {
		return "", "", world.Position{}, "", false
	}
	x, z := worldmap.ToWorld(rx, ry, float64(p.X), float64(p.Z), fx, fy)
	return zone, bucket, world.Position{X: x, Y: spawnPos.Y, Z: z}, frame, true
}

// teleportZoneFor is the zone label a teleport into region (rx, ry) arrives
// under. OWN DESIGN, disclosed:
//
//   - a town whose centre (worldmap.ZoneCentre) is that region -- Jangan,
//     Donwhang, Hotan and Constantinople, whose gates stand in their centre
//     regions since round 569 -- so the arrival shares the town's bucket and
//     grid with a /goto and a zone change;
//   - else a town whose centre is one region away: Samarkand, whose gate
//     GATE_CA stands in 106/108 beside its 106/107 centre. The client builds
//     radius 2 around the centre (World3D.REGION_LOAD_RADIUS), so the gate's
//     region is in the grid, a neighbour cell;
//   - else the region's own "x/y" label, its own frame and bucket.
//
// ZoneNames is sorted, so of the two labels for Donwhang's 102/153 the
// server's own "donwhang" (its roster's, /goto's) comes before "dunhuang".
func teleportZoneFor(rx, ry int) string {
	names := worldmap.ZoneNames()
	for _, name := range names {
		if c := worldmap.ZoneCentre[name]; c[0] == rx && c[1] == ry {
			return name
		}
	}
	for _, name := range names {
		c := worldmap.ZoneCentre[name]
		if dx, dy := c[0]-rx, c[1]-ry; dx >= -1 && dx <= 1 && dy >= -1 && dy <= 1 {
			return name
		}
	}
	return fmt.Sprintf("%d/%d", rx, ry)
}

// teleportRefusalReason is the server's own wording for an engine refusal code
// -- the client's fallback when its archive has no message for the code
// (client/scripts/net/error_text.gd's teleport_line).
func teleportRefusalReason(code uint16) string {
	switch code {
	case teleport.ErrNotEnoughMoney:
		return "not enough gold"
	case teleport.ErrLevelRange:
		return "your level is outside the range this destination allows"
	case teleport.ErrTradeCart:
		return "you cannot teleport with a trade cart"
	case teleport.ErrPvPState:
		return "your PvP state bars this destination"
	case teleport.ErrRocItem, teleport.ErrRocJob:
		return "you cannot enter there"
	}
	return fmt.Sprintf("teleport refused (code 0x%x)", code)
}
