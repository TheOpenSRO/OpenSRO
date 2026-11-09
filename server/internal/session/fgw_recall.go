package session

// The Forgotten World's party recall (round 869, lane W3;
// docs/protocol/forgotten_world.md 8 and 11 SERVER item 5): the recall NPC
// inside (NPC_FWORLD_RECALL_PARTY, interaction 0x27) lets the party's master
// pull a member from the town into the master's layer -- the way the rest of a
// party comes in, since a type-6 gate admits its creator only.
//
//	0x7519 {u32 npc}                 master -> the member list
//	0xB519 {01, u8 n, n x {u32 char, u8 state, u8 level, u16 minutes}} | {02, u16}
//	0x751A {u32 char}                master -> summon one member
//	0xB51A {02, u16 code}            master <- a refusal (category 0x23)
//	0x751A {u32 uid, u32 char, u32 5, str name}   push to the member
//	0x751C {u32 requester, u32 own, u8 1 | 0}     the member's answer
//	0xB51C {01} | {02, u16}          member <- the answer's reply
//
// READ (the server): 0x7519 (s:0x51bb70) wants the recall NPC within reach
// (3 otherwise), a party (0x1c33), its master (0x1c34) and two members (2),
// then runs an overlapped job (0x7d1b, 15.0 s) whose answer is the list.
// 0x751A (s:0x51bd60): a party (0x1c33), its master (0x1c34), not oneself
// (3), two members (2), a member (3), not already in an instance (0x1c35),
// then CCallUserMgr's request (2 when it fails); the member gets the push.
// 0x751C (s:0x51bf10) hands the answer to the requester's side.
//
// MEASURED (round 869, the master inside at the pillar, the member in
// Jangan):
//   - the list came 113 ms after 0x7519 -- no 15 s wait: the job's 15 s is
//     its limit (gameworld.RecallJobTimeout); OpenSRO answers at once;
//   - its per-member u8 is the member's LEVEL (65), the state 2 (possible),
//     the minutes 0;
//   - the summon sent nothing back to the master; the member got {u32 0x1F5,
//     u32 0x596, u32 5, str master's name} and the box "%s is summoning you.";
//   - Yes: 0x30BF {member uid, 0B, 01} (the teleport state), 0xB51C {01}, and
//     5.4 s later the member was warped into the master's layer at the
//     world's start, with the entry notices, its own 0x320C and its own
//     re-entry job;
//   - the party dismissed inside moved nobody.
//
// INFERRED / OURS, labelled where used: the list's states (1 a member already
// in the layer, 3 one CanEnter refuses or who stands outside a town); the u16
// as the member's own re-entry limit in minutes (MEASURED 0 for a member with
// none); the request's life as the client's 20 s (gameworld.SummonWait); the
// member's checks at the summon in the category-0x23 codes' order; the
// first u32 of the push as the master's uid (OpenSRO's uid is the character
// id's low 32 bits, round 710, so it equals the second). OPEN: what a No
// sends the master (none here), and its text.

import (
	"context"
	"encoding/binary"
	"math"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// summonReq is one open summon: the master's request to a member.
type summonReq struct {
	master, member int64
	masterName     string
	w              *gameworld.World
	at             time.Time
	accepted       bool
	timer          *time.Timer
}

var summons = struct {
	sync.Mutex
	byMember map[int64]*summonReq
}{byMember: map[int64]*summonReq{}}

// recallReply is {02, code} or {01}.
func recallReply(code uint16) []byte {
	if code == 0 {
		return []byte{1}
	}
	return binary.LittleEndian.AppendUint16([]byte{2}, code)
}

// FGWRecallHandler answers 0x7519, 0x751A and 0x751C (the package note).
func FGWRecallHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case proto.OpPartyRecallList:
			return recallList(ctx, sess, p.Data)
		case proto.OpPartyRecallSummon:
			if code := recallSummon(ctx, sess, p.Data); code != 0 {
				return sess.Send(&proto.Packet{Opcode: proto.OpPartyRecallSummonAck, Data: recallReply(code)})
			}
		case proto.OpPartyRecallAnswer:
			return recallAnswer(ctx, sess, p.Data)
		}
		return nil
	}
}

