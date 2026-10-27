package session

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The GM console is ONE additive op pair: the client sends a command line,
// the server answers with a text reply (plus the little structure a reply
// needs -- a place to move to, which views went stale, whether the account
// is a GM at all). New commands are new words in the line, not new opcodes.
// Our own protocol; nothing here mirrors an original-client feature.
const (
	OpGMCommand       uint16 = 0x00F1 // client -> server
	OpGMCommandResult uint16 = 0x00F2 // server -> client
)

// Refresh bits in GMCommandResult.Refresh, telling the client which of its
// views a command made stale.
const (
	gmRefreshStats     = 1 << 0
	gmRefreshMonsters  = 1 << 1
	gmRefreshInventory = 1 << 2
	gmRefreshEquipment = 1 << 3
)

// GMCommandRequest is what the client sends: the character name (as every
// other request identifies the actor), the command line exactly as typed,
// and the monster the client currently has selected (0 if none -- /kill
// needs it, and selection is the client's to know). An empty Line is the
// probe the client fires on enter-world to learn whether it is a GM.
type GMCommandRequest struct {
	Name            string
	Line            string
	SelectedMonster int64
}

func (r *GMCommandRequest) Encode() []byte {
	out := encodeStrings(r.Name, r.Line)
	return append(out, encodeInt64(r.SelectedMonster)...)
}

func DecodeGMCommandRequest(data []byte) (*GMCommandRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 2)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandRequest: %w", err)
	}
	id, _, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandRequest: selected monster: %w", err)
	}
	return &GMCommandRequest{Name: fields[0], Line: fields[1], SelectedMonster: id}, nil
}

// GMCommandResult is the reply. IsGM is set for an account the gate allows,
// so the client can show its GM tooltip and section to GMs only. Refused
// marks a command that did nothing. The rest is the optional structure a
// reply may carry: a place to move to (HasPos/Zone/X/Z), a level-up to
// announce, and the Refresh bitmask.
type GMCommandResult struct {
	IsGM    bool
	Refused bool
	Text    string

	HasPos bool
	Zone   string // a zone to change to first; "" for none
	X, Z   float32

	NewLevel   int32 // 0 = no level-up
	StatPoints int32

	Refresh uint8
}

func (r *GMCommandResult) Encode() []byte {
	out := []byte{boolByte(r.IsGM), boolByte(r.Refused)}
	out = append(out, encodeStrings(r.Text)...)
	out = append(out, boolByte(r.HasPos))
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Z)...)
	out = append(out, encodeStrings(r.Zone)...)
	out = append(out, encodeInt32(r.NewLevel)...)
	out = append(out, encodeInt32(r.StatPoints)...)
	out = append(out, r.Refresh)
	return out
}

func DecodeGMCommandResult(data []byte) (*GMCommandResult, error) {
	if len(data) < 2 {
		return nil, fmt.Errorf("session: decoding GMCommandResult: truncated flags")
	}
	res := &GMCommandResult{IsGM: data[0] != 0, Refused: data[1] != 0}
	text, rest, err := decodeStringsPrefix(data[2:], 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: text: %w", err)
	}
	res.Text = text[0]
	if len(rest) < 1 {
		return nil, fmt.Errorf("session: decoding GMCommandResult: truncated position flag")
	}
	res.HasPos = rest[0] != 0
	rest = rest[1:]
	if res.X, rest, err = decodeFloat32(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: x: %w", err)
	}
	if res.Z, rest, err = decodeFloat32(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: z: %w", err)
	}
	zone, rest, err := decodeStringsPrefix(rest, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: zone: %w", err)
	}
	res.Zone = zone[0]
	if res.NewLevel, rest, err = decodeInt32(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: level: %w", err)
	}
	if res.StatPoints, rest, err = decodeInt32(rest); err != nil {
		return nil, fmt.Errorf("session: decoding GMCommandResult: stat points: %w", err)
	}
	if len(rest) < 1 {
		return nil, fmt.Errorf("session: decoding GMCommandResult: truncated refresh")
	}
	res.Refresh = rest[0]
	return res, nil
}

