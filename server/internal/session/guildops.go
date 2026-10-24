package session

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The original's guild membership requests (round 822, READ: docs/protocol/
// guild.md, "Requests and replies"): create 0x70F0, disband 0x70F1, leave
// 0x70F2, invite 0x70F3 (the invitee's 0x3080 answer), expel 0x70F4, and the
// members' 0x38F5 updates. The ShardManager's jobs are direct store calls
// here (one process).

// guildNPCInteraction is the guild manager's interaction id (0x0f): the
// create and disband handlers ask HasAvailableInteraction(npc, 0xf)
// (s:0x514ce0, s:0x515340).
const guildNPCInteraction = 0x0f

// guildNPCInReach is FUN_004e72a0(npc) == 1 and HasAvailableInteraction(npc,
// 0xf): the NPC the request names is in reach and is a guild manager.
func guildNPCInReach(e world.Entity, npc uint32) bool {
	pl, code := npcTarget(e, npc)
	if code != 0 || pl.npc == nil {
		return false
	}
	for _, id := range pl.npc.Interact {
		if id == guildNPCInteraction {
			return true
		}
	}
	return false
}

// guildOpsDeps is what the handlers need (GuildHandler sets it).
type guildOpsDeps struct {
	chars  character.Store
	guilds guild.Store
	hub    *world.Hub
}

// guildJoinGate answers whether an account may use OpenSRO's own join-by-id
// (OpGuildJoin, round 525): since round 822 a GM account only (the QA bots),
// the original having no such request -- members come by invitation.
var guildJoinGate atomic.Pointer[func(username string) bool]

// SetGuildJoinGate names it (main passes the GM gate); nil refuses all.
func SetGuildJoinGate(allow func(username string) bool) {
	if allow == nil {
		guildJoinGate.Store(nil)
		return
	}
	guildJoinGate.Store(&allow)
}

func guildJoinAllowed(sess *gateway.Session) bool {
	g := guildJoinGate.Load()
	if g == nil {
		return false
	}
	name, _ := AuthenticatedUsername(sess)
	return (*g)(name)
}

func sendGuild(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		_ = sess.Send(&proto.Packet{Opcode: op, Data: data})
	}
}

// guildLive is a member's level, model and presence.
func (d guildOpsDeps) guildLive(ctx context.Context, characterID int64) guild.MemberLive {
	var l guild.MemberLive
	if d.chars != nil {
		if c, err := d.chars.GetByID(ctx, characterID); err == nil && c != nil {
			l.Level = uint8(min(max(c.Level, 0), 255))
			l.RefObjID, _ = modelOf(c)
		}
	}
	_, l.Online = entityOf(d.hub, characterID)
	return l
}

// toMembers sends op/data to every member of g in the world but `skip`.
func (d guildOpsDeps) toMembers(g *guild.Guild, op uint16, data []byte, skip int64) {
	if g == nil || d.hub == nil {
		return
	}
	for _, m := range g.Members {
		if m.CharacterID == skip {
			continue
		}
		if e, ok := entityOf(d.hub, m.CharacterID); ok {
			sendGuild(e.Session, op, data)
		}
	}
}

// penalize gives characterID the guild penalty from now.
func (d guildOpsDeps) penalize(ctx context.Context, characterID int64) {
	if err := d.guilds.SetPenalty(ctx, characterID, time.Now().Add(guild.PenaltyDuration)); err != nil {
		slog.Warn("guild penalty not saved", "character_id", characterID, "err", err)
	}
}

// penaltyLeft is the guild penalty characterID still has (0 none).
func (d guildOpsDeps) penaltyLeft(ctx context.Context, characterID int64) time.Duration {
	until, err := d.guilds.PenaltyUntil(ctx, characterID)
	if err != nil || until.IsZero() {
		return 0
	}
	if left := time.Until(until); left > 0 {
		return left
	}
	return 0
}

// --- create (0x70F0) ---------------------------------------------------------

