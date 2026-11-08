package session

// Round 865 stage 2: the guardian matching board, 0x747A..0x747F
// (docs/protocol/academy.md 7.10). The board lives in memory, as the shard
// manager keeps it, and loses a camp's entry when its guardian logs out, the
// camp fills or disbands.
//
// OPEN, labelled: the push that puts a join request to the guardian and the
// fields of its answer (0x347F). Without the question the guardian is never
// asked, so a request that passes every refusal waits the 15 s and ends as
// "no reply" (0xB47E {01, 02}, READ c:0x892c50 UIIT_MSG_TC_JOIN_NOREPLY).

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// acJoin is a join request waiting for its guardian.
type acJoin struct {
	entry uint32
	timer *time.Timer
}

// academyJoinWait is the join request's wait (READ m:0x79b018, 15.0f).
var academyJoinWait = academy.MatchJoinWaitSeconds * time.Second

func (rt *academyRuntime) handleBoard(ctx context.Context, sess *gateway.Session, e world.Entity, p *proto.Packet) {
	switch p.Opcode {
	case proto.OpAcademyMatchEntry:
		rt.handleMatchEntry(ctx, sess, e, p.Data)
	case proto.OpAcademyMatchCorrect:
		rt.handleMatchModify(ctx, sess, e, p.Data)
	case proto.OpAcademyMatchDelete:
		rt.handleMatchDelete(ctx, sess, e, p.Data)
	case proto.OpAcademyMatchList:
		rt.handleMatchList(ctx, sess, p.Data)
	case proto.OpAcademyMatchJoin:
		rt.handleMatchJoin(ctx, sess, e, p.Data)
	case proto.OpAcademyMatchJoinAnswer:
		// OPEN: the guardian's answer's fields (relayed raw to the shard,
		// s:0x4168f0). Not acted on.
	}
}

// guardianCamp is boardCheck's shared tail (s:0x4e4950 / s:0x4e4a10): dead
// 0x6808, no camp 0x6824, not the guardian 0x6816; 0 and the camp when it
// passes.
func (rt *academyRuntime) guardianCamp(ctx context.Context, e world.Entity) (*academy.Camp, uint16) {
	if e.Life == world.LifeDead {
		return nil, uint16(academy.ErrWrongState)
	}
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		return nil, ErrAcademyNoPosition
	}
	if m, ok := c.Member(e.CharacterID); !ok || m.Class != academy.MemberClassGuardian {
		return nil, academy.ErrOrderWork
	}
	return c, 0
}

// handleMatchEntry is s:0x519b80: s:0x4e4950's order -- dead 0x6808, a job
// suit change under way 0x6823 (pc[0x30]+0x13, OpenSRO's jobChangePending),
// no camp 0x6824, not the guardian 0x6816, the invite penalty 0x681f --
// then the board (already listed 0x6825); 0xB47A {01, entry, graduates}
// (MEASURED). The type byte is kept as sent (1 apprentices, 2 assistants).
func (rt *academyRuntime) handleMatchEntry(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyMatchEntryAck
	req, err := academy.DecodeMatchEntry(data)
	if err != nil {
		return
	}
	if e.Life == world.LifeDead {
		acFail(sess, op, uint16(academy.ErrWrongState))
		return
	}
	if jobChangePending(e.CharacterID) {
		acFail(sess, op, ErrAcademyJobDress)
		return
	}
	c, code := rt.guardianCamp(ctx, e)
	if code != 0 {
		acFail(sess, op, code)
		return
	}
	if rt.penaltyLeft(ctx, e.CharacterID, academy.PenaltyIDInvite) > 0 {
		acFail(sess, op, academy.ErrNotInvite24T)
		return
	}
	entry, code := rt.board.Register(uint32(c.ID), req.Flags, req.Title)
	if code != 0 {
		acFail(sess, op, code)
		return
	}
	acSend(sess, op, academy.EncodeMatchEntryOK(entry, uint32(c.GraduateCount)))
}

// handleMatchModify is s:0x519bd0 (s:0x4e4a10's checks, then the entry 0x6826
// when not the camp's); 0xB47B {01, u32 entry, u32 camp, u8 flags, str
// title} (READ c:0x890960; no trailing u32).
func (rt *academyRuntime) handleMatchModify(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyMatchCorrectAck
	req, err := academy.DecodeMatchEntry(data)
	if err != nil {
		return
	}
	c, code := rt.guardianCamp(ctx, e)
	if code != 0 {
		acFail(sess, op, code)
		return
	}
	entry, code := rt.board.Modify(req.ID, uint32(c.ID), req.Flags, req.Title)
	if code != 0 {
		acFail(sess, op, code)
		return
	}
	acSend(sess, op, academy.EncodeMatchModifyOK(entry))
}

// handleMatchDelete is s:0x519c20: the same checks; 0xB47C {01, u32 entry}
// (MEASURED).
func (rt *academyRuntime) handleMatchDelete(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyMatchDeleteAck
	id, err := academy.DecodeU32(data)
	if err != nil {
		return
	}
	c, code := rt.guardianCamp(ctx, e)
	if code != 0 {
		acFail(sess, op, code)
		return
	}
	if code := rt.board.Delete(id, uint32(c.ID)); code != 0 {
		acFail(sess, op, code)
		return
	}
	acSend(sess, op, academy.EncodeMatchDeleteOK(id))
}