// GMCommandHandler runs GM commands for accounts the gate allows. gate may
// be nil (nobody is a GM), and every field of deps may be nil (a command
// whose dependency is missing refuses with a reply). hub is the world hub,
// consulted for the actor's authoritative zone and position -- so /tp's
// "current zone" and /spawn's placement come from where the server has the
// character, not from anything the client claims.
func GMCommandHandler(chars character.Store, gate *gm.Gate, deps *gm.Deps, hub *world.Hub, logger *slog.Logger) gateway.Handler {
	if deps == nil {
		deps = &gm.Deps{}
	}
	if deps.Logger == nil {
		deps.Logger = logger
	}
	if deps.Speed == nil {
		deps.Speed = gmSpeed{hub: hub}
	}
	if deps.Afflict == nil {
		deps.Afflict = gmAfflict{hub: hub, deps: strikeDeps{chars: chars, eq: deps.Equip, items: deps.Items, mp: deps.Mana, hub: hub}}
	}
	if deps.Clock == nil {
		deps.Clock = gmClock{hub: hub}
	}
	if deps.Jobs == nil {
		deps.Jobs = gmJobs{}
	}
	// Round 788: /block refuses a GM's account; /ban kicks from the world.
	if deps.IsGMAccount == nil {
		deps.IsGMAccount = gate.Allows
	}
	if deps.Sessions == nil {
		deps.Sessions = GMSessions{Hub: hub}
	}
	// Round 764's review, F3: a GM's zone change may name any spot.
	zoneSpotGate.Store(gate)
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpGMCommand {
			return nil
		}
		req, err := DecodeGMCommandRequest(p.Data)
		if err != nil {
			return sess.Send(&proto.Packet{Opcode: OpGMCommandResult, Data: (&GMCommandResult{Refused: true, Text: "malformed command"}).Encode()})
		}

		username, _ := AuthenticatedUsername(sess)
		isGM := gate.Allows(username)

		// The gate first. A non-GM gets a plain refusal -- except the
		// enter-world probe (an empty line), which stays silent so a normal
		// player never sees a refusal they did not ask for.
		if !isGM {
			text := "GM commands are not enabled for your account."
			refused := true
			if req.Line == "" {
				text, refused = "", false
			}
			if logger != nil && req.Line != "" {
				logger.Info("gm command refused: not a GM", "account", username, "character", req.Name, "line", req.Line)
			}
			return sess.Send(&proto.Packet{Opcode: OpGMCommandResult, Data: (&GMCommandResult{IsGM: false, Refused: refused, Text: text}).Encode()})
		}

		// The probe: a GM's client asks "am I a GM?" on enter-world. Answer
		// yes and hand back the one-line help, which the client prints once.
		if req.Line == "" {
			return sess.Send(&proto.Packet{Opcode: OpGMCommandResult, Data: (&GMCommandResult{IsGM: true, Text: gm.Help}).Encode()})
		}

		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.Name)
		if errStr != "" {
			return sess.Send(&proto.Packet{Opcode: OpGMCommandResult, Data: (&GMCommandResult{IsGM: true, Refused: true, Text: errStr}).Encode()})
		}

		accountID, _ := AuthenticatedAccountID(sess)
		actor := gm.Actor{
			Account: username, AccountID: accountID, CharacterID: characterID, Name: req.Name,
			TargetMonsterID: req.SelectedMonster,
		}
		if hub != nil {
			if ent, ok := hub.EntityByCharacterID(characterID); ok {
				// The entity's zone is its hub BUCKET (world.Entity.Zone): the
				// zone label, or worldmap.WorldBucket for every label with a
				// frame under -single-frame (round 571). The console's uses,
				// mapped: /spawn spawns into it and /kill's broadcast goes to
				// it (both want the bucket, where the players are); /tp is in
				// its frame (the one world's, under the flag); /goto compares
				// it with LABELS, and under the flag no label equals the
				// bucket -- so /goto <zone> always travels (a label is a grid
				// hint, not where the GM is) and /goto <monster> always names
				// the species' zone label for the client to re-centre on
				// (gm.Actor.Zone). The reply's Zone below is therefore always
				// a label: gotoSpot's zone or species zone, never the bucket,
				// and /kill's bucket is cleared from it.
				actor.Zone = ent.Zone
				actor.X, actor.Y, actor.Z = ent.Pos.X, ent.Pos.Y, ent.Pos.Z
				// A dead GM is not moved (round 549): /tp and /goto refuse on
				// this, the rest of the console runs (gm.Actor.Dead).
				actor.Dead = ent.Life == world.LifeDead
			}
		}

		// The selected monster's watchers before the command (round 656's
		// review): a /kill is announced to them as well as to those watching
		// where it died.
		// /damage may name its monster by id (gm.CommandTarget).
		var watchedBefore []world.Entity
		target := gm.CommandTarget(req.Line, actor.TargetMonsterID)
		if hub != nil && deps.Monsters != nil && target != 0 {
			if m, alive := deps.Monsters.Get(target); alive {
				watchedBefore = monsterWatchers(hub, deps.Monsters, m)
			}
		}
		out := deps.Run(ctx, actor, req.Line)
		if gmAfterRunHook != nil {
			gmAfterRunHook()
		}
		// A /tp or /goto puts the GM where its client then stands it; a wall's
		// root takes that landing as a warp's (round 646, walls.go
		// noteWarpLanding, OURS).
		if out.HasPos && !out.Refused {
			noteWarpLanding(characterID, time.Now(), [2]float64{out.X, out.Z})
			// And for anyone (round 749, destmove.go): a relocation to the
			// GM's point is taken.
			noteGMLanding(characterID, time.Now(), out.X, out.Z)
		}

		// A GM /kill removes the monster server-side; tell the rest of the
		// zone it is gone, the same broadcast a combat kill sends. The GM's
		// own client learns it from RefreshMonsters in this reply.
		// Round 656: to the players whose area of interest held the monster
		// (monsterWatchers), each under its monster wire lock.
		if out.KilledMonsterID != 0 && hub != nil {
			msg := (&MonsterDied{MonsterID: out.KilledMonsterID}).Encode()
			dead := combat.Monster{ID: out.KilledMonsterID, Zone: out.Zone, X: out.KilledX, Z: out.KilledZ}
			if out.KilledMonsterID != target {
				watchedBefore = nil
			}
			for _, e := range unionWatchers(watchedBefore, monsterWatchers(hub, deps.Monsters, dead)) {
				if e.Session.ID() != sess.ID() {
					sendMonsterPush(e.Session, &proto.Packet{Opcode: OpMonsterDied, Data: msg})
				}
			}
		}

		result := &GMCommandResult{
			IsGM: true, Refused: out.Refused, Text: out.Text,
			HasPos: out.HasPos, Zone: out.Zone, X: float32(out.X), Z: float32(out.Z),
		}
		if out.LevelUp != nil {
			result.NewLevel = int32(out.LevelUp.NewLevel)
			result.StatPoints = int32(out.LevelUp.StatPoints)
		}
		// /kill's Zone is where the monster was, not a place to send the
		// player; only /tp and /goto move the player. Keep Zone for a move.
		if !out.HasPos && out.KilledMonsterID != 0 {
			result.Zone = ""
		}
		if out.RefreshStats {
			result.Refresh |= gmRefreshStats
		}
		if out.RefreshMonsters {
			result.Refresh |= gmRefreshMonsters
		}
		if out.RefreshInventory {
			result.Refresh |= gmRefreshInventory
		}
		if out.RefreshEquipment {
			result.Refresh |= gmRefreshEquipment
		}
		// Round 786 (arrival.go): with the arrival guard on, a /tp or a
		// /goto to a monster is the server's own warp -- out of the world
		// behind the loading screen until the client's 0x3012, then the
		// protection -- not the client's placement; the reply then names no
		// move of its own. A /goto to a zone alone stays the client's
		// OpChangeZone, which warps the same way.
		if out.HasPos && !out.Refused && arrivalGuardOn.Load() && hub != nil {
			if zone, bucket, pos, frame, ok := gmWarpTarget(sess, hub, out.Zone, out.X, out.Z); ok {
				result.HasPos, result.Zone = false, ""
				defer func() {
					_, _ = warpVia(ctx, sess, deps.Equip, chars, hub, deps.Berserk, zone, bucket, pos, frame, "gm "+gmVerb(req.Line))
				}()
			}
		}
		err = sess.Send(&proto.Packet{Opcode: OpGMCommandResult, Data: result.Encode()})
		// A /silk change (round 837): 0x3154 then 0x3153, as retail's
		// outside-change path (mall.go).
		if out.Silk != nil {
			SilkChanged(sess, out.Silk.Reason, out.Silk.CashType, out.Silk.Offset, out.Silk.After)
		}
		// A GM /notice (round 634) reaches every character, the GM included,
		// after the GM's own reply.
		if out.Notice != "" {
			BroadcastNotice(hub, out.Notice)
		}
		// A worn item's new plus (/item worn, round 735) reaches the zone as
		// a 0x3038 of the same item (equip_broadcast.go, OURS: retail changes
		// no worn item's plus).
		for _, slot := range out.WornChanged {
			var items ItemLookup
			if deps.Items != nil {
				items = deps.Items
			}
			broadcastWorn(ctx, hub, deps.Equip, items, characterID, equipment.Slot(slot))
		}
		// A GM /spawn is pushed to the whole zone, the GM included, after the
		// GM's own reply (round 542, behind -monster-spawn-push; off, nothing
		// is sent). Until then the other players found it only on their next
		// monster list. Sent whether or not the reply went out: the monsters
		// exist either way.
		for _, id := range out.SpawnedMonsterIDs {
			BroadcastMonsterSpawned(hub, deps.Monsters, id)
		}
		// A unique a GM spawns or kills is announced to the world as any
		// unique is (round 657, uniquenotice.go): the spawn by its hatch,
		// the kill by the damage list. A /kill with no one on the list is
		// announced with the "???" killer, which the client shows as "...
		// has disappeared" -- OURS: retail has no GM kill, and its rule
		// (no killer, no notice) would leave the GM's kill silent.
		if deps.Monsters != nil {
			for _, id := range out.SpawnedMonsterIDs {
				if m, ok := deps.Monsters.Get(id); ok {
					AnnounceUniqueSpawn(hub, m, false)
				}
			}
		}
		if out.Killed != nil {
			if len(out.KillHits) > 0 {
				AnnounceUniqueKill(hub, deps.Parties, *out.Killed, out.KillHits)
			} else if UniqueNoticeFor(out.Killed.Rarity) {
				broadcastUniqueNotice(hub, &UniqueNotice{Kind: UniqueNoticeKill, RefObjID: uint32(out.Killed.RefObjID), Killer: UnknownKiller})
			}
		}
		return err
	}
}