// handleRetailGuildCreate is CGuildManager::HandleCreateGuild (s:0x514ce0,
// READ): the founder's checks (FUN_00514b20: dead 0x4c07, level 0x4c0a,
// gold 0x4c0c, job 0x4c57, the penalty 0x4c3c with its seconds, in a guild
// 0x4c17), the guild manager in reach (else 3), the name 2..12 bytes
// (0x4c18), the name filter 0x4c19, a name taken 0x4c1a; then the guild, the
// fee, 0xB0F0 {1, the block} and the founder's guild line.
func handleRetailGuildCreate(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if len(p.Data) < 6 {
		return nil
	}
	npc := binary.LittleEndian.Uint32(p.Data)
	n := int(binary.LittleEndian.Uint16(p.Data[4:]))
	if len(p.Data) < 6+n {
		return nil
	}
	name := string(p.Data[6 : 6+n])
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpCreateResult, guild.EncodeFail(code))
		return nil
	}
	founder, err := d.chars.GetByID(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	if err := guild.CheckCreator(founder.HP > 0 && !deadBySession(d.hub, sess), founder.Level, founder.Gold); err != nil {
		switch {
		case errors.Is(err, guild.ErrCreatorDead):
			return fail(0x4c07)
		case errors.Is(err, guild.ErrCreatorLevelTooLow):
			return fail(0x4c0a)
		default:
			return fail(0x4c0c)
		}
	}
	if inJobMode(ctx, e.CharacterID) {
		return fail(0x4c57)
	}
	if left := d.penaltyLeft(ctx, e.CharacterID); left > 0 {
		sendGuild(sess, guild.OpCreateResult, guild.EncodeCreatePenalty(uint32(left/time.Second)))
		return nil
	}
	if _, err := d.guilds.GuildIDOf(ctx, e.CharacterID); err == nil {
		return fail(guild.CodeOtherGuild)
	}
	if !guildNPCInReach(e, npc) {
		return fail(guild.CodeNotInRange)
	}
	if !guild.ValidName(name) {
		return fail(0x4c18)
	}
	if !NameFilter().NameOK(name) {
		return fail(0x4c19)
	}
	g, err := d.guilds.Create(ctx, name, e.CharacterID, e.Name)
	if err != nil {
		switch {
		case errors.Is(err, guild.ErrNameTaken):
			return fail(0x4c1a)
		case errors.Is(err, guild.ErrAlreadyInGuild):
			return fail(guild.CodeOtherGuild)
		case errors.Is(err, guild.ErrInvalidNameLength):
			return fail(0x4c18)
		}
		return fail(0x4c1b) // GUILDERR_CANT_CREATE_GUILD_IN_DB
	}
	// The fee on the job's reply (trs_sm_guildjob::FUN_005c8bf0 ->
	// OffsetGold(-500000)); a fee no longer there takes the guild down.
	if err := d.chars.DeductGold(ctx, e.CharacterID, guild.CreateGoldRequired); err != nil {
		if _, derr := d.guilds.Disband(context.WithoutCancel(ctx), g.ID); derr != nil {
			slog.Warn("guild founded but neither paid for nor rolled back", "character_id", e.CharacterID, "guild_id", g.ID, "err", derr)
		}
		return fail(0x4c0c)
	}
	tellGold(ctx, d.chars, d.hub, e.CharacterID, true)
	block := guild.EncodeBlock(g, func(id int64) guild.MemberLive { return d.guildLive(ctx, id) })
	sendGuild(sess, guild.OpCreateResult, guild.EncodeCreateOK(block))
	refreshGuildPlate(d.hub, e.CharacterID, g)
	return nil
}

// --- disband (0x70F1) --------------------------------------------------------