// recallMaster is the caller's layer, entity and party for 0x7519 / 0x751A:
// its refusal code when it is no party's master.
func recallMaster(sess *gateway.Session) (*gameworld.World, world.Entity, *party.Party, uint16) {
	hub := sessionHub(sess)
	w := instanceOf(hub)
	if hub == nil {
		return nil, world.Entity{}, nil, gameworld.CodeRecallTarget
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok {
		return nil, world.Entity{}, nil, gameworld.CodeRecallTarget
	}
	ps := gameWorldDeps().Parties
	var p *party.Party
	in := false
	if ps != nil {
		p, in = ps.Get(e.CharacterID)
	}
	if !in {
		return w, e, nil, gameworld.CodeNotParty
	}
	if p.LeaderID != e.CharacterID {
		return w, e, p, gameworld.CodeNotMaster
	}
	return w, e, p, 0
}

// recallNPCInReach reports the recall NPC uid of the caller's layer within
// the NPCs' reach (READ s:0x51bb70: IsWithinInteractionRange, then id 0x27
// in the NPC's set).
func recallNPCInReach(hub *world.Hub, e world.Entity, uid uint32) bool {
	pl, ok := npcInWorld(hub, uid, e.Zone)
	if !ok || pl.npc == nil {
		return false
	}
	has := false
	for _, b := range pl.npc.Interact {
		has = has || b == gameworld.RecallInteraction
	}
	if !has {
		return false
	}
	dx, dy, dz := pl.x-e.Pos.X, float64(pl.npc.Y)-e.Pos.Y, pl.z-e.Pos.Z
	return math.Sqrt(dx*dx+dy*dy+dz*dz) <= npcInteractRange
}

// RecallMember is one row of 0xB519.
type RecallMember struct {
	CharID  uint32
	State   uint8
	Level   uint8
	Minutes uint16
}

// EncodeRecallList is 0xB519's success.
func EncodeRecallList(ms []RecallMember) []byte {
	b := []byte{1, byte(len(ms))}
	for _, m := range ms {
		b = binary.LittleEndian.AppendUint32(b, m.CharID)
		b = append(b, m.State, m.Level)
		b = binary.LittleEndian.AppendUint16(b, m.Minutes)
	}
	return b
}

func recallList(ctx context.Context, sess *gateway.Session, data []byte) error {
	fail := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: proto.OpPartyRecallListAck, Data: recallReply(code)})
	}
	if len(data) < 4 {
		return fail(gameworld.CodeRecallTarget)
	}
	w, e, p, code := recallMaster(sess)
	if w == nil || !recallNPCInReach(sessionHub(sess), e, binary.LittleEndian.Uint32(data)) {
		return fail(gameworld.CodeRecallTarget)
	}
	if code != 0 {
		return fail(code)
	}
	if len(p.Members) < 2 {
		return fail(gameworld.CodeRecallPlain)
	}
	now := w.Clock().Now()
	var rows []RecallMember
	for _, m := range p.Members {
		if m.CharacterID == e.CharacterID {
			continue
		}
		rows = append(rows, recallRow(ctx, w, m, now))
	}
	return sess.Send(&proto.Packet{Opcode: proto.OpPartyRecallListAck, Data: EncodeRecallList(rows)})
}

