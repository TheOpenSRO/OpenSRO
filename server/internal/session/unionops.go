package session

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"sync"
	"sync/atomic"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 844 (lane U): the players' union flow -- the request 0x70FB and its
// answer, leave 0x70FC, expel 0x70FD, the union broken, and union chat --
// as SR_GameServer and its ShardManager do it (internal/guild/union844.go has
// the reading; docs/protocol/guild_union.md the whole of it). The
// ShardManager's jobs are direct store calls here (one process), as round
// 822's guild requests are.

// UnionHandler serves 0x70FB..0x70FD (the answer rides the party handler's
// 0x3080 chain, unionRequestAnswer).
func UnionHandler() gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case guild.OpUnionRequest:
			return handleUnionRequest(ctx, sess, p)
		case guild.OpUnionLeave:
			return handleUnionLeave(ctx, sess)
		case guild.OpUnionExpel:
			return handleUnionExpel(ctx, sess, p)
		}
		return nil
	}
}

// unionHostile answers whether two guilds are hostile (at war): the request's
// 0x4c42. Nil -- no wars -- answers no. The guild war lane stores its own
// test here (unionHostile.Store).
var unionHostile atomic.Pointer[func(ctx context.Context, a, b int64) bool]

func unionGuildsHostile(ctx context.Context, a, b int64) bool {
	f := unionHostile.Load()
	return f != nil && (*f)(ctx, a, b)
}

// unionRequest is one request waiting for the target's answer (the wait
// response of kind 6, 30 s: the same wrapper as the party's and the guild's).
type unionRequest struct {
	requester, target int64
	timer             *time.Timer
}

var unionRequests = struct {
	mu sync.Mutex
	m  map[int64]*unionRequest // by target
}{m: map[int64]*unionRequest{}}

// unionRequestTimeout is the wait (party.InviteTimeout's 30 s, the wrapper
// s:0x46c7e0's).
var unionRequestTimeout = party.InviteTimeout

// unionDeps is the guild handler's state, or nil before the guild handler is
// made.
func unionDeps() *guildOpsDeps { return guildOps.Load() }

// handleUnionRequest is 0x70FB {u32 target uid} (s:0x5170b0): the target in
// reach, then s:0x5c6550; a valid request opens the target's box (0x3080 kind
// 6) and tells the requester nothing; a refusal is 0xB0FB {2, code}.
func handleUnionRequest(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
	d := unionDeps()
	if d == nil || len(p.Data) < 4 {
		return nil
	}
	targetUID := binary.LittleEndian.Uint32(p.Data)
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpUnionRequestResult, guild.EncodeFail(code))
		return nil
	}
	t, code := (PartyDeps{Hub: d.hub}).reachTarget(me, targetUID)
	if code != 1 {
		return fail(guild.CodeNotInRange)
	}
	req := guild.UnionRequest{RequesterAlive: me.Life != world.LifeDead, TargetFound: t.Life != world.LifeDead}
	g, err := d.guilds.GetByCharacter(ctx, me.CharacterID)
	if err == nil && g != nil {
		req.RequesterGuildID = g.ID
		req.RequesterIsMaster = g.LeaderID == me.CharacterID
		req.RequesterLevel = g.Level
		req.RequesterUnion = unionOfGuild(ctx, g.ID)
	}
	tg, err := d.guilds.GetByCharacter(ctx, t.CharacterID)
	if err == nil && tg != nil {
		req.TargetGuildID = tg.ID
		req.TargetLevel = tg.Level
		req.TargetIsMaster = tg.LeaderID == t.CharacterID
		req.TargetInUnion = unionOfGuild(ctx, tg.ID) != nil
		if g != nil {
			req.TargetHostile = unionGuildsHostile(ctx, g.ID, tg.ID)
		}
	}
	if code := guild.ValidateUnionRequest(req); code != 1 {
		slog.Info("union request refused", "character_id", me.CharacterID, "target", t.CharacterID, "code", code)
		return fail(code)
	}
	// The wait response (s:0x4ea0d0): a target already asked is busy -- the
	// maker fails and the validator answers 3.
	unionRequests.mu.Lock()
	if _, pending := unionRequests.m[t.CharacterID]; pending {
		unionRequests.mu.Unlock()
		return fail(guild.CodeNotInRange)
	}
	r := &unionRequest{requester: me.CharacterID, target: t.CharacterID}
	r.timer = time.AfterFunc(unionRequestTimeout, func() { unionRequestTimedOut(r) })
	unionRequests.m[t.CharacterID] = r
	unionRequests.mu.Unlock()
	slog.Info("union requested", "character_id", me.CharacterID, "guild_id", g.ID, "target", t.CharacterID, "target_guild", tg.ID)
	sendGuild(t.Session, guild.OpRequest, guild.EncodeUnionRequestBox(uint32(me.CharacterID)))
	return nil
}

