package session

// Round 865 stage 2: the academy (the engine's training camp) on retail's
// opcodes, docs/protocol/academy.md. This file holds the requests
// 0x7470..0x7478 and 0x7483 in the game server's refusal orders (section 7,
// crossed channels included) and the invitation's 0x3080 kind 9;
// academylive.go the world entry, logout, moves, level refresh and honor
// rank; academyboard.go the matching board; academyshop.go the honor store.
//
// Not modelled, labelled:
//   - The character lock (char[0x30]+4, 0x6808): OpenSRO holds no DB-job
//     lock on a character, so no request meets it.
//   - A filtered word in a notice (the filter s:0x7312f0 also refuses the
//     project's word list): only the quotes are refused, as the guild
//     notice does (guild.NoticeQuoteRefused).
//   - The shard manager's job queue: the store runs each job at once, so its
//     timeout 0x680e never happens; its store failures are answered 0x6813
//     (0x6813 / 0x6814 both print TC_ERROR_ORDER_WORK; which the shard picks
//     for which failure is OPEN).

import (
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/leveldata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/timedjob"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// AcademyDeps is what the academy needs.
type AcademyDeps struct {
	Store academy.Store
	Chars character.Store
	Hub   *world.Hub
	// Timed keeps the four penalties (timed jobs category 2, ids 7..10).
	Timed timedjob.Store
	// Guilds names a guardian's guild in the honor ranking (nil: none).
	Guilds guild.Store
	// Skills looks the honor rank's SKILL_TC_* buffs up by code (nil: the
	// buffs are not engaged).
	Skills interface {
		GetSkillByCode(ctx context.Context, code string) (*refdata.Skill, error)
	}
	Mana *mana.Tracker
	// Now is the clock (time.Now when nil); tests set a fake one.
	Now    func() time.Time
	Logger *slog.Logger
}

// academyRuntime is the academy's run-time state: the store's deps and what
// the game server holds of each member it has seen (fields 11-17 of its
// entry), which does not survive a restart (docs/protocol/academy.md 3).
type academyRuntime struct {
	AcademyDeps
	board *academy.Board

	mu      sync.Mutex
	live    map[int64]*acLive   // by CharID
	invites map[int64]*acInvite // by the invitee
	joins   map[int64]*acJoin   // by the requester (the matching board)
	// joinSeq numbers the board's join requests (the job id 0x747E down and
	// 0x347F carry; OURS: from 1, one counter per server).
	joinSeq uint32
}

// acLive is a member as this server last knew it.
type acLive struct {
	campID  int64
	live    academy.Live // its Display is filled in while inWorld
	inWorld bool
}

var academyRT atomic.Pointer[academyRuntime]

// SetAcademy installs the academy; nil deps.Store turns it off.
func SetAcademy(d AcademyDeps) {
	if d.Store == nil {
		academyRT.Store(nil)
		world.SetLevelHook(nil)
		return
	}
	academyRT.Store(&academyRuntime{AcademyDeps: d, board: academy.NewBoard(),
		live: map[int64]*acLive{}, invites: map[int64]*acInvite{}, joins: map[int64]*acJoin{}})
	world.SetLevelHook(academyLevelChanged)
}

func (rt *academyRuntime) now() time.Time {
	if rt.Now != nil {
		return rt.Now()
	}
	return time.Now().Add(time.Duration(academyClockOffset.Load()))
}

// academyClockOffset is how far /academytime has moved the academy's clock
// (OURS, a QA aid; 0 on a server nobody moved it on).
var academyClockOffset atomic.Int64

// AdvanceAcademyClock moves the academy's clock forward by d (the GM's
// /academytime) and returns the new academy time.
func AdvanceAcademyClock(d time.Duration) time.Time {
	academyClockOffset.Add(int64(d))
	if rt := academyRT.Load(); rt != nil {
		return rt.now()
	}
	return time.Now().Add(time.Duration(academyClockOffset.Load()))
}

func (rt *academyRuntime) log() *slog.Logger {
	if rt.Logger != nil {
		return rt.Logger
	}
	return slog.Default()
}

func acSend(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		logAcademyReply(sess, op, data)
		_ = sess.Send(&proto.Packet{Opcode: op, Data: data})
	}
}

// academyActorKey holds, on a session, the character its academy requests
// come from (round 866), so a reply's log line names it.
const academyActorKey = "academy.actor"

type academyActor struct {
	id   int64
	name string
}

// logAcademyReply logs, at INFO, every academy reply (0xB470..0xB483) and a
// joiner's 0x3C80 0a with its result and code (round 866: prod logged no
// academy request at all, so a player's report could not be followed).
func logAcademyReply(sess *gateway.Session, op uint16, data []byte) {
	result, code := -1, -1
	switch {
	case op >= proto.OpAcademyOpenAck && op <= proto.OpAcademyBuffTransferAck:
		if len(data) > 0 {
			result = int(data[0])
		}
		if result == int(academy.ResultFail) && len(data) >= 3 {
			code = int(binary.LittleEndian.Uint16(data[1:]))
		}
		if op == proto.OpAcademyMatchJoinAck && result == int(academy.ResultOK) && len(data) >= 2 {
			code = int(data[1]) // the join's state: 0 refused, 1 joined, 2 no reply
		}
	case op == proto.OpAcademyUpdate && len(data) >= 2 && data[0] == academy.PushJoin:
		result = int(data[1])
		if result == int(academy.ResultFail) && len(data) >= 4 {
			code = int(binary.LittleEndian.Uint16(data[2:]))
		}
	default:
		return
	}
	var who academyActor
	if v, ok := sess.Get(academyActorKey); ok {
		who, _ = v.(academyActor)
	} else if rt := academyRT.Load(); rt != nil && rt.Hub != nil {
		if e, ok := rt.Hub.EntityBySession(sess.ID()); ok {
			who = academyActor{id: e.CharacterID, name: e.Name}
		}
	}
	slog.Info("academy reply", "character_id", who.id, "name", who.name, "opcode", fmt.Sprintf("%#04x", op),
		"result", result, "code", fmt.Sprintf("%#04x", code))
}