// handleGuildDisband is s:0x515340 -> 0x5c6870 (READ): no guild, nothing; not
// the master 0x4c1e; the guild manager not in reach 3; at war 0x4c46 and the
// storage in use 0x4c48 (OpenSRO has neither yet); then 0xB0F1 {1}, 0x38F5
// type 1 to every member in the world, and the master's penalty
// (s:0x5c8b3d).
func handleGuildDisband(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if len(p.Data) < 4 {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	if g.LeaderID != e.CharacterID {
		sendGuild(sess, guild.OpDisbandResult, guild.EncodeFail(guild.CodePermissionDenied))
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(p.Data)) {
		sendGuild(sess, guild.OpDisbandResult, guild.EncodeFail(guild.CodeNotInRange))
		return nil
	}
	was, err := d.guilds.Disband(ctx, g.ID)
	if err != nil {
		sendGuild(sess, guild.OpDisbandResult, guild.EncodeFail(guild.CodePermissionDenied))
		return nil
	}
	sendGuild(sess, guild.OpDisbandResult, guild.EncodeOK())
	d.toMembers(was, guild.OpUpdate, guild.EncodeDisbanded(), 0)
	d.penalize(ctx, e.CharacterID)
	for _, m := range was.Members {
		refreshGuildPlate(d.hub, m.CharacterID, nil)
	}
	slog.Info("guild disbanded", "guild_id", was.ID, "name", was.Name, "master", e.CharacterID)
	return nil
}

// --- leave (0x70F2) and expel (0x70F4) ---------------------------------------

// handleRetailGuildLeave is s:0x515070 -> 0x5c60b0(.., 1) (READ): no guild,
// nothing; the NPC out of reach 3; the master, nothing at all (the handler
// returns before the job); then 0xB0F2 {1} to the leaver, 0x38F5 type 3 {id,
// 1} to the members in the world (the leaver too: its client clears its
// guild), its line dropped, and its penalty (s:0x5c3f94).
func handleRetailGuildLeave(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if len(p.Data) < 4 {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	if _, code := npcTarget(e, binary.LittleEndian.Uint32(p.Data)); code != 0 {
		sendGuild(sess, guild.OpLeaveResult, guild.EncodeFail(guild.CodeNotInRange))
		return nil
	}
	if g.LeaderID == e.CharacterID {
		return nil
	}
	return d.removeMember(ctx, g, e.CharacterID, guild.RemovedLeft, sess, guild.OpLeaveResult)
}

// handleGuildExpel is s:0x5151d0 -> 0x5c60b0(.., 2) (READ): no guild,
// nothing; without the expel bit 0x4c1e; a name no member has, nothing; the
// expeller themself 0x4c36; the master 0x4c1f; then 0xB0F4 {1}, 0x38F5 type
// 3 {id, 2} to the members in the world (the expelled one too) and the
// expelled one's penalty.
func handleGuildExpel(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if len(p.Data) < 2 {
		return nil
	}
	n := int(binary.LittleEndian.Uint16(p.Data))
	if len(p.Data) < 2+n {
		return nil
	}
	name := string(p.Data[2 : 2+n])
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	if !memberPerm(g, e.CharacterID).Has(guild.PermExpel) {
		sendGuild(sess, guild.OpExpelResult, guild.EncodeFail(guild.CodePermissionDenied))
		return nil
	}
	var target *guild.Member
	for i := range g.Members {
		if strings.EqualFold(g.Members[i].Name, name) {
			target = &g.Members[i]
			break
		}
	}
	if target == nil {
		return nil
	}
	if target.CharacterID == e.CharacterID {
		sendGuild(sess, guild.OpExpelResult, guild.EncodeFail(guild.CodeExpelSelf))
		return nil
	}
	if target.CharacterID == g.LeaderID {
		sendGuild(sess, guild.OpExpelResult, guild.EncodeFail(guild.CodeMasterCannot))
		return nil
	}
	return d.removeMember(ctx, g, target.CharacterID, guild.RemovedExpelled, sess, guild.OpExpelResult)
}

// removeMember takes characterID out of g and tells everyone: the asker's
// reply {1} on replyOp, 0x38F5 type 3 to the members in the world before
// the removal (so the one going hears it), the line dropped, the penalty.
func (d guildOpsDeps) removeMember(ctx context.Context, g *guild.Guild, characterID int64, reason byte, sess *gateway.Session, replyOp uint16) error {
	after, err := d.guilds.Remove(ctx, characterID)
	if err != nil {
		code := guild.CodeCantFindMember
		if errors.Is(err, guild.ErrIsMaster) {
			code = guild.CodeMasterCannot
		}
		sendGuild(sess, replyOp, guild.EncodeFail(code))
		return nil
	}
	sendGuild(sess, replyOp, guild.EncodeOK())
	d.toMembers(g, guild.OpUpdate, guild.EncodeMemberRemoved(characterID, reason), 0)
	refreshGuildPlate(d.hub, characterID, nil)
	d.penalize(ctx, characterID)
	_ = after
	return nil
}

// memberPerm is characterID's permission in g (none for a non-member).
func memberPerm(g *guild.Guild, characterID int64) guild.Permission {
	for _, m := range g.Members {
		if m.CharacterID == characterID {
			return m.Permission
		}
	}
	return 0
}

// --- invite (0x70F3) and its answer (0x3080) --------------------------------

// guildInvite is one invitation waiting for its answer (the request
// trs_wait_response, 30 s: party.InviteTimeout's float).
type guildInvite struct {
	inviter, target int64
	guildID         int64
	timer           *time.Timer
}

var guildInvites = struct {
	mu sync.Mutex
	m  map[int64]*guildInvite // by target
}{m: map[int64]*guildInvite{}}

// guildInviteTimeout is the invitation's wait (READ: the same request
// wrapper as the party's, 0x46c7e0, whose 30.0 is party.InviteTimeout).
var guildInviteTimeout = party.InviteTimeout

// handleGuildInvite is GObjPC_HandleGuildMemberAddMsg_0f3 (s:0x514f10, READ):
// no guild, nothing; without the invite bit 0x4c1e; the inviter themself,
// nothing; a full guild 0x4c13; the target out of reach (600, the request's
// PC range) or not a player 3; then the target (s:0x514c40): locked or busy
// 0x4c06, dead 3, the penalty 0x4c3d, in this guild 0x4c12 or another
// 0x4c17, in a job suit 0x4c56; then 0x3080 {5, inviter} to the target and
// nothing to the inviter. Each refusal is 0xB0F3 {2, code}.
func handleGuildInvite(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if len(p.Data) < 4 {
		return nil
	}
	targetUID := binary.LittleEndian.Uint32(p.Data)
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpInviteResult, guild.EncodeFail(code))
		return nil
	}
	if !memberPerm(g, e.CharacterID).Has(guild.PermInvite) {
		return fail(guild.CodePermissionDenied)
	}
	if int64(targetUID) == e.CharacterID {
		return nil
	}
	if len(g.Members) >= guild.MaxMembersFor(g.Level) {
		return fail(guild.CodeGuildFull)
	}
	t, code := (PartyDeps{Hub: d.hub}).reachTarget(e, targetUID)
	if code != 1 {
		return fail(guild.CodeNotInRange)
	}
	if code := d.targetAvailable(ctx, e, g, t); code != 1 {
		return fail(code)
	}
	guildInvites.mu.Lock()
	if _, pending := guildInvites.m[t.CharacterID]; pending {
		guildInvites.mu.Unlock()
		return fail(guild.CodeTargetBusy)
	}
	inv := &guildInvite{inviter: e.CharacterID, target: t.CharacterID, guildID: g.ID}
	inv.timer = time.AfterFunc(guildInviteTimeout, func() { d.inviteTimedOut(inv) })
	guildInvites.m[t.CharacterID] = inv
	guildInvites.mu.Unlock()
	sendGuild(t.Session, guild.OpRequest, guild.EncodeInvitation(uint32(e.CharacterID)))
	return nil
}