// takeUnionRequest removes and returns target's pending request.
func takeUnionRequest(target int64) *unionRequest {
	unionRequests.mu.Lock()
	defer unionRequests.mu.Unlock()
	r := unionRequests.m[target]
	if r != nil {
		delete(unionRequests.m, target)
		r.timer.Stop()
	}
	return r
}

// failUnionRequest is trs_wait_response::FUN_005cccd0: 0xB0FB {2, code} to
// the requester only (the target's box closes by its own timer).
func failUnionRequest(d *guildOpsDeps, r *unionRequest, code uint16) {
	if e, ok := entityOf(d.hub, r.requester); ok {
		sendGuild(e.Session, guild.OpUnionRequestResult, guild.EncodeFail(code))
	}
}

// unionRequestTimedOut is the 30 s with no answer: 0x4c10 to the requester
// (s:0x46ce51).
func unionRequestTimedOut(r *unionRequest) {
	unionRequests.mu.Lock()
	if unionRequests.m[r.target] != r {
		unionRequests.mu.Unlock()
		return
	}
	delete(unionRequests.m, r.target)
	unionRequests.mu.Unlock()
	if d := unionDeps(); d != nil {
		failUnionRequest(d, r, guild.CodeInviteTimeout)
	}
}

// unionRequestAnswer takes the target's 0x3080 answer when a union request
// waits for it; false when none does. s:0x5c8510 kind 6: either side gone 2;
// a "no" 0x4c2e; a "yes" the ShardManager's job 0xb (sm:0x438f..), whose
// refusals go to the requester and whose success forms or grows the union.
func unionRequestAnswer(ctx context.Context, sess *gateway.Session, me world.Entity, data []byte) bool {
	d := unionDeps()
	if d == nil {
		return false
	}
	unionRequests.mu.Lock()
	_, pending := unionRequests.m[me.CharacterID]
	unionRequests.mu.Unlock()
	if !pending {
		return false
	}
	accept, ok := guild.DecodeAnswer(data)
	if !ok {
		return true
	}
	r := takeUnionRequest(me.CharacterID)
	if r == nil {
		return true
	}
	if _, online := entityOf(d.hub, r.requester); !online {
		return true
	}
	if !accept {
		failUnionRequest(d, r, guild.CodeUnionRefused)
		return true
	}
	if code := unionJoinJob(ctx, d, r); code != 1 {
		failUnionRequest(d, r, code)
	}
	return true
}

