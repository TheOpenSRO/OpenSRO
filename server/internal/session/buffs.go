package session

// Buffs, self-casts and Ghost Walk (round 616; docs/protocol/skill_buffs.md,
// the shared contract of rounds 616-619).
//
// The four opcodes are srrevamp's own. 0x00F5..0x00F8 were free: the highest
// session opcode in use was OpTeleportResult 0x00F4 (teleport.go), no file
// under server/ or client/scripts/ defined any of the four (re-measured by
// grep at the start of this round), and the only mentions of the numbers were
// unrelated offsets. The retail analogues are named beside each.
//
// OpUseSkill (skill.go) grows a strict suffix: u8 targetType (0 none/self,
// 1 entity, 2 ground) and, for 2, the ground point as three f32. A request
// without it -- every client before round 617 -- decodes as targetType 1.

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"sync"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/buff"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

const (
	// OpBuffStart: a buff started on an owner (retail 0xB0BD, plus our time
	// and speed fields). Server -> every session in the owner's zone.
	OpBuffStart uint16 = 0x00F5
	// OpBuffEnd: an owner's buffs ended (retail 0xB072). Server -> the zone.
	OpBuffEnd uint16 = 0x00F6
	// OpBuffCancel: the player cancels one of its buffs (retail 0x7074
	// action kind 5). Client -> server; no reply -- success is the
	// OpBuffEnd broadcast, a refusal is silent, as retail's is.
	OpBuffCancel uint16 = 0x00F7
	// OpSkillMove: a ground cast moved its caster (Ghost Walk). Server -> the
	// zone, the caster included.
	OpSkillMove uint16 = 0x00F8
	// OpSelfID: the entering client's own character id -- the id OpBuffStart
	// and OpBuffEnd carry as ownerId and OpSkillMove as characterId. Server ->
	// the entering session only, once per OpEnterWorld (a reconnect included),
	// after the world-entry messages. Added to the contract in round 616 at
	// the coordinator's request; 0x00F9 was free (the same grep).
	OpSelfID uint16 = 0x00F9
)

// The OpUseSkill targetType values.
const (
	TargetNone   uint8 = 0
	TargetEntity uint8 = 1
	TargetGround uint8 = 2
	// TargetCharacter (3, round 622) is in friendlycast.go.
)

// PlayerRunSpeed is a player character's base run speed, characterdata
// Speed2 (column 47). MEASURED: all 52 player rows of the retail table
// (CHAR_CH_MAN_* .. CHAR_EU_WOMAN_*, ids from 1907) carry walk 16 and run 50,
// the number the client already moves by (World3D._move_speed).
const PlayerRunSpeed = 50

// buffBooks is every character's book of active buffs.
var buffBooks = buff.NewBooks(PlayerRunSpeed)

// buffLocks serialise, per owner, a book operation and the packets it sends
// (round 616's review): the speed a packet carries is the one the operation
// computed under the book's lock, and a later operation's packets cannot
// overtake an earlier one's. Per owner, so one slow client stalls only its
// own buffs.
var buffLocks sync.Map // int64 -> *sync.Mutex

func buffLock(ownerID int64) *sync.Mutex {
	l, _ := buffLocks.LoadOrStore(ownerID, &sync.Mutex{})
	return l.(*sync.Mutex)
}

// overlapRefusal is 0x300c UIIT_SKILL_USE_FAIL_OVERLAP's text, MEASURED in
// the retail textuisystem.txt.
const overlapRefusal = "The selected item cannot be used together or the skill is already in use."

// groundRefusal answers a ground cast of a skill with no ground move, and a
// 'tele' skill cast without a point: FUN_005862e0 returns 0 when the cast
// context's position list is empty, and the context builder aborts (READ).
// The text is OURS.
const groundRefusal = "select a location on the ground"

// notInWorldRefusal answers a cast whose named character is not the one the
// session has in the world; castFailedRefusal one whose buff or move could
// not be done after the costs (they are refunded). Texts OURS.
const (
	notInWorldRefusal = "not in world"
	castFailedRefusal = "the skill could not be used"
)

// targetRefusal answers a targetType 0 cast of a skill that needs a hostile
// target. The text is OURS.
const targetRefusal = "select a target first"

// The ownerKind byte OpBuffStart and OpBuffEnd end with (round 616): monster
// ids (combat.Hub's counter) and character ids (the database's) overlap.
const (
	OwnerCharacter uint8 = 0
	OwnerMonster   uint8 = 1
)

