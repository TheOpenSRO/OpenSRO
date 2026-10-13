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
//   - The arrival height. The arrival POINT is READ (round 642): the
//     destination's teleportdata point, exactly -- HandleTeleportUse passes
//     the link's target to 0x407760 (through 0x4e0a40, call at 0x513779),
//     which copies the record's region word (+0x20) and its x/y/z words
//     (+0x26/+0x28/+0x2a) as floats, with no scatter over the radius (the
//     battle arena's FUN_00662380 is the one place that scatters, by
//     rand() over +/- radius). OpenSRO lands on (region, x, z); the height
//     is spawnPos's 0, and the client stands the player on its walkable graph
//     there (World3D._land_teleport_arrival) -- measured in round 642 to be
//     within a unit of the table's y at 33 of the 42 open-world points
//     probed, and dry ground at all of them.
//   - The zone label the arrival is kept under (teleportZoneFor).
//   - The interaction range is READ since round 642's review (reach,
//     teleport.Reach: GObjPC::IsWithinInteractionRange, 0x4a8e10; NPC 300,
//     structure 800, the requester's region or a neighbour). OURS within it:
//     the height term is dropped, and an NPC the server has no npcpos row for
//     is not measured. An OpenSRO teleport completes inside one request, so
//     its own "already teleporting" state is never seen; a return scroll's
//     cast is (round 779): HandleTeleportUse asks GetTeleportState (vslot
//     0x120) right after the gate resolves and refuses 0x1c14,
//     UIIT_MSG_INTERACTION_FAIL_TELESCROLL_ALREADY_WORKING (READ, 0x513634;
//     category 0xd's table entry 13 -> 0x7ba0d7), before the range.
//   - A point with no associated object is refused with code 2 as well; the
//     engine answers nothing when its gate lookup (FUN_00485d90) fails -- a
//     bare `return` -- and OpenSRO does not leave a client waiting.
//   - The GM and -teleport-free waivers (teleport.QuoteFee), the refusal
//     reasons' wording, and the refusals that carry code 0 (not in the
//     world, dead, no network loaded, a destination OpenSRO cannot place).

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"

	"github.com/OpenSRO/OpenSRO/server/internal/berserk"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/gm"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/teleport"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The teleport pair, OpenSRO's own placeholders. 0x00F3/0x00F4 were free on
// 2026-09-26: the highest op in server/internal/session and
// client/scripts/net was 0x00F2 (OpGMCommandResult), and no file under
// server/, client/scripts or docs/ named either. The client half pins them
// (client/scripts/net/teleport.gd).
const (
	OpTeleportUse    uint16 = 0x00F3 // client -> server
	OpTeleportResult uint16 = 0x00F4 // server -> the requester
)

// teleportScrollWorking is HandleTeleportUse's refusal while a scroll's cast
// is working (round 779, READ above).
const teleportScrollWorking uint16 = 0x1c14

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
// 0x1c10, 0x1c15, 0x1c19, 0x1c23, 0x1c24) or 0 for a refusal of OpenSRO's
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