func acFail(sess *gateway.Session, op uint16, code uint16) {
	acSend(sess, op, academy.EncodeFail(code))
}

// AcademyHandler answers the academy's requests.
func AcademyHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		rt := academyRT.Load()
		if rt == nil || rt.Hub == nil {
			return nil
		}
		switch p.Opcode {
		case proto.OpAcademyOpenRequest, proto.OpAcademyDisbandRequest, proto.OpAcademyInviteRequest,
			proto.OpAcademyBanRequest, proto.OpAcademyLeaveRequest, proto.OpAcademyGraduationRequest,
			proto.OpAcademyForceGradRequest, proto.OpAcademyNoticeRequest, proto.OpAcademyHonorRankRequest,
			proto.OpAcademyMatchEntry, proto.OpAcademyMatchCorrect, proto.OpAcademyMatchDelete,
			proto.OpAcademyMatchList, proto.OpAcademyMatchJoin, proto.OpAcademyMatchJoinAnswer,
			proto.OpAcademyBuffTransfer:
		default:
			return nil
		}
		e, ok := rt.Hub.EntityBySession(sess.ID())
		if !ok {
			return nil
		}
		sess.Set(academyActorKey, academyActor{id: e.CharacterID, name: e.Name})
		rt.log().Info("academy request", "character_id", e.CharacterID, "name", e.Name,
			"opcode", fmt.Sprintf("%#04x", p.Opcode), "len", len(p.Data))
		switch p.Opcode {
		case proto.OpAcademyOpenRequest:
			rt.handleOpen(ctx, sess, e, p.Data)
		case proto.OpAcademyDisbandRequest:
			rt.handleDisband(ctx, sess, e)
		case proto.OpAcademyInviteRequest:
			rt.handleInvite(ctx, sess, e, p.Data)
		case proto.OpAcademyBanRequest:
			rt.handleBan(ctx, sess, e, p.Data)
		case proto.OpAcademyLeaveRequest:
			rt.handleLeave(ctx, sess, e)
		case proto.OpAcademyGraduationRequest:
			rt.handleGraduate(ctx, sess, e, p.Data)
		case proto.OpAcademyForceGradRequest:
			rt.handleForceGraduate(ctx, sess, e, p.Data)
		case proto.OpAcademyNoticeRequest:
			rt.handleNotice(ctx, sess, e, p.Data)
		case proto.OpAcademyHonorRankRequest:
			rt.handleHonorRank(ctx, sess, e, p.Data)
		case proto.OpAcademyBuffTransfer:
			rt.handleBuffTransfer(ctx, sess, e)
		default:
			rt.handleBoard(ctx, sess, e, p)
		}
		return nil
	}
}

// --- helpers ------------------------------------------------------------------

// campOf is characterID's camp, nil for none.
func (rt *academyRuntime) campOf(ctx context.Context, characterID int64) *academy.Camp {
	c, err := rt.Store.CampOf(ctx, characterID)
	if err != nil {
		if !errors.Is(err, academy.ErrNotInCamp) {
			rt.log().Warn("academy: reading the camp failed", "character_id", characterID, "err", err)
		}
		return nil
	}
	return c
}

// storeCode is a store failure's refusal (the shard's own codes, section 11).
func storeCode(err error) uint16 {
	switch {
	case errors.Is(err, academy.ErrInCamp):
		return academy.ErrAlreadyInCamp
	case errors.Is(err, academy.ErrApprenticeFull):
		return ErrAcademyStudentsFull
	case errors.Is(err, academy.ErrAssistantsFull):
		return ErrAcademySecondFull
	case errors.Is(err, academy.ErrNoSuchCamp):
		return academy.InviteRefused
	}
	return ErrAcademyStoreFailed
}

// The codes this file sends besides internal/academy's.
const (
	ErrAcademyTargetBusy  uint16 = 0x6806
	ErrAcademyInviterGone uint16 = 0x680c
	// ErrAcademyRequesterGone: the shard's "requester not found"
	// (docs/protocol/academy.md 11; no text on the client).
	ErrAcademyRequesterGone uint16 = 0x680d
	ErrAcademyExisting      uint16 = 0x680f // TC_ERROR_TRAININGCAMP_ALREADY_ENTRY
	ErrAcademySecondFull    uint16 = 0x6810 // TC_ERROR_SECOND_GUARDIAN_COUNT_OVER
	ErrAcademyStoreFailed   uint16 = 0x6813
	ErrAcademyNotice        uint16 = 0x6817
	ErrAcademyEnterPenalty  uint16 = 0x681e // TC_ERROR_NOT_ENTRY_24T
	ErrAcademyJobDress      uint16 = 0x6823 // TC_ERROR_JOB_DRESS
	ErrAcademyNoPosition    uint16 = 0x6824 // TC_ERROR_NOT_POSITION
	ErrAcademyStudentsFull  uint16 = 0x6828 // TC_ERROR_STUDENT_COUNT_OVER
	ErrAcademyBanMatching   uint16 = 0x6829 // TC_BAN_MACHING_ERROR
	ErrAcademyCantGraduate  uint16 = 5
	ErrAcademyNPC           uint16 = 3
	ErrAcademyInviteMissing uint16 = 0
	ErrAcademyInviteFar     uint16 = 4
)

// npcStorage is the server NPC function the academy's NPC lines need: the
// storage keeper's id 3 (READ s:0x5190c4 `mov byte [esp+0x10],3` -> the NPC's
// function set lookup s:0x431790; npcspawn's WAREHOUSE rule gives {3, 1}).
const npcStorage byte = 3