// BuffStart is the OpBuffStart payload.
type BuffStart struct {
	OwnerID     int64
	SkillID     int64
	Token       uint32
	DurationMs  int64 // -1: no duration
	RemainingMs int64 // -1: no duration
	RunSpeed    uint32
	OwnerKind   uint8 // a trailing byte; OwnerCharacter for every buff today
}

func (r *BuffStart) Encode() []byte {
	out := encodeInt64(r.OwnerID)
	out = append(out, encodeInt64(r.SkillID)...)
	out = binary.LittleEndian.AppendUint32(out, r.Token)
	out = append(out, encodeInt64(r.DurationMs)...)
	out = append(out, encodeInt64(r.RemainingMs)...)
	out = binary.LittleEndian.AppendUint32(out, r.RunSpeed)
	return append(out, r.OwnerKind)
}

func DecodeBuffStart(data []byte) (*BuffStart, error) {
	if len(data) != 40 && len(data) != 41 {
		return nil, fmt.Errorf("session: decoding BuffStart: %d bytes, want 41", len(data))
	}
	le := binary.LittleEndian
	kind := OwnerCharacter
	if len(data) == 41 {
		kind = data[40]
	}
	return &BuffStart{
		OwnerKind:   kind,
		OwnerID:     int64(le.Uint64(data[0:])),
		SkillID:     int64(le.Uint64(data[8:])),
		Token:       le.Uint32(data[16:]),
		DurationMs:  int64(le.Uint64(data[20:])),
		RemainingMs: int64(le.Uint64(data[28:])),
		RunSpeed:    le.Uint32(data[36:]),
	}, nil
}

// BuffEnd is the OpBuffEnd payload.
type BuffEnd struct {
	OwnerID   int64
	Tokens    []uint32
	RunSpeed  uint32
	OwnerKind uint8 // a trailing byte; OwnerCharacter for every buff today
}

func (r *BuffEnd) Encode() []byte {
	out := encodeInt64(r.OwnerID)
	out = append(out, byte(len(r.Tokens)))
	for _, t := range r.Tokens {
		out = binary.LittleEndian.AppendUint32(out, t)
	}
	out = binary.LittleEndian.AppendUint32(out, r.RunSpeed)
	return append(out, r.OwnerKind)
}

func DecodeBuffEnd(data []byte) (*BuffEnd, error) {
	if len(data) < 9 {
		return nil, errors.New("session: decoding BuffEnd: truncated")
	}
	n := int(data[8])
	if len(data) != 9+4*n+4 && len(data) != 9+4*n+5 {
		return nil, fmt.Errorf("session: decoding BuffEnd: %d bytes for %d tokens", len(data), n)
	}
	le := binary.LittleEndian
	r := &BuffEnd{OwnerID: int64(le.Uint64(data[0:]))}
	for i := 0; i < n; i++ {
		r.Tokens = append(r.Tokens, le.Uint32(data[9+4*i:]))
	}
	r.RunSpeed = le.Uint32(data[9+4*n:])
	if len(data) == 9+4*n+5 {
		r.OwnerKind = data[9+4*n+4]
	}
	return r, nil
}

// SelfID is the OpSelfID payload.
type SelfID struct {
	CharacterID int64
}

func (r *SelfID) Encode() []byte { return encodeInt64(r.CharacterID) }

func DecodeSelfID(data []byte) (*SelfID, error) {
	if len(data) != 8 {
		return nil, fmt.Errorf("session: decoding SelfID: %d bytes, want 8", len(data))
	}
	return &SelfID{CharacterID: int64(binary.LittleEndian.Uint64(data))}, nil
}

// BuffCancelRequest is the OpBuffCancel payload. Token 0 cancels the first
// record of the skill, as FUN_0059ef90 matches any record for a zero token.
type BuffCancelRequest struct {
	CharacterName string
	SkillID       int64
	Token         uint32
}

func (r *BuffCancelRequest) Encode() []byte {
	out := encodeStrings(r.CharacterName)
	out = append(out, encodeInt64(r.SkillID)...)
	return binary.LittleEndian.AppendUint32(out, r.Token)
}

func DecodeBuffCancelRequest(data []byte) (*BuffCancelRequest, error) {
	fields, rest, err := decodeStringsPrefix(data, 1)
	if err != nil {
		return nil, fmt.Errorf("session: decoding BuffCancelRequest: %w", err)
	}
	id, rest, err := decodeInt64(rest)
	if err != nil {
		return nil, fmt.Errorf("session: decoding BuffCancelRequest: skill id: %w", err)
	}
	if len(rest) < 4 {
		return nil, errors.New("session: decoding BuffCancelRequest: token: truncated")
	}
	return &BuffCancelRequest{CharacterName: fields[0], SkillID: id, Token: binary.LittleEndian.Uint32(rest)}, nil
}

