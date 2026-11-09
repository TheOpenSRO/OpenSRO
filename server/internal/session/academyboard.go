package session

// Round 865 stage 2: the guardian matching board, 0x747A..0x747F
// (docs/protocol/academy.md 7.10). The board lives in memory, as the shard
// manager keeps it, and loses a camp's entry when its guardian logs out, the
// camp fills or disbands.
//
// Round 866: a join request is put to the camp's guardian (0x747E down, its
// question box) and the guardian's 0x347F settles it (READ c:0x890fa0,
// c:0x645c46, c:0x81d530; MEASURED on both sides, docs/protocol/academy.md
// 7.10). Before, the question was OPEN and never sent: a request waited 15 s
// and ended "no reply" with no box on the guardian's side.

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// acJoin is a join request waiting for its guardian's answer.
type acJoin struct {
	id        uint32 // the job id the question and its answer carry
	entry     uint32
	requester int64
	guardian  int64
	campID    int64
	timer     *time.Timer
}

// academyJoinWait is how long a join request waits for its guardian's answer
// before it ends "no reply" (academy.MatchJoinBackstop; tests shorten it).
var academyJoinWait = academy.MatchJoinBackstop

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
		rt.handleMatchJoinAnswer(ctx, e, p.Data)
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
	entry, code := rt.board.RegisterAt(uint32(c.ID), req.Flags, req.Title, rt.now())
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
// 0x682a, a request already waiting 0x6827, the guardian offline 0x680c.
// Then the question goes to the guardian (round 866): 0x747E down with the
// job id and the requester (academy.EncodeMatchJoinAsk), and the requester
// waits for its 0x347F; nothing goes to the requester yet (MEASURED: its
// next message is the 0xB47E the answer brings).
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
	ge, online := entityOf(rt.Hub, g.CharID)
	if !ok || !online {
		rt.board.Release(id)
		acFail(sess, op, ErrAcademyInviterGone)
		return
	}
	rt.dropJoins(e.CharacterID)
	joiner := rt.joinerOf(ctx, e)
	j := &acJoin{entry: id, requester: e.CharacterID, guardian: g.CharID, campID: c.ID}
	rt.mu.Lock()
	rt.joinSeq++
	j.id = rt.joinSeq
	j.timer = time.AfterFunc(academyJoinWait, func() { rt.joinNoReply(e.CharacterID, j) })
	rt.joins[e.CharacterID] = j
	rt.mu.Unlock()
	acSend(ge.Session, proto.OpAcademyMatchJoin, academy.EncodeMatchJoinAsk(academy.MatchJoinAsk{
		JobID: j.id, Requester: party.JIDOf(e.CharacterID), Entry: id, Level: byte(e.Level), MaxLevel: byte(e.Level),
		RefObjID: uint32(joiner.RefObjID), Name: e.Name}))
	rt.log().Info("academy match join asked", "character_id", e.CharacterID, "name", e.Name, "camp_id", c.ID,
		"entry", id, "job", j.id, "guardian", g.CharID)
}

// handleMatchJoinAnswer is the guardian's 0x347F {u32 job, u32 requester, u8
// answer} (READ c:0x81d530; s:0x519d10 relays it to the shard, whose
// m:0x459b30 acts on the answer: 0 and 2 end the request, 1 joins). OURS, as
// the party matching's answer (partymatch.go): only the camp's guardian may
// answer its own job, and the echoed requester must be the job's; an answer
// that fails either is dropped and the request keeps waiting.
func (rt *academyRuntime) handleMatchJoinAnswer(ctx context.Context, e world.Entity, data []byte) {
	jobID, requester, answer, err := academy.DecodeMatchJoinAnswer(data)
	if err != nil {
		return
	}
	rt.mu.Lock()
	var j *acJoin
	for _, w := range rt.joins {
		if w.id == jobID {
			j = w
			break
		}
	}
	if j == nil || j.guardian != e.CharacterID || requester != party.JIDOf(j.requester) {
		rt.mu.Unlock()
		rt.log().Info("academy match answer dropped", "character_id", e.CharacterID, "job", jobID, "answer", answer)
		return
	}
	delete(rt.joins, j.requester)
	rt.mu.Unlock()
	j.timer.Stop()
	rt.board.Release(j.entry)
	rt.resolveMatchJoin(ctx, j, answer)
}

// resolveMatchJoin carries out the guardian's answer (MEASURED, each step's
// messages on each side):
//   - 0 (No, or the guardian's box timing out at 15 s): the requester gets
//     0xB47E {01 00} ("Request has been cancelled."); the guardian nothing.
//   - 2: the requester gets 0xB47E {01 02} (the shard's own no-reply; its
//     client prints "Reply time has passed, ...").
//   - 1: the requester joins: the guardian gets 0x3C80 02, 0d, 05 and then
//     0xB47E {01 01}; the requester 0x3C80 {0a 01, CampInfo}, 05 and then
//     0xB47E {01 01} -- both print "Registration has been completed." on the
//     banner (MEASURED, the same instant). A failed accept (the requester
//     gone, joined elsewhere meanwhile, the role filled) answers 0xB47E {02,
//     code} to both (INFERRED from m:0x459b30's two sends on that path; the
//     codes are the store's, as an invitation's).
//
// Any other answer is dropped, as the shard asserts on it.
func (rt *academyRuntime) resolveMatchJoin(ctx context.Context, j *acJoin, answer byte) {
	const op = proto.OpAcademyMatchJoinAck
	req, rok := entityOf(rt.Hub, j.requester)
	guard, gok := entityOf(rt.Hub, j.guardian)
	log := rt.log().With("requester", j.requester, "guardian", j.guardian, "camp_id", j.campID, "job", j.id)
	switch answer {
	case academy.MatchJoinRefused, academy.MatchJoinNoReply:
		if rok {
			acSend(req.Session, op, academy.EncodeMatchJoinResult(answer))
		}
		log.Info("academy match join answered", "answer", answer)
		return
	case academy.MatchJoinDone:
	default:
		log.Info("academy match join answer ignored", "answer", answer)
		return
	}
	fail := func(code uint16) {
		if rok {
			acFail(req.Session, op, code)
		}
		if gok {
			acFail(guard.Session, op, code)
		}
		log.Info("academy match join refused", "code", code)
	}
	if !rok {
		fail(ErrAcademyRequesterGone)
		return
	}
	if rt.campOf(ctx, j.requester) != nil {
		fail(academy.ErrAlreadyInCamp)
		return
	}
	c, err := rt.Store.AddMember(ctx, j.campID, rt.joinerOf(ctx, req), rt.now())
	if err != nil {
		fail(storeCode(err))
		return
	}
	rt.announceJoin(ctx, c, req)
	if gok {
		acSend(guard.Session, op, academy.EncodeMatchJoinResult(academy.MatchJoinDone))
	}
	acSend(req.Session, op, academy.EncodeMatchJoinResult(academy.MatchJoinDone))
	log.Info("academy joined", "character_id", j.requester, "by", "matching")
}

// joinNoReply ends a join request no answer came for in academy.
// MatchJoinBackstop: 0xB47E {01, 02} to the requester.
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
	rt.log().Info("academy match join no reply", "requester", requester, "guardian", j.guardian, "job", j.id)
}

// dropJoins ends characterID's waiting join request (it left the world, or
// asked again).
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