// npcCheck is 0x7470's and 0x7478's NPC test (READ s:0x4e72a0 and its two
// callers): the NPC in reach (IsWithinInteractionRange, filter 0x146), the
// player in an interaction with it (s:0x4dd5d0 on the NPC's +0x1a0 set) and
// the NPC offering function 3; any failure answers 3 (s:0x519094 /
// s:0x519b02: a result other than 1 falls to `push 3`).
func npcCheck(sess *gateway.Session, e world.Entity, uid uint32) bool {
	pl, code := npcTarget(e, uid)
	if code != 0 || pl.npc == nil {
		return false
	}
	npcInteractions.mu.Lock()
	st, ok := npcInteractions.m[sess.ID()]
	talking := ok && st.entity == uid && (st.selected || st.mode != 0)
	npcInteractions.mu.Unlock()
	if !talking {
		return false
	}
	for _, id := range pl.npc.Interact {
		if id == npcStorage {
			return true
		}
	}
	return false
}

// toOnline sends data on op to every member of campID this server holds in
// the world, except except (0 none) -- CTrainingCamp::BroadcastToLocalMember
// (s:0x5de1e0).
func (rt *academyRuntime) toOnline(campID int64, op uint16, data []byte, except int64) {
	for _, id := range rt.onlineOf(campID) {
		if id == except {
			continue
		}
		if e, ok := entityOf(rt.Hub, id); ok {
			acSend(e.Session, op, data)
		}
	}
}

// push is a 0x3C80 to campID's online members.
func (rt *academyRuntime) push(campID int64, data []byte, except int64) {
	rt.toOnline(campID, proto.OpAcademyUpdate, data, except)
}

// onlineOf is campID's members in the world, by CharID.
func (rt *academyRuntime) onlineOf(campID int64) []int64 {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	var out []int64
	for id, l := range rt.live {
		if l.campID == campID && l.inWorld {
			out = append(out, id)
		}
	}
	return out
}

// penaltyLeft is the seconds left on characterID's penalty id (0 none).
func (rt *academyRuntime) penaltyLeft(ctx context.Context, characterID int64, id int) int64 {
	if rt.Timed == nil {
		return 0
	}
	jobs, err := rt.Timed.List(ctx, characterID)
	if err != nil {
		return 0
	}
	now := rt.now()
	for _, j := range jobs {
		if j.Type == timedjob.TypePenalty && j.Ref == int64(id) && now.Before(j.End) {
			return int64(math.Ceil(j.End.Sub(now).Seconds()))
		}
	}
	return 0
}

// penalize gives characterID penalty id for its length (section 8).
func (rt *academyRuntime) penalize(ctx context.Context, characterID int64, id int) {
	secs, ok := academy.PenaltySeconds(id)
	if !ok || rt.Timed == nil {
		return
	}
	now := rt.now()
	if err := rt.Timed.Put(ctx, timedjob.Job{CharID: characterID, Type: timedjob.TypePenalty, Ref: int64(id), Key: int64(id),
		Start: now, End: now.Add(time.Duration(secs) * time.Second)}); err != nil {
		rt.log().Warn("academy: the penalty was not saved", "character_id", characterID, "penalty", id, "err", err)
	}
}

// findByName is TrainingCamp_FindMemberByName (s:0x5e42c0): the name compared
// ignoring case, a name under 2 characters found as nobody.
func findByName(c *academy.Camp, name string) (academy.Member, bool) {
	if len(name) < 2 {
		return academy.Member{}, false
	}
	for _, m := range c.Members {
		if strings.EqualFold(m.Name, name) {
			return m, true
		}
	}
	return academy.Member{}, false
}

// joinerOf is the character e as a store Joiner. OpenSRO keeps no max level
// apart from the level (a character's level never falls here), so both are
// the level.
func (rt *academyRuntime) joinerOf(ctx context.Context, e world.Entity) academy.Joiner {
	j := academy.Joiner{CharID: e.CharacterID, Name: e.Name, CurLevel: e.Level, MaxLevel: e.Level}
	if rt.Chars != nil {
		if c, err := rt.Chars.GetByID(ctx, e.CharacterID); err == nil && c != nil {
			j.RefObjID = c.RefObjID
		}
	}
	return j
}

// --- 0x7470 open --------------------------------------------------------------

// handleOpen is TrainingCamp_HandleOpen (s:0x518fd0): CheckCanCreate first
// (dead 0x6807, level 0x6809, gold 0x680a, in a camp 0x6812, the reopen
// penalty 0x681c + u32 seconds), then the NPC (3), then the store; the fee
// is taken after the camp is stored (s:0x4e4650) and 0x304E goes out before
// 0xB470 (MEASURED), then the founder's 0x3C80 05 field 1 = 0.
func (rt *academyRuntime) handleOpen(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyOpenAck
	var gold int64
	if rt.Chars != nil {
		if c, err := rt.Chars.GetByID(ctx, e.CharacterID); err == nil && c != nil {
			gold = c.Gold
		}
	}
	left := rt.penaltyLeft(ctx, e.CharacterID, academy.PenaltyIDOpen)
	code := academy.CheckCreate(academy.CreateRequest{Alive: e.Life != world.LifeDead, Level: e.Level, Gold: gold,
		AlreadyInCamp: rt.campOf(ctx, e.CharacterID) != nil, WithinReopenCooldown: left > 0})
	if code == academy.ErrNotOpen7D {
		acSend(sess, op, academy.EncodeFailSeconds(academy.ErrNotOpen7D, uint32(left)))
		return
	}
	if code != 0 {
		acFail(sess, op, uint16(code))
		return
	}
	npc, err := academy.DecodeU32(data)
	if err != nil {
		return
	}
	if !npcCheck(sess, e, npc) {
		acFail(sess, op, ErrAcademyNPC)
		return
	}
	c, err := rt.Store.Found(ctx, rt.joinerOf(ctx, e), rt.now())
	if err != nil {
		acFail(sess, op, storeCode(err))
		return
	}
	// The fee (OffsetGold(-100000), s:0x4e4650). A balance that fell
	// meanwhile undoes the camp (OURS: the engine's OffsetGold cannot fail).
	if rt.Chars != nil {
		if err := rt.Chars.DeductGold(ctx, e.CharacterID, academy.FoundingGold); err != nil {
			_, _ = rt.Store.Disband(ctx, c.ID)
			acFail(sess, op, academy.ErrOpenGold)
			return
		}
		if ch, err := rt.Chars.GetByID(ctx, e.CharacterID); err == nil && ch != nil {
			acSend(sess, charmsg.OpCharInfo, charmsg.EncodeGold(ch.Gold, false))
		}
	}
	rt.attach(e, c.ID)
	acSend(sess, op, academy.EncodeCampOK(c, rt.liveOf))
	rt.setOnline(c.ID, e.CharacterID, true)
	rt.engageHonorBuffs(ctx, e.CharacterID, c.Rank)
	rt.log().Info("academy founded", "camp_id", c.ID, "character_id", e.CharacterID)
}