// SkillMove is the OpSkillMove payload: where a ground cast put its caster.
type SkillMove struct {
	CharacterID int64
	SkillID     int64
	X, Y, Z     float32
}

func (r *SkillMove) Encode() []byte {
	out := encodeInt64(r.CharacterID)
	out = append(out, encodeInt64(r.SkillID)...)
	out = append(out, encodeFloat32(r.X)...)
	out = append(out, encodeFloat32(r.Y)...)
	return append(out, encodeFloat32(r.Z)...)
}

func DecodeSkillMove(data []byte) (*SkillMove, error) {
	if len(data) != 8+8+12 {
		return nil, fmt.Errorf("session: decoding SkillMove: %d bytes, want 28", len(data))
	}
	le := binary.LittleEndian
	return &SkillMove{
		CharacterID: int64(le.Uint64(data[0:])),
		SkillID:     int64(le.Uint64(data[8:])),
		X:           math.Float32frombits(le.Uint32(data[16:])),
		Y:           math.Float32frombits(le.Uint32(data[20:])),
		Z:           math.Float32frombits(le.Uint32(data[24:])),
	}, nil
}

// buffSpec is what a cast of ref starts: the row's own group, level,
// duration, markers and speed runs.
func buffSpec(ref *refdata.Skill, casterID int64) buff.Spec {
	s := buff.Spec{
		SkillID: ref.ID, GroupID: ref.GroupID, Level: ref.BasicLevel, CasterID: casterID,
		DuraMs: ref.DuraMs, Cbuf: ref.Cbuf, Nbuf: ref.Nbuf,
		Lnks: ref.Lnks, Lks2: ref.Lks2, TargetRequired: ref.TargetRequired,
	}
	if v, ok := ref.BuffParam("hste"); ok && len(v) > 0 {
		s.HasHste, s.Hste = true, v[0]
	}
	if v, ok := ref.BuffParam("hst2"); ok && len(v) > 0 {
		s.HasHst2, s.Hst2 = true, v[0]
	}
	if v, ok := ref.BuffParam("hst3"); ok && len(v) > 0 {
		s.HasHst3, s.Hst3 = true, v[0]
	}
	return s
}

// startsCasterBuff reports whether a cast of ref starts a buff on its caster:
// action kind 3 (SkillAction_Buff) with Target_Required 0 -- its targets are
// the caster (Skill_CollectTargetsByEffect with no 'efr', INFERRED in the
// spec §2.2) -- or with Target_Required 1 and a friendly target group (Self,
// Ally or Party), which since round 622 starts on the character the cast
// names (friendlycast.go; nothing named is refused, as the retail client
// refuses it). A Target_Required 1 row whose groups are
// all hostile (the DOTs, Water Cancel -- a debuff on the target) is not a
// caster buff and is not modelled: it keeps the path it had before.
func startsCasterBuff(ref *refdata.Skill) bool {
	if ref == nil || ref.ActionKind != 3 {
		return false
	}
	return !ref.TargetRequired || ref.TargetSelf || ref.TargetAlly || ref.TargetParty
}

// zoneOf returns every entity in characterID's zone, the character included,
// or nil when it is not in the world.
func zoneOf(hub *world.Hub, characterID int64) []world.Entity {
	if hub == nil {
		return nil
	}
	e, ok := hub.EntityByCharacterID(characterID)
	if !ok {
		return nil
	}
	return hub.EntitiesInZone(e.Zone)
}

func sendToAll(to []world.Entity, op uint16, data []byte) {
	for _, e := range to {
		if e.Session != nil {
			e.Session.Send(&proto.Packet{Opcode: op, Data: data})
		}
	}
}

// buffStartPacket is rec as OpBuffStart at now.
func buffStartPacket(rec buff.Record, now time.Time, runSpeed uint32) []byte {
	msg := &BuffStart{OwnerID: rec.OwnerID, SkillID: rec.SkillID, Token: rec.Token,
		DurationMs: -1, RemainingMs: -1, RunSpeed: runSpeed, OwnerKind: OwnerCharacter}
	if rec.Timed() {
		msg.DurationMs = rec.Dura.Milliseconds()
		msg.RemainingMs = rec.Remaining(now).Milliseconds()
	}
	return msg.Encode()
}

// speedField is what a packet's runSpeed carries: the new speed when the
// operation changed it, 0 (unchanged) otherwise.
func speedField(sp buff.Speed) uint32 {
	if sp.Changed {
		return sp.RunSpeed
	}
	return 0
}