// TeleportHandler answers OpTeleportUse and, since round 686, OpRecallDesignate
// (recall.go). network is cmd/server's -teleport-dir
// (nil without it: every request is refused); gate is the GM account list, the
// same gm.Gate the GM console uses (nil: nobody is a GM); free is
// -teleport-free. logger may be nil.
func TeleportHandler(chars character.Store, eq equipment.Store, hub *world.Hub, network *teleport.Table, gate *gm.Gate, free bool, logger *slog.Logger, zerk *berserk.Tracker) gateway.Handler {
	t := &teleporter{chars: chars, eq: eq, hub: hub, network: network, gate: gate, free: free, logger: logger, zerk: zerk}
	// The dungeons the network serves, and their entries, and the walk-in
	// zones (round 773).
	InstallDungeonEntries(network)
	installWalkIns(t)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case OpTeleportUse:
			return t.use(ctx, sess, p)
		case OpRecallDesignate:
			// A town gate's "Designate as return/recall point" (round 686,
			// recall.go).
			return t.designate(ctx, sess, p)
		}
		return nil
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
	// zerk is the berserk tracker the arrival ends a running berserk in
	// (warpTo -> endBerserk); nil leaves it.
	zerk *berserk.Tracker
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
	gateCode, ok := gateObject(t.network, gatePoint)
	if !ok {
		return refuse(teleportNoLink, "no such gate", "gate", gatePoint.Code)
	}
	// A scroll's cast refuses the gate (round 779): 0x1c14, before the
	// range test, as HandleTeleportUse asks.
	if scrollCastingOn(sess) {
		return refuse(teleportScrollWorking, teleportRefusalReason(teleportScrollWorking), "gate", gateCode)
	}
	// A gate in another game world -- a fortress, tomb, temple or arena
	// point -- is refused as its destinations are (OURS, round 642's review:
	// OpenSRO has the open world only, so a player cannot stand at one).
	if !inOpenWorld(gatePoint) {
		return refuse(0, "that gate is in an instanced area OpenSRO does not have yet", "gate", gateCode, "world", gatePoint.WorldID)
	}
	// The interaction range, READ (round 642's review): HandleTeleportUse
	// calls GObjPC::IsWithinInteractionRange (0x4a8e10) here, before the
	// link, and refuses with its 3 (not the gate's type, or not in the
	// requester's region or a neighbour) or 4 (too far). teleport.Reach.
	if code, measured := t.reach(current, gatePoint); code != 1 {
		return refuse(uint16(code), teleportRefusalReason(uint16(code)), "gate", gateCode, "measured", measured)
	}
	link, ok := t.network.LinkBetween(gatePoint.ID, int(req.Destination))
	if !ok {
		return refuse(teleportNoLink, "no such destination", "gate", gateCode, "dest", req.Destination)
	}
	// teleport.Read refuses a link whose end is not a point, so this holds.
	dest, _ := t.network.PointByID(link.To)
	zone, bucket, pos, frame, ok := teleportArrival(dest)
	if !ok {
		return refuse(0, "that destination is not a place OpenSRO can put a player yet", "gate", gateCode, "dest", dest.Code)
	}
	c, err := t.chars.GetByID(ctx, current.CharacterID)
	if err != nil || c == nil {
		return refuse(0, "lookup failed")
	}
	// The PvP state is a DISCLOSED STAND-IN: OpenSRO models none (no PK
	// system; internal/duel's own-design duel sets none), so every character
	// is PvPSTATE_NEUTRAL here. It decides only rule type 3, which no retail
	// link carries (0 of 1,460 slots, round 575) -- no current outcome turns
	// on it.
	if code := teleport.CheckRestrictions(link, c.Level, teleport.PvPNeutral); code != 0 {
		return refuse(code, teleportRefusalReason(code), "gate", gateCode, "dest", dest.Code, "level", c.Level)
	}
	// A destination in another game world -- a fortress, tomb, arena or
	// survival instance (teleport.Point.WorldID) -- is refused: OpenSRO has
	// the open world only. OURS: the engine looks the world up
	// (GameWorldMgr_FindByID, 0x5137ac) and enters it, or refuses with code 2
	// when there is none (0x513802). It does so after the restrictions and
	// the gold compare, as here -- except that OpenSRO refuses the world
	// before a short purse, since its charge is the compare.
	if !inOpenWorld(dest) {
		return refuse(0, "that destination is an instanced area OpenSRO does not have yet", "gate", gateCode, "dest", dest.Code, "world", dest.WorldID)
	}
	isGM := t.gate.Allows(username)
	fee, waiver := teleport.QuoteFee(link, c.Level, isGM, t.free)
	if fee > 0 {
		if err := t.chars.DeductGold(ctx, c.ID, fee); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return refuse(teleport.ErrNotEnoughMoney, teleportRefusalReason(teleport.ErrNotEnoughMoney),
					"gate", gateCode, "dest", dest.Code, "fee", fee)
			}
			return refuse(0, "charging the fee failed")
		}
	}
	if t.logger != nil {
		t.logger.Info("teleport", "account", username, "character", c.Name,
			"gate", gateCode, "from", gatePoint.Code, "dest", dest.Code, "zone", zone, "frame", frame,
			"x", pos.X, "z", pos.Z, "fee", fee, "waiver", waiver, "gm", isGM, "free_flag", t.free)
	}
	// The receipt goes first: the client marks the OpChangeZoneResult that
	// follows as this teleport's arrival (World3D._on_teleport_result).
	if err := sess.Send(&proto.Packet{Opcode: OpTeleportResult, Data: (&TeleportResult{
		OK: true, Waiver: waiver, Fee: fee, Destination: dest.ZoneName,
	}).Encode()}); err != nil {
		return err
	}
	moved, err := warpVia(ctx, sess, t.eq, t.chars, t.hub, t.zerk, zone, bucket, pos, frame, "gate teleport")
	if !moved && fee > 0 {
		// The session left the world between the check above and the move;
		// nothing moved, so nothing is owed.
		if rerr := t.chars.AddGold(ctx, c.ID, fee); rerr != nil && t.logger != nil {
			t.logger.Error("teleport: refunding a fee after a failed move", "character", c.Name, "fee", fee, "err", rerr)
		}
	}
	return err
}