// --- 0x7471 disband -----------------------------------------------------------

// handleDisband is TrainingCamp_HandleDisband (s:0x519120): CheckCanDisband
// (dead 0x6807, no camp 3, not the guardian 0x6816 -- these on 0xB470,
// s:0x5191d0 -- and the window 0x681d + u32 seconds on 0xB471); then 0xB471
// {1}, 0x3C80 01 to every member, the guardian's honor buffs cancelled and
// the reopen penalty (2, 7) on it.
func (rt *academyRuntime) handleDisband(ctx context.Context, sess *gateway.Session, e world.Entity) {
	c := rt.campOf(ctx, e.CharacterID)
	r := academy.DisbandRequest{Alive: e.Life != world.LifeDead, InCamp: c != nil}
	if c != nil {
		m, ok := c.Member(e.CharacterID)
		r.HasMemberRecord, r.MemberClass = ok, m.Class
		r.SinceStamp = int64(rt.now().Sub(c.CreationDate) / time.Second)
	}
	code, left := academy.CheckDisband(r)
	switch {
	case code == academy.ErrNotDisorganization7D:
		acSend(sess, proto.OpAcademyDisbandAck, academy.EncodeFailSeconds(uint16(code), uint32(left)))
		return
	case code != 0:
		acFail(sess, proto.OpAcademyOpenAck, uint16(code))
		return
	}
	online := rt.onlineOf(c.ID)
	if _, err := rt.Store.Disband(ctx, c.ID); err != nil {
		acFail(sess, proto.OpAcademyDisbandAck, storeCode(err))
		return
	}
	acSend(sess, proto.OpAcademyDisbandAck, academy.EncodeOK())
	for _, id := range online {
		if o, ok := entityOf(rt.Hub, id); ok {
			acSend(o.Session, proto.OpAcademyUpdate, academy.EncodeDisbanded())
		}
	}
	rt.forgetCamp(c)
	rt.board.DropCamp(uint32(c.ID))
	rt.cancelHonorBuffs(e.CharacterID)
	rt.penalize(ctx, e.CharacterID, academy.PenaltyIDOpen)
	rt.log().Info("academy disbanded", "camp_id", c.ID, "character_id", e.CharacterID)
}

// --- 0x7472 invite and its 0x3080 answer --------------------------------------

type acInvite struct {
	inviter, target int64
	campID          int64
	timer           *time.Timer
}

// academyInviteTimeout is the invitation's wait (READ s:0xb45b48, 30.0f;
// MEASURED 30.4 s and 30.5 s).
var academyInviteTimeout = academy.InviteWaitSeconds * time.Second

// handleInvite is TrainingCamp_HandleInvite (s:0x519230), in its order (the
// inviter s:0x4e4800, the target's reach s:0x4a8e10, the role by the target's
// current level, the target s:0x4e4890); then 0x3080 kind 9 to the target
// and nothing to the inviter.
func (rt *academyRuntime) handleInvite(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyInviteAck
	uid, err := academy.DecodeU32(data)
	if err != nil {
		return
	}
	if e.Life == world.LifeDead {
		acFail(sess, op, academy.ErrDeadOrBusy)
		return
	}
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		acFail(sess, op, academy.InviteRefused)
		return
	}
	if m, ok := c.Member(e.CharacterID); !ok || m.Class != academy.MemberClassGuardian {
		acFail(sess, op, academy.ErrOrderWork)
		return
	}
	if int64(uid) == e.CharacterID {
		acFail(sess, op, academy.InviteRefused)
		return
	}
	if rt.penaltyLeft(ctx, e.CharacterID, academy.PenaltyIDInvite) > 0 {
		acFail(sess, op, academy.ErrNotInvite24T)
		return
	}
	// IsWithinInteractionRange(target, PC filter): not found 0, beyond 600
	// 4, not a player 3.
	if uid >= npcspawn.UIDBase {
		acFail(sess, op, academy.InviteRefused)
		return
	}
	t, ok := rt.Hub.EntityByCharacterID(int64(uid))
	if !ok || t.Zone != e.Zone {
		acFail(sess, op, ErrAcademyInviteMissing)
		return
	}
	dx, dy, dz := t.Pos.X-e.Pos.X, t.Pos.Y-e.Pos.Y, t.Pos.Z-e.Pos.Z
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > party.InviteRangePC {
		acFail(sess, op, ErrAcademyInviteFar)
		return
	}
	// The role by the target's CURRENT level (s:0x5192c4) and its cap.
	class, invitable := academy.InviteRole(t.Level)
	switch {
	case !invitable:
		acFail(sess, op, academy.InviteRefused)
		return
	case class == academy.MemberClassStudent && academy.RoleFull(class, c.Count(class)):
		acFail(sess, op, ErrAcademyStudentsFull)
		return
	case class == academy.MemberClassSecondGuardian && academy.RoleFull(class, c.Count(class)):
		acFail(sess, op, ErrAcademySecondFull)
		return
	}
	// CheckCanEnter on the target (s:0x4e4890).
	if code := rt.targetAvailable(ctx, c, t); code != 0 {
		acFail(sess, op, code)
		return
	}
	rt.mu.Lock()
	if _, pending := rt.invites[t.CharacterID]; pending {
		rt.mu.Unlock()
		acFail(sess, op, ErrAcademyTargetBusy)
		return
	}
	inv := &acInvite{inviter: e.CharacterID, target: t.CharacterID, campID: c.ID}
	inv.timer = time.AfterFunc(academyInviteTimeout, func() { rt.inviteTimedOut(inv) })
	rt.invites[t.CharacterID] = inv
	rt.mu.Unlock()
	acSend(t.Session, party.OpInvitation, academy.EncodeInvitation(uint32(e.CharacterID), e.Name))
}