// unionJoinJob is the ShardManager's job 0xb (sm:0x438f.., in its order):
// the requester's guild gone 0x4c0d, the target's 0x4c25, the target's in a
// union 0x4c28, the target not its master 0x4c24, the requester's union full
// 0x4c29; then the union formed (the requester's guild first) or the target's
// guild added to it, and everyone told (unionJoined).
func unionJoinJob(ctx context.Context, d *guildOpsDeps, r *unionRequest) uint16 {
	us := unionStore()
	if us == nil {
		return 2
	}
	g, err := d.guilds.GetByCharacter(ctx, r.requester)
	if err != nil || g == nil {
		return guild.CodeNotInGuild
	}
	tg, err := d.guilds.GetByCharacter(ctx, r.target)
	if err != nil || tg == nil {
		return guild.ErrAllianceCantFindTargetGuild
	}
	if unionOfGuild(ctx, tg.ID) != nil {
		return guild.ErrAllianceTargetHasAlliance
	}
	if tg.LeaderID != r.target {
		return guild.ErrAllianceTargetMasterAbsent
	}
	if u := unionOfGuild(ctx, g.ID); u != nil && u.Count() >= guild.MaxAllianceGuilds {
		return guild.ErrAllianceFull
	}
	u, err := us.JoinUnion(ctx, tg.ID, g.ID)
	if err != nil {
		if c := guild.UnionCode(err); c != 0 {
			return uint16(c)
		}
		slog.Warn("union join failed", "guild_id", g.ID, "target_guild", tg.ID, "err", err)
		return 2
	}
	slog.Info("union joined", "union_id", u.ID, "leader_guild", u.LeaderGuildID(), "joined", tg.ID, "guilds", u.Count())
	unionJoined(ctx, u, tg.ID)
	return 1
}

// unionMaster is the sender's guild and union for 0x70FC / 0x70FD, or the
// refusal: no guild 0x4c0d, not the master 0x4c1e, no union 0x4c2f.
func unionMaster(ctx context.Context, d *guildOpsDeps, characterID int64) (*guild.Guild, *guild.Union, uint16) {
	g, err := d.guilds.GetByCharacter(ctx, characterID)
	if err != nil || g == nil {
		return nil, nil, guild.CodeNotInGuild
	}
	if g.LeaderID != characterID {
		return nil, nil, guild.CodePermissionDenied
	}
	u := unionOfGuild(ctx, g.ID)
	if u == nil {
		return nil, nil, guild.CodeNoUnion
	}
	return g, u, 1
}

// handleUnionLeave is 0x70FC (s:0x5c6710, sm:0x4391d0): the guild leaves its
// union; 0xB0FC {1}, or {2, code}.
func handleUnionLeave(ctx context.Context, sess *gateway.Session) error {
	d := unionDeps()
	us := unionStore()
	if d == nil || us == nil {
		return nil
	}
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	g, _, code := unionMaster(ctx, d, me.CharacterID)
	if code != 1 {
		sendGuild(sess, guild.OpUnionLeaveResult, guild.EncodeFail(code))
		return nil
	}
	before, _, err := us.LeaveUnion(ctx, g.ID)
	if err != nil {
		if errors.Is(err, guild.ErrNoUnion) {
			sendGuild(sess, guild.OpUnionLeaveResult, guild.EncodeFail(guild.CodeNoUnion))
		}
		return nil
	}
	slog.Info("union left", "union_id", before.ID, "guild_id", g.ID)
	unionOut(ctx, before, g.ID, guild.UnionOutLeft, nil, func() {
		sendGuild(sess, guild.OpUnionLeaveResult, guild.EncodeOK())
	})
	return nil
}

// handleUnionExpel is 0x70FD {u32 guild id} (s:0x5c67a0, sm:0x439350): the
// union's first guild's master puts a guild out; 0xB0FD {1}, or {2, code}.
func handleUnionExpel(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
	d := unionDeps()
	us := unionStore()
	if d == nil || us == nil || len(p.Data) < 4 {
		return nil
	}
	target := int64(binary.LittleEndian.Uint32(p.Data))
	me, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpUnionExpelResult, guild.EncodeFail(code))
		return nil
	}
	g, u, code := unionMaster(ctx, d, me.CharacterID)
	if code != 1 {
		return fail(code)
	}
	if u.LeaderGuildID() != g.ID {
		return fail(guild.CodePermissionDenied)
	}
	if !u.Has(target) {
		return fail(guild.CodeNotInUnion)
	}
	if tg, err := d.guilds.Get(ctx, target); err != nil || tg == nil {
		return fail(guild.ErrAllianceCantFindTargetGuild)
	}
	before, _, err := us.LeaveUnion(ctx, target)
	if err != nil {
		return fail(guild.CodeNotInUnion)
	}
	slog.Info("union expelled", "union_id", before.ID, "guild_id", target, "by", g.ID)
	unionOut(ctx, before, target, guild.UnionOutExpelled, nil, func() {
		sendGuild(sess, guild.OpUnionExpelResult, guild.EncodeOK())
	})
	return nil
}