// broadcastBuffEnd sends OpBuffEnd for ended (all of one owner, already out
// of its book) to the owner's zone, with the speed the ending operation
// computed. The caller holds buffLock(ownerID).
func broadcastBuffEnd(to []world.Entity, ownerID int64, ended []buff.Record, sp buff.Speed) {
	speed := speedField(sp)
	// The count is a byte on the wire; a book this large does not occur,
	// but a split keeps the packet honest if it ever does.
	for len(ended) > 0 {
		n := len(ended)
		if n > 255 {
			n = 255
		}
		msg := &BuffEnd{OwnerID: ownerID, RunSpeed: speed, OwnerKind: OwnerCharacter}
		for _, r := range ended[:n] {
			msg.Tokens = append(msg.Tokens, r.Token)
		}
		sendToAll(to, OpBuffEnd, msg.Encode())
		ended = ended[n:]
	}
}

// startCasterBuffLocked applies ref to casterID at now and tells zone: an
// OpBuffEnd for the record the recast rule ended, then the OpBuffStart. The
// caller holds buffLock(casterID) from its own buffBooks.CheckOverlap to
// here, so the refusal cannot change in between; false is returned only if
// it did anyway.
func startCasterBuffLocked(zone []world.Entity, ref *refdata.Skill, casterID int64, now time.Time) bool {
	return startCasterBuffOn(zone, ref, casterID, casterID, now)
}

// startCasterBuffOn starts ref's buff, cast by casterID, on ownerID's book and
// tells zone (the owner's). The caller holds ownerID's buff lock. Round 622:
// the owner is the named character for a friendly Target_Required 1 row.
func startCasterBuffOn(zone []world.Entity, ref *refdata.Skill, casterID, ownerID int64, now time.Time) bool {
	rec, ended, refused, sp := buffBooks.Start(ownerID, buffSpec(ref, casterID), now)
	if refused != buff.NotRefused {
		return false
	}
	// Both packets carry the speed the one operation left: the end's and the
	// start's agree, whichever the client applies last.
	broadcastBuffEnd(zone, ownerID, ended, sp)
	sendToAll(zone, OpBuffStart, buffStartPacket(rec, now, speedField(sp)))
	return true
}

// endBuffsOf clears ownerID's whole book and tells its zone (a death).
func endBuffsOf(hub *world.Hub, ownerID int64) {
	l := buffLock(ownerID)
	l.Lock()
	defer l.Unlock()
	ended, sp := buffBooks.EndAll(ownerID)
	broadcastBuffEnd(zoneOf(hub, ownerID), ownerID, ended, sp)
}

// expireBuffs is one pass of the ticker: every record past its end ends.
func expireBuffs(hub *world.Hub, now time.Time) {
	for _, owner := range buffBooks.DueOwners(now) {
		l := buffLock(owner)
		l.Lock()
		ended, sp := buffBooks.ExpireOwner(owner, now)
		broadcastBuffEnd(zoneOf(hub, owner), owner, ended, sp)
		l.Unlock()
	}
}

// RunBuffTicker ends buffs at their end time: SkillBook::Update's active-
// action pass, one per character per server frame in retail (the frame
// period is OPEN). This polls every buffPoll (OURS, as regen's poll is); the
// end test itself is exact (buff.Record.Expired).
func RunBuffTicker(ctx context.Context, hub *world.Hub, logger *slog.Logger) {
	t := time.NewTicker(buffPoll)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			expireBuffs(hub, now)
		}
	}
}

// buffPoll is how often RunBuffTicker looks. OURS.
const buffPoll = 100 * time.Millisecond

// sendBuffsInView is what a character entering a zone learns and tells: the
// active buffs of everyone already there go to it, and its own go to them.
// OURS -- whether retail re-sends active buffs on entering view is OPEN (spec
// §6 item 7); without it a player arriving would see no aura or icon on a
// character already buffed, and a player's own bar would lose nothing (its
// own buffs come back to it too, and the client keys them by token).
func sendBuffsInView(hub *world.Hub, arriving world.Entity, now time.Time) {
	if hub == nil {
		return
	}
	// A record that writes the run speed carries its owner's current one
	// (round 616's review), so a client arriving -- or the owner's own, after
	// a zone change -- learns the speed along with the buff.
	packets := func(owner int64) [][]byte {
		recs := buffBooks.Active(owner)
		if len(recs) == 0 {
			return nil
		}
		speed := buffBooks.RunSpeed(owner)
		var out [][]byte
		for _, rec := range recs {
			s := uint32(0)
			if buff.Contributes(rec) {
				s = speed
			}
			out = append(out, buffStartPacket(rec, now, s))
		}
		return out
	}
	for _, other := range hub.EntitiesInZone(arriving.Zone) {
		for _, data := range packets(other.CharacterID) {
			arriving.Session.Send(&proto.Packet{Opcode: OpBuffStart, Data: data})
		}
	}
	mine := packets(arriving.CharacterID)
	if len(mine) == 0 {
		return
	}
	for _, other := range hub.EntitiesInZone(arriving.Zone) {
		if other.CharacterID == arriving.CharacterID || other.Session == nil {
			continue
		}
		for _, data := range mine {
			other.Session.Send(&proto.Packet{Opcode: OpBuffStart, Data: data})
		}
	}
}