// targetAvailable is TrainingCamp_CheckCanEnter (s:0x4e4890) for t: busy
// 0x6806 (an open NPC interaction or an exchange: OpenSRO's stand-ins for
// the lock bytes, as the guild's), dead 3, the entry penalties (2, 9) / (2,
// 10) 0x681e, in this camp 0x680f or another 0x6812; else 0.
func (rt *academyRuntime) targetAvailable(ctx context.Context, c *academy.Camp, t world.Entity) uint16 {
	if t.Session != nil && npcTalkOpen(t.Session.ID()) || tradeEstablishedOn(rt.Hub, t.CharacterID) {
		return ErrAcademyTargetBusy
	}
	if t.Life == world.LifeDead {
		return academy.InviteRefused
	}
	if rt.penaltyLeft(ctx, t.CharacterID, academy.PenaltyIDEnter) > 0 || rt.penaltyLeft(ctx, t.CharacterID, academy.PenaltyIDEnter3D) > 0 {
		return ErrAcademyEnterPenalty
	}
	if tc := rt.campOf(ctx, t.CharacterID); tc != nil {
		if c != nil && tc.ID == c.ID {
			return ErrAcademyExisting
		}
		return academy.ErrAlreadyInCamp
	}
	return 0
}

// takeInvite removes and returns target's pending invitation.
func (rt *academyRuntime) takeInvite(target int64) *acInvite {
	rt.mu.Lock()
	defer rt.mu.Unlock()
	inv := rt.invites[target]
	if inv != nil {
		delete(rt.invites, target)
		inv.timer.Stop()
	}
	return inv
}

// failInvite tells both sides: 0xB472 {2, code} to the inviter and 0x3C80
// {0a, 2, code} to the invitee (READ s:0x5e11b0; MEASURED for the timeout).
func (rt *academyRuntime) failInvite(inv *acInvite, code uint16) {
	if o, ok := entityOf(rt.Hub, inv.inviter); ok {
		acFail(o.Session, proto.OpAcademyInviteAck, code)
	}
	if o, ok := entityOf(rt.Hub, inv.target); ok {
		acSend(o.Session, proto.OpAcademyUpdate, academy.EncodeJoinFail(code))
	}
}

// inviteTimedOut is the 30 s with no answer: 0x000E both ways, in the same
// instant (MEASURED; the engine's 0x680e cut to its low byte, s:0x46cf0f).
func (rt *academyRuntime) inviteTimedOut(inv *acInvite) {
	rt.mu.Lock()
	if rt.invites[inv.target] != inv {
		rt.mu.Unlock()
		return
	}
	delete(rt.invites, inv.target)
	rt.mu.Unlock()
	rt.log().Info("academy invite timed out", "character_id", inv.target, "inviter", inv.inviter)
	rt.failInvite(inv, academy.ErrInviteTimeout)
}

// academyInviteAnswer takes the invitee's 0x3080 answer when an academy
// invitation waits for it (false otherwise): the server's order on the
// answer (s:0x5df910) -- the inviter gone 0x680c (to the invitee), a refusal
// (answer byte not 1) 0x6811 both ways, else the store adds the member and
// the join's sequence goes out (section 6).
func academyInviteAnswer(ctx context.Context, sess *gateway.Session, me world.Entity, data []byte) bool {
	rt := academyRT.Load()
	if rt == nil {
		return false
	}
	rt.mu.Lock()
	_, pending := rt.invites[me.CharacterID]
	rt.mu.Unlock()
	if !pending {
		return false
	}
	inv := rt.takeInvite(me.CharacterID)
	if inv == nil {
		return true
	}
	inviter, online := entityOf(rt.Hub, inv.inviter)
	if !online {
		acSend(sess, proto.OpAcademyUpdate, academy.EncodeJoinFail(ErrAcademyInviterGone))
		return true
	}
	accept := len(data) >= 2 && data[0] == 1 && data[1] == 1
	rt.log().Info("academy invite answered", "character_id", me.CharacterID, "name", me.Name, "inviter", inv.inviter,
		"accept", accept, "answer", fmt.Sprintf("% x", data))
	if !accept {
		rt.failInvite(inv, academy.ErrInviteRejection)
		return true
	}
	c, err := rt.Store.AddMember(ctx, inv.campID, rt.joinerOf(ctx, me), rt.now())
	if err != nil {
		rt.failInvite(inv, storeCode(err))
		return true
	}
	rt.announceJoin(ctx, c, me)
	rt.log().Info("academy joined", "camp_id", c.ID, "character_id", me.CharacterID, "inviter", inviter.CharacterID)
	return true
}