// recallRow is one member's row: its state, its level and its re-entry
// limit's minutes (the package note).
func recallRow(ctx context.Context, w *gameworld.World, m party.Member, now time.Time) RecallMember {
	row := RecallMember{CharID: uint32(m.CharacterID), State: gameworld.RecallImpossible, Level: uint8(m.Level)}
	hub := world.HubOf(nil, m.CharacterID)
	if hub == nil {
		return row
	}
	me, ok := hub.EntityByCharacterID(m.CharacterID)
	if !ok {
		return row
	}
	row.Level = uint8(me.Level)
	if g := w.Ref.Group; g != nil {
		if j, running := groupCoolTime(ctx, m.CharacterID, g.ID, now); running {
			row.Minutes = uint16(j.End.Sub(now) / time.Minute)
		}
	}
	if instanceOf(hub) == w {
		row.State = gameworld.RecallInside
		return row
	}
	if summonRefusal(ctx, w, hub, me, now) == 0 {
		row.State = gameworld.RecallPossible
	}
	return row
}

// summonRefusal is why member e cannot be summoned into w now (0: it can):
// the category-0x23 codes (forgotten_world.md 8), in this order (OURS order
// past the READ ones): in an instance 0x1c35, dead 0x1c36, outside a town
// 0x1c37, busy (a stall or an exchange) 0x1c0b, then the world's CanEnter.
func summonRefusal(ctx context.Context, w *gameworld.World, hub *world.Hub, e world.Entity, now time.Time) uint16 {
	if instanceOf(hub) != nil {
		return gameworld.CodeOtherWorld
	}
	if e.Life == world.LifeDead {
		return gameworld.CodeDead
	}
	if !fgwInTown(e) {
		return gameworld.CodeNotTown
	}
	if _, _, stalled := stallOf(e.CharacterID); stalled || exchangeEstablished(e.CharacterID) {
		return gameworld.CodeBusy
	}
	if c := gameworld.CanEnter(w, entrantOf(ctx, e, false, now), now); c != 0 {
		if c == 2 || c == 6 {
			return gameworld.CodeBusy
		}
		return c
	}
	return 0
}

// recallSummon is 0x751A from the master: its refusal, or 0 when the push
// went to the member (MEASURED: nothing comes back to the master then).
func recallSummon(ctx context.Context, sess *gateway.Session, data []byte) uint16 {
	if len(data) < 4 {
		return gameworld.CodeRecallTarget
	}
	target := int64(binary.LittleEndian.Uint32(data))
	w, e, p, code := recallMaster(sess)
	if code != 0 {
		return code
	}
	if w == nil {
		return gameworld.CodeRecallTarget
	}
	if target == e.CharacterID {
		return gameworld.CodeRecallTarget
	}
	if len(p.Members) < 2 {
		return gameworld.CodeRecallPlain
	}
	var member party.Member
	found := false
	for _, m := range p.Members {
		if m.CharacterID == target {
			member, found = m, true
		}
	}
	if !found {
		return gameworld.CodeRecallTarget
	}
	hub := world.HubOf(nil, member.CharacterID)
	if hub == nil {
		return gameworld.CodeRecallTarget
	}
	me, ok := hub.EntityByCharacterID(member.CharacterID)
	if !ok || me.Session == nil {
		return gameworld.CodeRecallTarget
	}
	now := fgwClock()
	if c := summonRefusal(ctx, w, hub, me, w.Clock().Now()); c != 0 {
		return c
	}
	summons.Lock()
	if s := summons.byMember[member.CharacterID]; s != nil && now.Sub(s.at) < gameworld.SummonWait {
		summons.Unlock()
		return gameworld.CodeSummonWait
	}
	req := &summonReq{master: e.CharacterID, member: member.CharacterID, masterName: e.Name, w: w, at: now}
	summons.byMember[member.CharacterID] = req
	summons.Unlock()
	push := binary.LittleEndian.AppendUint32(nil, uint32(e.CharacterID))
	push = binary.LittleEndian.AppendUint32(push, uint32(e.CharacterID))
	push = binary.LittleEndian.AppendUint32(push, uint32(gameworld.SummonDelay/time.Second))
	push = binary.LittleEndian.AppendUint16(push, uint16(len(e.Name)))
	push = append(push, e.Name...)
	_ = me.Session.Send(&proto.Packet{Opcode: proto.OpPartyRecallSummon, Data: push})
	if l := gameWorldDeps().Logger; l != nil {
		l.Info("party recall: summon sent", "world", w.ID.String(), "master", e.CharacterID, "member", member.CharacterID)
	}
	return 0
}