// BuffHandler answers OpBuffCancel: the dispel of retail's 0x7074 action kind
// 5 (0x4ae520 -> FUN_0059ef90 / FUN_0059eff0). A cancel that finds no record,
// or that the 'nbuf' rule refuses, changes nothing and answers nothing -- the
// retail handler returns silently in both cases (it answers 0x3003 only for a
// zero skill id, which srrevamp's request cannot carry meaningfully).
func BuffHandler(chars character.Store, hub *world.Hub) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if p.Opcode != OpBuffCancel {
			return nil
		}
		req, err := DecodeBuffCancelRequest(p.Data)
		if err != nil {
			return nil
		}
		characterID, errStr := resolveCharacterID(ctx, sess, chars, req.CharacterName)
		if errStr != "" {
			return nil
		}
		// The named character must be the one this session has in the
		// world (round 616's review), as for a cast.
		e, inWorld := hub.EntityBySession(sess.ID())
		if !inWorld || e.CharacterID != characterID {
			return nil
		}
		l := buffLock(characterID)
		l.Lock()
		defer l.Unlock()
		rec, res, sp := buffBooks.Cancel(characterID, req.SkillID, req.Token)
		if res != buff.Cancelled {
			return nil
		}
		broadcastBuffEnd(hub.EntitiesInZone(e.Zone), characterID, []buff.Record{rec}, sp)
		return nil
	}
}

// ghostWalkDestination is FUN_005862e0's 'tele' clamp: the requested point
// when it lies within d world units of from, otherwise the point d units
// from from along the line to it. The distance is the full three-component
// length (the function squares and sums all three offsets, READ).
func ghostWalkDestination(from, to world.Position, d float64) world.Position {
	dx, dy, dz := to.X-from.X, to.Y-from.Y, to.Z-from.Z
	dist := math.Sqrt(dx*dx + dy*dy + dz*dz)
	if dist <= d || dist == 0 {
		return to
	}
	k := d / dist
	return world.Position{X: from.X + dx*k, Y: from.Y + dy*k, Z: from.Z + dz*k}
}

// finitePosition reports whether all three coordinates are finite numbers:
// a NaN or an infinity from the wire is refused before anything is spent
// (round 616's review) -- the clamp's arithmetic would carry it into the
// stored position.
func finitePosition(x, y, z float32) bool {
	for _, v := range []float32{x, y, z} {
		f := float64(v)
		if math.IsNaN(f) || math.IsInf(f, 0) {
			return false
		}
	}
	return true
}

// moveBySkill puts the session's character at pos the way a move does
// (world.Hub.Move, the periodic position save), and tells the zone -- the
// caster included -- with OpSkillMove.
//
// NOT MODELLED, disclosed: the navmesh reachability test FUN_005862e0 runs
// before it accepts the point (DAT_00cc387c vtable +0x30; bit 0x10000000
// refuses). srrevamp's server has no navmesh -- movement is client-
// authoritative (handleMove stores what the client sends) -- so the landing
// point is the clamped point, and the client stands the player on its own
// walkable graph there, as it does for every move.
func moveBySkill(sess *gateway.Session, hub *world.Hub, chars character.Store, skillID int64, pos world.Position, now time.Time) bool {
	if e, inWorld := hub.EntityBySession(sess.ID()); inWorld {
		if accepted, _ := motions.moved(e.CharacterID, now); !accepted {
			return false
		}
	}
	entity, _, ok := hub.Move(sess, pos)
	if !ok {
		return false
	}
	keepUp.Cancel(entity.CharacterID)
	savePositionEvery(chars, sess, entity, now)
	msg := &SkillMove{CharacterID: entity.CharacterID, SkillID: skillID,
		X: float32(pos.X), Y: float32(pos.Y), Z: float32(pos.Z)}
	sendToAll(hub.EntitiesInZone(entity.Zone), OpSkillMove, msg.Encode())
	return true
}