// gateObject names the object a player talks to at teleport point p: the
// teleportbuilding row whose id is the point's associated object and whose own
// point is this point (GATE_CH -> 2094 STORE_CH_GATE -> GATE_CH), or, since
// round 642, the NPC a point is associated with -- a ferry, airship or tunnel
// ticket seller, a Jangan gate soldier, a Constantinople guide
// (GATE_NPC_CH_FERRY -> 2011 NPC_CH_FERRY), which is not a building row. The
// name is the building's code, or the point's own code for an NPC (the
// server's tables do not carry NPC codes). ok is false for a point with no
// associated object (118 retail rows: walk-in portals and instance exits),
// which nothing a player clicks stands for.
//
// READ (round 642): the engine serves an NPC exactly as it serves a gate
// structure. RefTeleport_ExtractData (0x6a7be0) sets the associated ref
// object's +0x190 to the teleport record for ANY associated object
// (`mov [edx+0x190],ebx` at 0x6a7ce7, no class test), and
// GObjPC::HandleTeleportUse (0x513590) takes the link through that pointer
// (Gate_LinkForTeleportUse), after FUN_00485d00 has checked that the talked-to
// object offers interaction 8, 0x1c, 9 or 0x1e (refusing 3 otherwise). The id
// 8 is registered on the associated object of every link's SOURCE point when a
// byte of that point's record (+0x34) is 1 (CGameServer::FUN_006b5200 ->
// RefRow_AddInteraction8, 0x6a7f70, EAX = the source CRefTeleport from
// FUN_004f89f0 at 0x6b527c). That byte is the last one RefTeleport_ExtractData
// reads (0x6a7f45) and the client's teleportdata.txt has no column for it, so
// "the point has an outgoing link" stands in for it here -- which a link
// lookup (LinkBetween) already requires -- as it does on the client
// (NpcServiceReader.gate_services). Disclosed.
func gateObject(network *teleport.Table, p teleport.Point) (string, bool) {
	if p.ObjectID == 0 {
		return "", false
	}
	// The object must stand for this point (no retail object names two).
	if owner, ok := network.PointByObject(p.ObjectID); !ok || owner.ID != p.ID {
		return "", false
	}
	if b, ok := network.BuildingByID(p.ObjectID); ok {
		return b.Code, true
	}
	return p.Code, true
}

// inOpenWorld reports whether point p is in the open world, the one OpenSRO
// has: WorldID 1, or 0 for a teleportdata.csv exported before round 642,
// which does not say (cmd/server warns at boot).
func inOpenWorld(p teleport.Point) bool {
	return p.WorldID == 0 || p.WorldID == teleport.MainWorld
}