// targetAvailable is FUN_00514c40 for t (READ): busy 0x4c06 (an open NPC
// interaction; OpenSRO has no character lock), dead 3, the penalty 0x4c3d,
// in a guild 0x4c12 (this one) or 0x4c17, in a job suit 0x4c56; else 1.
func (d guildOpsDeps) targetAvailable(ctx context.Context, inviter world.Entity, g *guild.Guild, t world.Entity) uint16 {
	if npcTalkOpen(t.Session.ID()) || tradeEstablishedOn(d.hub, t.CharacterID) {
		return guild.CodeTargetBusy
	}
	if t.Life == world.LifeDead {
		return guild.CodeNotInRange
	}
	if d.penaltyLeft(ctx, t.CharacterID) > 0 {
		return guild.CodeJoinPenalty
	}
	if tg, err := d.guilds.GuildIDOf(ctx, t.CharacterID); err == nil {
		if tg == g.ID {
			return guild.CodeExistingMember
		}
		return guild.CodeOtherGuild
	}
	if inJobMode(ctx, t.CharacterID) {
		return guild.CodeJoinJob
	}
	return 1
}

// takeGuildInvite removes and returns target's pending invitation.
func takeGuildInvite(target int64) *guildInvite {
	guildInvites.mu.Lock()
	defer guildInvites.mu.Unlock()
	inv := guildInvites.m[target]
	if inv != nil {
		delete(guildInvites.m, target)
		inv.timer.Stop()
	}
	return inv
}

