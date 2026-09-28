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
)

// PlayerRunSpeed is a player character's base run speed, characterdata
// Speed2 (column 47). MEASURED: all 52 player rows of the retail table
// (CHAR_CH_MAN_* .. CHAR_EU_WOMAN_*, ids from 1907) carry walk 16 and run 50,
// the number the client already moves by (World3D._move_speed).
const PlayerRunSpeed = 50

// buffBooks is every character's book of active buffs.
var buffBooks = buff.NewBooks()

// overlapRefusal is 0x300c UIIT_SKILL_USE_FAIL_OVERLAP's text, MEASURED in
// the retail textuisystem.txt.
const overlapRefusal = "The selected item cannot be used together or the skill is already in use."

// groundRefusal answers a ground cast of a skill with no ground move, and a
// 'tele' skill cast without a point: FUN_005862e0 returns 0 when the cast
// context's position list is empty, and the context builder aborts (READ).
// The text is OURS.
const groundRefusal = "select a location on the ground"

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
	}
	if v, ok := ref.BuffParam("hste"); ok && len(v) > 0 {
		s.HasHste, s.Hste = true, v[0]
	}
	if v, ok := ref.BuffParam("hst3"); ok && len(v) > 0 {
		s.HasHst3, s.Hst3 = true, v[0]
	}
	if _, ok := ref.BuffParam("hst2"); ok {
		s.HasHst2 = true
	}
	return s
}

// startsCasterBuff reports whether a cast of ref starts a buff on its caster:
// action kind 3 (SkillAction_Buff) with Target_Required 0 -- its targets are
// the caster (Skill_CollectTargetsByEffect with no 'efr', INFERRED in the
// spec §2.2) -- or with Target_Required 1 and a friendly target group (Self,
// Ally or Party), whose target resolution when nothing friendly is selected
// is OPEN: it lands on the caster. A Target_Required 1 row whose groups are
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

// broadcastBuffEnd sends one OpBuffEnd for ended (all of one owner, already
// out of its book) to the owner's zone. runSpeed is the owner's new run speed
// when one of the ended records had written to it, 0 (unchanged) otherwise.
func broadcastBuffEnd(hub *world.Hub, ownerID int64, ended []buff.Record) {
	if len(ended) == 0 {
		return
	}
	speed := uint32(0)
	if buff.Contributes(ended...) {
		speed = buffBooks.RunSpeed(ownerID, PlayerRunSpeed)
	}
	to := zoneOf(hub, ownerID)
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

// startCasterBuff applies ref to casterID at now and tells the zone: an
// OpBuffEnd for the records the recast rule ended, then the OpBuffStart,
// whose runSpeed is the caster's new run speed when the new record wrote to
// it (0 otherwise). The refusal was checked before the costs
// (buffBooks.CheckOverlap); a refusal here -- a race between two casts --
// starts nothing.
func startCasterBuff(hub *world.Hub, ref *refdata.Skill, casterID int64, now time.Time) (buff.Record, bool) {
	rec, ended, refused := buffBooks.Start(casterID, buffSpec(ref, casterID), now)
	if refused != buff.NotRefused {
		return buff.Record{}, false
	}
	broadcastBuffEnd(hub, casterID, ended)
	speed := uint32(0)
	if buff.Contributes(rec) {
		speed = buffBooks.RunSpeed(casterID, PlayerRunSpeed)
	}
	sendToAll(zoneOf(hub, casterID), OpBuffStart, buffStartPacket(rec, now, speed))
	return rec, true
}

// endBuffsOf clears ownerID's whole book and tells its zone (a death).
func endBuffsOf(hub *world.Hub, ownerID int64) {
	broadcastBuffEnd(hub, ownerID, buffBooks.EndAll(ownerID))
}

// expireBuffs is one pass of the ticker: every record past its end ends.
func expireBuffs(hub *world.Hub, now time.Time) {
	for owner, ended := range buffBooks.Expire(now) {
		broadcastBuffEnd(hub, owner, ended)
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
	for _, other := range hub.EntitiesInZone(arriving.Zone) {
		for _, rec := range buffBooks.Active(other.CharacterID) {
			arriving.Session.Send(&proto.Packet{Opcode: OpBuffStart, Data: buffStartPacket(rec, now, 0)})
		}
	}
	mine := buffBooks.Active(arriving.CharacterID)
	if len(mine) == 0 {
		return
	}
	for _, other := range hub.EntitiesInZone(arriving.Zone) {
		if other.CharacterID == arriving.CharacterID || other.Session == nil {
			continue
		}
		for _, rec := range mine {
			other.Session.Send(&proto.Packet{Opcode: OpBuffStart, Data: buffStartPacket(rec, now, 0)})
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
		rec, res := buffBooks.Cancel(characterID, req.SkillID, req.Token)
		if res != buff.Cancelled {
			return nil
		}
		broadcastBuffEnd(hub, characterID, []buff.Record{rec})
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