// reach is IsWithinInteractionRange's answer for the requester and the object
// gate point p stands for: 1 within reach, else teleport.ErrInteractionTarget
// (3) or teleport.ErrTooFar (4). The object is the point's associated object
// -- its teleportbuilding row for a gate structure (limit RangeStructure,
// 800), its npcpos placements for an NPC (limit RangeNPC, 300; the nearest
// placement counts). The type test (FUN_004a8d90) holds by construction: a
// building row is a structure and every other associated object with links
// is an NPCNPC (all 32 retail ones read TypeID 1, 2, 2).
//
// The requester's place is the hub position named back into region and local
// coordinates in its frame (worldmap.FromWorld; the world frame under
// -single-frame). OURS, disclosed: an NPC with no known placement -- a server
// run without -npcpos-csv -- is not measured (reach answers 1, measured
// false), and a requester whose zone has no frame is answered 3. The height
// is left out (teleport.Reach's horizontal mode, why there).
func (t *teleporter) reach(e world.Entity, p teleport.Point) (code int, measured bool) {
	places := t.network.ObjectPlaces(p.ObjectID)
	if len(places) == 0 {
		return 1, false
	}
	limit := teleport.RangeNPC
	if _, ok := t.network.BuildingByID(p.ObjectID); ok {
		limit = teleport.RangeStructure
	}
	from, ok := placeOfEntity(e)
	if !ok {
		return teleport.ErrInteractionTarget, true
	}
	code = teleport.ErrInteractionTarget
	for _, to := range places {
		switch c := teleport.Reach(from, to, limit, true); {
		case c == 1:
			return 1, true
		case c == teleport.ErrTooFar:
			code = c
		}
	}
	return code, true
}

// placeOfEntity is a hub entity's place as the tables name one: its region
// and the local x, y, z there -- in a dungeon (round 773) the rid and the
// dungeon-space point, which teleport.Reach compares as they are. ok is false
// for a zone with no frame and no dungeon.
func placeOfEntity(e world.Entity) (teleport.Place, bool) {
	if rid, ok := dungeonOf(e.Zone); ok {
		dx, dy, dz := worldmap.WorldToDungeon(e.Pos.X, e.Pos.Y, e.Pos.Z)
		return teleport.Place{Region: rid, X: dx, Y: dy, Z: dz}, true
	}
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		return teleport.Place{}, false
	}
	rx, ry, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
	return teleport.Place{Region: worldmap.RegionID(rx, ry), X: lx, Y: e.Pos.Y, Z: lz}, true
}

// entityFrame is the region a hub entity's coordinates are relative to: the
// world frame for the -single-frame bucket, else its zone label's own
// (worldmap.FrameFor).
func entityFrame(zone string) (rx, ry int, ok bool) {
	if zone == worldmap.WorldBucket {
		return worldmap.WorldOrigin[0], worldmap.WorldOrigin[1], true
	}
	return worldmap.FrameFor(zone)
}

// teleportArrival is where a teleport to point p lands: the zone label
// (teleportZoneFor), the hub bucket and FrameRegion arrival gives that label
// -- its own centre, or worldmap.WorldOrigin under -single-frame -- and the
// point named in that frame by worldmap.ToWorld (region y drives world X,
// region x drives world Z, Z mirrored: AGENTS.md, worldmap's measured
// columns), at spawnPos's height. A dungeon point (a negative region id) lands
// in its dungeon since round 773; ok is false for one in an instanced world.
func teleportArrival(p teleport.Point) (zone, bucket string, pos world.Position, frame string, ok bool) {
	if worldmap.IsDungeonRegion(p.Region) {
		// A dungeon point (round 773, dungeon.go): the dungeon's own label,
		// bucket and frame, at the point -- its x, y, z are dungeon space,
		// READ as the field's are (0x407760 copies the record's region word
		// and x/y/z words). The height is the table's: a dungeon's floors
		// stack, so 0 could name another floor. Only the open world's
		// dungeons are served (inOpenWorld); the instanced ones -- the job
		// temple, the Medusa and Zealot rooms -- stay refused (OURS).
		if !inOpenWorld(p) {
			return "", "", world.Position{}, "", false
		}
		zone = worldmap.DungeonZone(p.Region)
		x, y, z := worldmap.DungeonToWorld(float64(p.X), float64(p.Y), float64(p.Z))
		return zone, zone, world.Position{X: x, Y: y, Z: z}, zone, true
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
	case teleport.ErrTooFar:
		return "you are too far away"
	case teleport.ErrInteractionTarget:
		return "you are not near that gate"
	case teleportScrollWorking:
		return "a teleport scroll is already working"
	}
	return fmt.Sprintf("teleport refused (code 0x%x)", code)
}