// announceJoin is the join's sequence (MEASURED, section 6): 0x3C80 02 with
// the new member's entry (play state 1, no place, no name) to the members
// already there, 0x3C80 {0a 01, CampInfo} to the joiner (its own entry with
// play state 1, its place and its name), 0x3C80 0d to the others, 0x3C80 05
// field 1 = 0 to all; a full camp leaves the matching board.
func (rt *academyRuntime) announceJoin(ctx context.Context, c *academy.Camp, joiner world.Entity) {
	m, _ := c.Member(joiner.CharacterID)
	rt.push(c.ID, academy.EncodeJoined(m, academy.Unplaced), joiner.CharacterID)
	rt.attach(joiner, c.ID)
	acSend(joiner.Session, proto.OpAcademyUpdate, academy.EncodeJoinOK(c, rt.liveOf))
	rt.sendPosition(c.ID, joiner.CharacterID)
	rt.setOnline(c.ID, joiner.CharacterID, true)
	if len(c.Members) >= 1+academy.MaxSecondGuardians+academy.MaxStudents {
		rt.board.DropCamp(uint32(c.ID))
	}
}

// --- 0x7473 ban, 0x7474 leave --------------------------------------------------

// handleBan is TrainingCamp_HandleBan (s:0x5193a0): CheckBan's order, then the
// shard's refusal of a camp on the matching board 0x6829 (m:0x456777, its
// text "To ban, you must first delete your matching registration."); then
// 0xB473 {1}, 0x3C80 {03, id, 2} to every member (the banned one included),
// and the invite penalty (2, 8) on the guardian when the banned member was an
// apprentice (s:0x5dfb3b).
func (rt *academyRuntime) handleBan(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyBanAck
	name, err := academy.DecodeName(data)
	if err != nil {
		return
	}
	c := rt.campOf(ctx, e.CharacterID)
	r := academy.BanRequest{InCamp: c != nil}
	var target academy.Member
	if c != nil {
		m, ok := c.Member(e.CharacterID)
		r.HasMemberRecord, r.MemberClass = ok, m.Class
		target, r.TargetFound = findByName(c, name)
		r.TargetIsCaller = target.CharID == e.CharacterID
		r.TargetSinceStamp = int64(rt.now().Sub(target.JoinDate) / time.Second)
	}
	if code := academy.CheckBan(r); code != 0 {
		acFail(sess, op, uint16(code))
		return
	}
	if _, listed := rt.listed(c.ID); listed {
		acFail(sess, op, ErrAcademyBanMatching)
		return
	}
	online := rt.onlineOf(c.ID)
	_, gone, err := rt.Store.RemoveMember(ctx, target.CharID, academy.RemoveBanned)
	if err != nil {
		acFail(sess, op, storeCode(err))
		return
	}
	acSend(sess, op, academy.EncodeOK())
	rt.removed(c.ID, online, gone.CharID, academy.RemoveBanned)
	if gone.Class == academy.MemberClassStudent {
		rt.penalize(ctx, e.CharacterID, academy.PenaltyIDInvite)
	}
	rt.log().Info("academy member banned", "camp_id", c.ID, "character_id", gone.CharID, "by", e.CharacterID)
}

// handleLeave is TrainingCamp_HandleLeave (s:0x519510): no camp 0x680b, the
// guardian 0x6816, no record 0x6815 (all on 0xB474), joined under 24 h ago
// 0x6821 on 0xB473 (MEASURED); then 0xB474 {1}, 0x3C80 {03, id, 1} to all,
// and the entry penalty (2, 9) on an apprentice, (2, 10) on an assistant.
func (rt *academyRuntime) handleLeave(ctx context.Context, sess *gateway.Session, e world.Entity) {
	c := rt.campOf(ctx, e.CharacterID)
	r := academy.LeaveRequest{InCamp: c != nil}
	var me academy.Member
	if c != nil {
		me, r.HasMemberRecord = c.Member(e.CharacterID)
		r.MemberClass = me.Class
		r.SinceStamp = int64(rt.now().Sub(me.JoinDate) / time.Second)
	}
	switch code := academy.CheckLeave(r); code {
	case 0:
	case academy.ErrNotOut24T:
		acFail(sess, proto.OpAcademyBanAck, uint16(code))
		return
	default:
		acFail(sess, proto.OpAcademyLeaveAck, uint16(code))
		return
	}
	online := rt.onlineOf(c.ID)
	if _, _, err := rt.Store.RemoveMember(ctx, e.CharacterID, academy.RemoveLeft); err != nil {
		acFail(sess, proto.OpAcademyLeaveAck, storeCode(err))
		return
	}
	acSend(sess, proto.OpAcademyLeaveAck, academy.EncodeOK())
	rt.removed(c.ID, online, e.CharacterID, academy.RemoveLeft)
	switch me.Class {
	case academy.MemberClassStudent:
		rt.penalize(ctx, e.CharacterID, academy.PenaltyIDEnter)
	case academy.MemberClassSecondGuardian:
		rt.penalize(ctx, e.CharacterID, academy.PenaltyIDEnter3D)
	}
	rt.log().Info("academy member left", "camp_id", c.ID, "character_id", e.CharacterID)
}

// removed tells online (the camp's members in the world before the removal)
// 0x3C80 {03, id, reason} and forgets the member's run-time state.
func (rt *academyRuntime) removed(campID int64, online []int64, charID int64, reason int) {
	msg := academy.EncodeRemoved(charID, reason)
	for _, id := range online {
		if o, ok := entityOf(rt.Hub, id); ok {
			acSend(o.Session, proto.OpAcademyUpdate, msg)
		}
	}
	rt.forget(charID)
}