// failInvite tells both sides (trs_wait_response::FUN_005ccbd0, READ): 0xB0F3
// {2, code} to the inviter (clearing its request lock) and 0xB0F8 {2, code}
// to the invitee (0x4c10 closes its question box).
func (d guildOpsDeps) failInvite(inv *guildInvite, code uint16) {
	if e, ok := entityOf(d.hub, inv.inviter); ok {
		sendGuild(e.Session, guild.OpInviteResult, guild.EncodeFail(code))
	}
	if e, ok := entityOf(d.hub, inv.target); ok {
		sendGuild(e.Session, guild.OpJoinResult, guild.EncodeFail(code))
	}
}

// inviteTimedOut is the 30 s with no answer: 0x4c10 to both
// (trs_wait_response::OnTimeout, kinds 5, 6 and 10, READ 0x46ce51).
func (d guildOpsDeps) inviteTimedOut(inv *guildInvite) {
	guildInvites.mu.Lock()
	if guildInvites.m[inv.target] != inv {
		guildInvites.mu.Unlock()
		return
	}
	delete(guildInvites.m, inv.target)
	guildInvites.mu.Unlock()
	d.failInvite(inv, guild.CodeInviteTimeout)
}

// guildOps is the handlers' state, set by GuildHandler (the 0x3080 answer
// arrives through PartyHandler and is offered here first).
var guildOps atomic.Pointer[guildOpsDeps]

// guildInviteAnswer takes the invitee's 0x3080 answer when a guild
// invitation is waiting for it; false when none is (the answer is someone
// else's). A refusal fails both sides with its code (0x4c16); an
// acceptance joins: the guild is checked again (full 0x4c13, gone 0x4c1d),
// the member added, its block sent to it (s:0x5c8d40) and its line to those
// who see it, and 0x38F5 type 2 (its record) then type 6 (online: the
// "[%s] has joined your guild" line) to the members in the world.
func guildInviteAnswer(ctx context.Context, sess *gateway.Session, me world.Entity, data []byte) bool {
	d := guildOps.Load()
	if d == nil {
		return false
	}
	guildInvites.mu.Lock()
	_, pending := guildInvites.m[me.CharacterID]
	guildInvites.mu.Unlock()
	if !pending {
		return false
	}
	accept, ok := guild.DecodeAnswer(data)
	if !ok {
		return true
	}
	inv := takeGuildInvite(me.CharacterID)
	if inv == nil {
		return true
	}
	if !accept {
		code := guild.CodeJoinRefused
		if len(data) >= 3 && data[0] == 2 {
			code = binary.LittleEndian.Uint16(data[1:])
		}
		d.failInvite(inv, code)
		return true
	}
	g, err := d.guilds.Get(ctx, inv.guildID)
	if err != nil {
		d.failInvite(inv, guild.CodeCantFindMember)
		return true
	}
	if code := d.targetAvailable(ctx, world.Entity{}, g, me); code != 1 && code != guild.CodeTargetBusy {
		d.failInvite(inv, code)
		return true
	}
	g, err = d.guilds.Join(ctx, inv.guildID, me.CharacterID, me.Name)
	if err != nil {
		code := uint16(0x4c1c) // GUILDERR_CANT_ADD_MEMBER_IN_DB
		if errors.Is(err, guild.ErrGuildFull) {
			code = guild.CodeGuildFull
		}
		d.failInvite(inv, code)
		return true
	}
	var added guild.Member
	for _, m := range g.Members {
		if m.CharacterID == me.CharacterID {
			added = m
		}
	}
	live := d.guildLive(ctx, me.CharacterID)
	live.Online = true
	d.toMembers(g, guild.OpUpdate, guild.EncodeMemberAdded(added, live), me.CharacterID)
	d.toMembers(g, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldOffline, added, live), me.CharacterID)
	sendGuildBlock(ctx, sess, g)
	refreshGuildPlate(d.hub, me.CharacterID, g)
	slog.Info("guild joined", "guild_id", g.ID, "character_id", me.CharacterID, "inviter", inv.inviter)
	return true
}