// handleMatchList is s:0x519c70 (no checks): 0xB47D for page (MEASURED empty:
// 01 00 00 00).
func (rt *academyRuntime) handleMatchList(ctx context.Context, sess *gateway.Session, data []byte) {
	page, err := academy.DecodeU8(data)
	if err != nil {
		return
	}
	entries, pages := academy.Page(rt.board.Entries(), int(page))
	var rows []academy.MatchRow
	for _, en := range entries {
		c, err := rt.Store.Get(ctx, int64(en.CampID))
		if err != nil {
			continue
		}
		g, ok := c.Guardian()
		if !ok {
			continue
		}
		rows = append(rows, academy.MatchRow{Entry: en, Level: byte(g.CurLevel), MaxLevel: byte(g.MaxLevel),
			RefObjID: uint32(g.RefObjID), Guardian: g.Name, GraduateCount: uint32(c.GraduateCount), Rank: byte(c.Rank),
			Assistants: uint32(c.Count(academy.MemberClassSecondGuardian)), Apprentices: uint32(c.Count(academy.MemberClassStudent))})
	}
	if len(rows) == 0 {
		page = 0
	}
	acSend(sess, proto.OpAcademyMatchListAck, academy.EncodeMatchList(byte(pages), page, rows))
}

// handleMatchJoin is s:0x519cc0 then the shard (m:0x45a010), in their order:
// the game server's s:0x4e4aa0 -- dead 3, the entry penalties 0x681e, in a
// camp 0x6812 -- then the shard's: the entry 0x6826, the role by the max
// level (60 or more 3), the apprentices full 0x6828, not recruiting
// apprentices 0x682a, the assistants full 0x6810, not recruiting assistants
// 0x682a, a request already waiting 0x6827, the guardian offline 0x680c;
// then the 15 s wait (see the file's OPEN note).
func (rt *academyRuntime) handleMatchJoin(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyMatchJoinAck
	id, err := academy.DecodeU32(data)
	if err != nil {
		return
	}
	if e.Life == world.LifeDead {
		acFail(sess, op, academy.InviteRefused)
		return
	}
	if rt.penaltyLeft(ctx, e.CharacterID, academy.PenaltyIDEnter) > 0 || rt.penaltyLeft(ctx, e.CharacterID, academy.PenaltyIDEnter3D) > 0 {
		acFail(sess, op, ErrAcademyEnterPenalty)
		return
	}
	if rt.campOf(ctx, e.CharacterID) != nil {
		acFail(sess, op, academy.ErrAlreadyInCamp)
		return
	}
	entry, ok := rt.board.Get(id)
	if !ok {
		acFail(sess, op, academy.ErrBoardNoEntry)
		return
	}
	c, err := rt.Store.Get(ctx, int64(entry.CampID))
	if err != nil {
		acFail(sess, op, academy.ErrBoardNoEntry)
		return
	}
	class := academy.ClassForMaxLevel(e.Level)
	switch class {
	case academy.MemberClassStudent:
		if academy.RoleFull(class, c.Count(class)) {
			acFail(sess, op, ErrAcademyStudentsFull)
			return
		}
	case academy.MemberClassSecondGuardian:
		if academy.RoleFull(class, c.Count(class)) {
			acFail(sess, op, ErrAcademySecondFull)
			return
		}
	default:
		acFail(sess, op, academy.InviteRefused)
		return
	}
	if !academy.RecruitsRole(entry.Flags, class) {
		acFail(sess, op, academy.ErrBoardRole)
		return
	}
	g, ok := c.Guardian()
	if !rt.board.Hold(id) {
		acFail(sess, op, academy.ErrBoardPending)
		return
	}
	if _, online := entityOf(rt.Hub, g.CharID); !ok || !online {
		rt.board.Release(id)
		acFail(sess, op, ErrAcademyInviterGone)
		return
	}
	j := &acJoin{entry: id}
	j.timer = time.AfterFunc(academyJoinWait, func() { rt.joinNoReply(e.CharacterID, j) })
	rt.mu.Lock()
	rt.joins[e.CharacterID] = j
	rt.mu.Unlock()
}

// joinNoReply ends a join request the guardian did not answer: 0xB47E {01,
// 02}.
func (rt *academyRuntime) joinNoReply(requester int64, j *acJoin) {
	rt.mu.Lock()
	if rt.joins[requester] != j {
		rt.mu.Unlock()
		return
	}
	delete(rt.joins, requester)
	rt.mu.Unlock()
	rt.board.Release(j.entry)
	if e, ok := entityOf(rt.Hub, requester); ok {
		acSend(e.Session, proto.OpAcademyMatchJoinAck, academy.EncodeMatchJoinResult(academy.MatchJoinNoReply))
	}
}

// dropJoins ends characterID's waiting join request (it left the world).
func (rt *academyRuntime) dropJoins(characterID int64) {
	rt.mu.Lock()
	j := rt.joins[characterID]
	delete(rt.joins, characterID)
	rt.mu.Unlock()
	if j != nil {
		j.timer.Stop()
		rt.board.Release(j.entry)
	}
}