// unionOut tells everyone that guildID went out of `before` (how: left or
// expelled), as s:0x5b8cf0 and sm:0x4369f0 do: 0x38F5 {0x12, how, guildID}
// to every guild of the union as it was (the one gone too: its client clears
// its union), then `between` (the request's reply), then -- when the union
// is broken (its first guild went, or fewer than two are left) --
// {0x12, 3} to the guilds left, and the store's union dissolved. Every
// member's guild line is filed again (its union id). gone is the guild itself
// when it no longer exists (a disband): its members are told the 0x12 and
// nothing more.
func unionOut(ctx context.Context, before *guild.Union, guildID int64, how byte, gone *guild.Guild, between func()) {
	if before == nil {
		if between != nil {
			between()
		}
		return
	}
	all := unionGuilds(ctx, before.GuildIDs())
	if gone != nil {
		all = append(all, gone)
	}
	toGuildMembers(all, guild.OpUpdate, guild.EncodeUnionOut(how, guildID))
	if between != nil {
		between()
	}
	var left []*guild.Guild
	for _, g := range all {
		if g != gone && g.ID != guildID {
			left = append(left, g)
		}
	}
	if guild.UnionBroken(before, guildID) {
		// The store dissolves a union under two itself; one whose first
		// guild left is broken here.
		if b, ok := unionStore().(guild.UnionBreaker); ok {
			if err := b.BreakUnion(ctx, before.ID); err != nil {
				slog.Warn("union not broken", "union_id", before.ID, "err", err)
			}
		}
		slog.Info("union broken", "union_id", before.ID, "guilds_left", len(left))
		toGuildMembers(left, guild.OpUpdate, guild.EncodeUnionOut(guild.UnionOutBroken, 0))
	}
	var live []*guild.Guild
	for _, g := range all {
		if g != gone {
			live = append(live, g)
		}
	}
	refreshUnionPlates(live)
}

// unionChat is chat type 0x0b (GObjPC::FUN_004b1750 case 0xb): no guild
// 0x200b, no union 0x200c, neither the master nor holding PermUnionChat
// 0x200e; else the line to every member of every union guild in the world
// but the sender (each client drops the copy with its own name, c:0x8780f1,
// and shows its own line from the result).
func unionChat(ctx context.Context, guilds guild.Store, hub *world.Hub, sender world.Entity, line *ChatUpdate) uint16 {
	if guilds == nil || hub == nil {
		return ChatErrAllianceDenied
	}
	g, err := guilds.GetByCharacter(ctx, sender.CharacterID)
	if err != nil || g == nil {
		return ChatErrAllianceDenied
	}
	u := unionOfGuild(ctx, g.ID)
	if u == nil {
		return ChatErrAllianceNoUnion
	}
	if g.LeaderID != sender.CharacterID && !memberPerm(g, sender.CharacterID).Has(guild.PermUnionChat) {
		return ChatErrGuildUnionLimit
	}
	for _, ug := range unionGuilds(ctx, u.GuildIDs()) {
		for _, m := range ug.Members {
			if m.CharacterID == sender.CharacterID {
				continue
			}
			if e, ok := hub.EntityByCharacterID(m.CharacterID); ok && e.Session != nil {
				sendChatUpdate(e.Session, line)
			}
		}
	}
	return 0
}

// ChatErrAllianceNoUnion is 0xB025's 0x200c: in a guild with no union (the
// same UIIT_CHATERR_ALLIANCE_PERMISSION_DENIED as 0x200b, c:0x877340).
const ChatErrAllianceNoUnion uint16 = 0x200c