// --- 0x7475 / 0x7476 graduation -----------------------------------------------

// handleGraduate is TrainingCamp_HandleGraduation (s:0x519600): no camp
// 0x680b, the guardian 5, no record 0x6815, the live max level under 40
// (apprentice) / 60 (assistant) 0x681a; the evaluation read after that, an
// apprentice's above 4 refused 5; then the graduation (self).
func (rt *academyRuntime) handleGraduate(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyGraduationAck
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		acFail(sess, op, academy.ErrNoCamp)
		return
	}
	m, ok := c.Member(e.CharacterID)
	if ok && m.Class == academy.MemberClassGuardian {
		acFail(sess, op, ErrAcademyCantGraduate)
		return
	}
	if !ok {
		acFail(sess, op, academy.ErrOrderWorkNoMember)
		return
	}
	floor, _ := academy.SelfGraduationLevel(m.Class)
	if e.Level < floor {
		acFail(sess, op, academy.ErrGraduationLevel)
		return
	}
	points := 0
	if m.Class == academy.MemberClassStudent {
		eval, err := academy.DecodeU8(data)
		if err != nil {
			return
		}
		if int(eval) >= len(academy.EvaluationPoints) {
			acFail(sess, op, ErrAcademyCantGraduate)
			return
		}
		points = academy.EvaluationPoints[eval]
	}
	rt.graduate(ctx, sess, op, c, m, points, true)
}

// handleForceGraduate is the guardian's 0x7476 (s:0x519770): no camp 0x680b,
// not the guardian 0x6816, not found 0x6815, itself 5, the member's STORED
// max level at most 40 (apprentice) / 60 (assistant) 0x6822; then the
// graduation with the points value 1 (s:0x5198a7) and no exp.
func (rt *academyRuntime) handleForceGraduate(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyForceGradAck
	name, err := academy.DecodeName(data)
	if err != nil {
		return
	}
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		acFail(sess, op, academy.ErrNoCamp)
		return
	}
	if me, ok := c.Member(e.CharacterID); !ok || me.Class != academy.MemberClassGuardian {
		acFail(sess, op, academy.ErrOrderWork)
		return
	}
	m, ok := findByName(c, name)
	if !ok {
		acFail(sess, op, academy.ErrOrderWorkNoMember)
		return
	}
	if m.CharID == e.CharacterID {
		acFail(sess, op, ErrAcademyCantGraduate)
		return
	}
	if !academy.MeetsMembershipLevel(m.Class, m.MaxLevel) {
		acFail(sess, op, academy.ErrMembershipLevel)
		return
	}
	rt.graduate(ctx, sess, op, c, m, 1, false)
}

// graduate stores the graduation and sends it (section 7.6): the reply {1}
// to the requester, 0x3C80 {04, id, kind} to every member (the graduate
// included), the exp of a self-graduating apprentice, the honor shares as
// 0x3C80 {05, id, 03, total} to all.
func (rt *academyRuntime) graduate(ctx context.Context, sess *gateway.Session, op uint16, c *academy.Camp, m academy.Member, points int, self bool) {
	online := rt.onlineOf(c.ID)
	after, g, err := rt.Store.Graduate(ctx, m.CharID, points, rt.now())
	if err != nil {
		acFail(sess, op, storeCode(err))
		return
	}
	acSend(sess, op, academy.EncodeOK())
	var kind byte
	if self {
		kind = 1
	}
	msg := academy.EncodeGraduated(m.CharID, kind)
	for _, id := range online {
		if o, ok := entityOf(rt.Hub, id); ok {
			acSend(o.Session, proto.OpAcademyUpdate, msg)
		}
	}
	rt.forget(m.CharID)
	if self && m.Class == academy.MemberClassStudent {
		if o, ok := entityOf(rt.Hub, m.CharID); ok {
			rt.giveExp(ctx, o, academy.GraduationExp)
		}
	}
	for _, s := range g.Shares {
		rt.push(after.ID, academy.EncodeFieldU32(s.CharID, academy.FieldHonor, uint32(s.Honor)), 0)
	}
	rt.log().Info("academy graduation", "camp_id", c.ID, "character_id", m.CharID, "self", self, "points", points)
}

// giveExp is GObjPC_GainExpAndLevel (vtable 0x170) for exp: the level-ups it
// makes and the 0x3056 notice, as a quest's reward pays it (quest.go
// payExp).
func (rt *academyRuntime) giveExp(ctx context.Context, e world.Entity, exp int64) {
	if levelTable == nil || !levelTable.Loaded() || rt.Chars == nil || exp <= 0 {
		return
	}
	id := e.CharacterID
	unlock := character.LockLeveling(id)
	char, err := rt.Chars.GetByID(ctx, id)
	if err != nil {
		unlock()
		return
	}
	newLevel, newExp, gained := levelTable.Advance(char.Level, char.Exp, exp)
	newStatPoints := char.StatPoints + gained*leveldata.StatPointsPerLevel
	newStr := char.Str + gained*character.StatGrowthPerLevel
	newInt := char.Int + gained*character.StatGrowthPerLevel
	if err := rt.Chars.SetLeveling(ctx, id, newLevel, newExp, newStatPoints, newStr, newInt); err != nil {
		unlock()
		rt.log().Warn("academy: paying the graduation exp failed", "character_id", id, "err", err)
		return
	}
	var lu *LevelUp
	if gained > 0 {
		rt.Hub.SetLevel(id, newLevel)
		rt.Chars.ResetHP(ctx, id)
		if rt.Mana != nil {
			rt.Mana.Refill(id, character.MaxMPWith(newInt, newLevel, character.BonusOf(id)))
		}
		lu = &LevelUp{NewLevel: int32(newLevel), StatPoints: int32(newStatPoints)}
	}
	unlock()
	g := charmsg.ExpGain{Exp: exp}
	if lu != nil {
		announceLevelUp(rt.Hub, id)
		acSend(e.Session, OpLevelUp, lu.Encode())
		g.LevelUp = true
		g.StatPoints = uint16(lu.StatPoints)
	}
	sendExpGainTo(e.Session, g)
}