func boolByte(b bool) byte {
	if b {
		return 1
	}
	return 0
}

// gmAfterRunHook, when set, runs right after a GM command has run and before
// its announcements: a test's window between a /kill and its death broadcast
// (TestGMKillReachesTheWatchersBeforeIt). nil in production.
var gmAfterRunHook func()

// gmWarpTarget is where a GM /tp or /goto to a monster puts the GM as a
// server warp (round 786): zone "" is a point in the GM's own place (its
// label, frame and bucket now, at its height now -- the client stands it on
// its ground at the arrival); a zone names the species' zone label, whose
// bucket and frame arrival gives. ok is false when the GM is not in the world
// or has no place yet.
func gmWarpTarget(sess *gateway.Session, hub *world.Hub, zone string, x, z float64) (label, bucket string, pos world.Position, frame string, ok bool) {
	cur, in := hub.EntityBySession(sess.ID())
	if !in {
		return "", "", world.Position{}, "", false
	}
	if zone == "" {
		p, known := placeOf(sess)
		if !known {
			return "", "", world.Position{}, "", false
		}
		return p.zone, cur.Zone, world.Position{X: x, Y: cur.Pos.Y, Z: z}, p.frame, true
	}
	b, _, f, _ := arrival(zone)
	return zone, b, world.Position{X: x, Z: z}, f, true
}

// gmVerb is a command line's first word, for the warp's log.
func gmVerb(line string) string {
	f := strings.Fields(strings.TrimPrefix(strings.TrimSpace(line), "/"))
	if len(f) == 0 {
		return ""
	}
	return "/" + strings.ToLower(f[0])
}