// takeSummon is the open summon of member by requester, nil for none or
// one past its 20 s.
func takeSummon(member, requester int64, now time.Time) *summonReq {
	summons.Lock()
	defer summons.Unlock()
	s := summons.byMember[member]
	if s == nil || s.master != requester || s.accepted || now.Sub(s.at) >= gameworld.SummonWait {
		return nil
	}
	return s
}

// recallAnswer is the member's 0x751C.
func recallAnswer(ctx context.Context, sess *gateway.Session, data []byte) error {
	reply := func(code uint16) error {
		return sess.Send(&proto.Packet{Opcode: proto.OpPartyRecallAnswerAck, Data: recallReply(code)})
	}
	if len(data) < 9 {
		return reply(gameworld.CodeRecallTarget)
	}
	requester := int64(binary.LittleEndian.Uint32(data))
	own := int64(binary.LittleEndian.Uint32(data[4:]))
	yes := data[8] == 1
	hub := sessionHub(sess)
	if hub == nil {
		return reply(gameworld.CodeRecallTarget)
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok || e.CharacterID != own {
		return reply(gameworld.CodeRecallTarget)
	}
	s := takeSummon(own, requester, fgwClock())
	if s == nil {
		return reply(gameworld.CodeRecallTarget)
	}
	if !yes {
		summons.Lock()
		if summons.byMember[own] == s {
			delete(summons.byMember, own)
		}
		summons.Unlock()
		return reply(0)
	}
	// MEASURED: the teleport state first, then {01}, then 5.4 s later the
	// warp.
	broadcastScrollState(hub, own, 1)
	if err := reply(0); err != nil {
		return err
	}
	summons.Lock()
	s.accepted = true
	s.timer = time.AfterFunc(summonDelay(), func() { completeSummon(context.Background(), sess, s) })
	summons.Unlock()
	return nil
}

// summonDelay is the accepted member's wait (a test seam).
var summonDelay = func() time.Duration { return gameworld.SummonDelay }

// completeSummon warps the accepted member into the master's layer
// (INFERRED: the member's CanEnter applies again at the warp; MEASURED, it
// arrives at the world's start).
func completeSummon(ctx context.Context, sess *gateway.Session, s *summonReq) {
	summons.Lock()
	if summons.byMember[s.member] == s {
		delete(summons.byMember, s.member)
	}
	summons.Unlock()
	hub := sessionHub(sess)
	if hub == nil || s.w.Closed() {
		return
	}
	e, ok := hub.EntityBySession(sess.ID())
	if !ok || e.CharacterID != s.member {
		return
	}
	if c := summonRefusal(ctx, s.w, hub, e, s.w.Clock().Now()); c != 0 {
		broadcastScrollState(hub, s.member, 0)
		if l := gameWorldDeps().Logger; l != nil {
			l.Info("party recall: summon refused at the warp", "member", s.member, "code", c)
		}
		return
	}
	broadcastScrollState(hub, s.member, 0)
	if err := EnterInstance(ctx, sess, s.w, "party recall"); err != nil {
		if l := gameWorldDeps().Logger; l != nil {
			l.Warn("party recall: warp failed", "member", s.member, "err", err)
		}
	}
}

// forgetSummonsOf drops w's open summons (its close).
func forgetSummonsOf(w *gameworld.World) {
	summons.Lock()
	defer summons.Unlock()
	for id, s := range summons.byMember {
		if s.w == w {
			if s.timer != nil {
				s.timer.Stop()
			}
			delete(summons.byMember, id)
		}
	}
}