// --- 0x7477 notice ------------------------------------------------------------

// The notice's lengths (READ s:0x5df070).
const (
	academyNoticeTitleMax   = 128
	academyNoticeContentMax = 2048
)

// handleNotice is HandleNoticeUpdate (s:0x519900) then s:0x5df070: a chat
// ban drops it with 0x3405; not the guardian 0x6816; a quote drops it with
// no reply; dead 0x6807; no camp 0x680b; not the guardian 0x6816; the lengths
// 0x6817; then 0x3C80 07 to every member (the writer included) and 0xB477
// {1} to the writer (MEASURED order).
func (rt *academyRuntime) handleNotice(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyNoticeAck
	title, content, err := academy.DecodeNotice(data)
	if err != nil {
		return
	}
	if restricted(ctx, sess, RestrictChat) {
		return
	}
	c := rt.campOf(ctx, e.CharacterID)
	isGuardian := false
	if c != nil {
		m, ok := c.Member(e.CharacterID)
		isGuardian = ok && m.Class == academy.MemberClassGuardian
	}
	// TrainingCamp_IsMemberClass0 answers 0 for no camp too (READ s:0x519900:
	// the test precedes the string reads), so a non-member is refused 0x6816
	// here and the job's own 0x680b below is not reached by it.
	if !isGuardian {
		acFail(sess, op, academy.ErrOrderWork)
		return
	}
	if guild.NoticeQuoteRefused(title) || guild.NoticeQuoteRefused(content) {
		return
	}
	if e.Life == world.LifeDead {
		acFail(sess, op, academy.ErrDeadOrBusy)
		return
	}
	if c == nil {
		acFail(sess, op, academy.ErrNoCamp)
		return
	}
	if !isGuardian {
		acFail(sess, op, academy.ErrOrderWork)
		return
	}
	if len(title) < 1 || len(title) > academyNoticeTitleMax || len(content) < 1 || len(content) > academyNoticeContentMax {
		acFail(sess, op, ErrAcademyNotice)
		return
	}
	if err := rt.Store.SetNotice(ctx, c.ID, title, content); err != nil {
		acFail(sess, op, storeCode(err))
		return
	}
	rt.push(c.ID, academy.EncodeNotice(title, content), 0)
	acSend(sess, op, academy.EncodeOK())
}

// --- 0x7478 honor rank list ---------------------------------------------------

// handleHonorRank is s:0x519ad0: the NPC (3), then 0xB478 {1, n, rows} from
// the stored ranking. OURS: every camp counts as loaded on this one server
// (the original lists only camps loaded on its game server, s:0x5e17f0).
func (rt *academyRuntime) handleHonorRank(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) {
	const op = proto.OpAcademyHonorRankAck
	npc, err := academy.DecodeU32(data)
	if err != nil {
		return
	}
	if !npcCheck(sess, e, npc) {
		acFail(sess, op, ErrAcademyNPC)
		return
	}
	acSend(sess, op, academy.EncodeHonorList(rt.honorRows(ctx)))
}

// honorRows is the ranking as 0xB478's rows.
func (rt *academyRuntime) honorRows(ctx context.Context) []academy.HonorRow {
	ranking, err := rt.Store.Ranking(ctx)
	if err != nil {
		return nil
	}
	var rows []academy.HonorRow
	for _, r := range ranking {
		c, err := rt.Store.Get(ctx, r.CampID)
		if err != nil {
			continue
		}
		g, ok := c.Guardian()
		if !ok {
			continue
		}
		row := academy.HonorRow{Ranking: uint32(r.Ranking), Rank: byte(r.Rank), Guardian: g.Name,
			CurLevel: byte(g.CurLevel), MaxLevel: byte(g.MaxLevel), GraduateCount: uint32(c.GraduateCount)}
		if rt.Guilds != nil {
			if gd, err := rt.Guilds.GetByCharacter(ctx, g.CharID); err == nil && gd != nil {
				row.GuildName = gd.Name
			}
		}
		rows = append(rows, row)
	}
	return rows
}

// --- 0x7483 cumulated buff transfer --------------------------------------------

// handleBuffTransfer is s:0x519d40 (READ): a member other than the guardian,
// its slot-0 row started at least 60 minutes ago, the camp's guardian online
// -- offline answers 0xB483 {2} (UIIT_MSG_TC_PASS_ERROR). OPEN: what a
// transfer to an online guardian moves and 0xB483's layout for it
// (s:0x4e4580), so nothing is sent then.
func (rt *academyRuntime) handleBuffTransfer(ctx context.Context, sess *gateway.Session, e world.Entity) {
	c := rt.campOf(ctx, e.CharacterID)
	if c == nil {
		return
	}
	m, ok := c.Member(e.CharacterID)
	if !ok || m.Class == academy.MemberClassGuardian {
		return
	}
	rows, _ := rt.Store.BuffRows(ctx, e.CharacterID)
	started := false
	for _, b := range rows {
		if b.Type == 0 && b.Slot == 0 && rt.now().Sub(b.Start) >= 60*time.Minute {
			started = true
		}
	}
	g, hasGuardian := c.Guardian()
	if !started || !hasGuardian {
		return
	}
	if _, online := entityOf(rt.Hub, g.CharID); !online {
		acSend(sess, proto.OpAcademyBuffTransferAck, []byte{academy.ResultFail})
		return
	}
	rt.log().Info("academy: buff transfer to an online guardian is OPEN; not sent", "character_id", e.CharacterID)
}
