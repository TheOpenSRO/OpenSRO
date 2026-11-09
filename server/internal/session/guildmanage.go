package session

// Round 844 (lane G): the guild window's and the guild manager's own
// requests, as SR_GameServer.exe answers them (READ unless marked;
// docs/protocol/guild_census.md):
//
//   - 0x70F9 the notice (s:0x516ea0 -> 0x5c6480),
//   - 0x70FA the level-up from the guild manager's window (s:0x516da0),
//   - 0x7103 the master's hand-over (s:0x517300 -> 0x5c6900),
//   - 0x7104 the members' permission bits (s:0x5173e0 -> 0x5c69f0),
//   - 0x7258 the SP -> GP donation (s:0x517cc0 -> 0x5c7880).
//
// The original sends each change to the ShardManager as a job and answers on
// its reply; here the store is the job (one process), as round 822's
// membership requests do.

import (
	"context"
	"encoding/binary"
	"errors"
	"log/slog"
	"sync/atomic"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// guildDonateSkills is the skill store the donation spends SP from (main
// sets it with SetGuildDonateSkills; nil refuses every donation with 2).
var guildDonateSkills atomic.Pointer[skill.Store]

// SetGuildDonateSkills names the store 0x7258 spends SP from.
func SetGuildDonateSkills(s skill.Store) {
	if s == nil {
		guildDonateSkills.Store(nil)
		return
	}
	guildDonateSkills.Store(&s)
}

// GuildDonateRate is the GP one SP gives. OPEN: the ShardManager credits the
// donation (job 0x2a, "SP DONATION FAILED") and its rate is not read; 1:1 is
// the rate a member's earned SP gives (round 272, GuildPointsPerSkillPoint),
// INFERRED for the donation too.
const GuildDonateRate = guild.GuildPointsPerSkillPoint

// handleGuildManage dispatches this file's requests.
func handleGuildManage(ctx context.Context, sess *gateway.Session, p *proto.Packet, d guildOpsDeps) error {
	if d.hub == nil {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	switch p.Opcode {
	case guild.OpNotice:
		return d.handleNotice(ctx, sess, e, p.Data)
	case guild.OpLevelUp:
		return d.handleLevelUpNPC(ctx, sess, e, p.Data)
	case guild.OpHandOver:
		return d.handleHandOver(ctx, sess, e, p.Data)
	case guild.OpPermission:
		return d.handlePermissions(ctx, sess, e, p.Data)
	case guild.OpDonate:
		return d.handleDonate(ctx, sess, e, p.Data)
	}
	return nil
}

func (d guildOpsDeps) manage() guild.ManageStore {
	m, _ := d.guilds.(guild.ManageStore)
	return m
}

// alive is GetLifeState == 1: the hub's life state, HP above 0 for one it
// does not hold (the founder check's stand-in, round 487).
func (d guildOpsDeps) alive(ctx context.Context, sess *gateway.Session, e world.Entity) bool {
	if e.Life == world.LifeDead || deadBySession(d.hub, sess) {
		return false
	}
	if d.chars != nil {
		if c, err := d.chars.GetByID(ctx, e.CharacterID); err == nil && c != nil && c.HP <= 0 {
			return false
		}
	}
	return true
}

func readStr(b []byte) (string, []byte, bool) {
	if len(b) < 2 {
		return "", nil, false
	}
	n := int(binary.LittleEndian.Uint16(b))
	if len(b) < 2+n {
		return "", nil, false
	}
	return string(b[2 : 2+n]), b[2+n:], true
}

// --- the notice (0x70F9) -----------------------------------------------------

// handleNotice is s:0x516ea0 -> 0x5c6480 (READ): a chat ban answers 0x3405
// and drops the request (s:0x516edf); a ' or " in the title or the body drops
// it with no reply (the filter s:0x7312f0); dead 0x4c07, no guild 0x4c0d,
// without the notice bit 0x4c1e, the title 1..128 bytes else 0x4c22, the
// body 1..2048 bytes else 0x4c23; then the guild's notice, 0xB0F9 {1} to the
// writer and 0x38F5 type 5 with the notice (mask 0x10, INFERRED: the
// ShardManager's relay s:0x5c3c90 copies the fields its mask names) to the
// members in the world.
func (d guildOpsDeps) handleNotice(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	title, rest, ok := readStr(data)
	if !ok {
		return nil
	}
	body, _, ok := readStr(rest)
	if !ok {
		return nil
	}
	if restricted(ctx, sess, RestrictChat) {
		return nil
	}
	if guild.NoticeQuoteRefused(title) || guild.NoticeQuoteRefused(body) {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpNoticeResult, guild.EncodeFail(code))
		return nil
	}
	if !d.alive(ctx, sess, e) {
		return fail(guild.CodeIMDead)
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeNotInGuild)
	}
	if !memberPerm(g, e.CharacterID).Has(guild.PermNotice) {
		return fail(guild.CodePermissionDenied)
	}
	switch guild.CheckNotice(title, body) {
	case guild.ErrNoticeTitle:
		return fail(guild.CodeNoticeTitle)
	case guild.ErrNoticeBody:
		return fail(guild.CodeNoticeBody)
	}
	m := d.manage()
	if m == nil {
		return fail(guild.CodeFailed)
	}
	g, err = m.SetNotice(ctx, g.ID, title, body)
	if err != nil {
		slog.Warn("guild notice not saved", "character_id", e.CharacterID, "err", err)
		return fail(guild.CodeFailed)
	}
	sendGuild(sess, guild.OpNoticeResult, guild.EncodeOK())
	d.toMembers(g, guild.OpUpdate, guild.EncodeGuildFields(guild.GuildFieldNotice, g), 0)
	return nil
}

// --- the level-up from the guild manager (0x70FA) ----------------------------

// handleLevelUpNPC is Guild_HandleLevelUpRequest s:0x516da0 (READ): the NPC
// in reach and a guild manager (else 3), then CGuild::HandleLevelUp's ladder
// (guild.CheckLevelUp: dead 0x4c07, no guild 0x4c0d, not the master 0x4c1e,
// level 5 0x4c21, gold 0x4c31, GP 0x4c32); its success 0xB0FA {1} and 0x38F5
// type 5 {level, GP} to the members (guildLevelChanged). Round 528's
// OpGuildLevel stays for OURS tools.
func (d guildOpsDeps) handleLevelUpNPC(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 4 {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpLevelUpResult, guild.EncodeFail(code))
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(data)) {
		return fail(guild.CodeNotInRange)
	}
	pc, err := d.chars.GetByID(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeFailed)
	}
	var paid int64
	pay := func(gold int64) error {
		if err := d.chars.DeductGold(ctx, e.CharacterID, gold); err != nil {
			if errors.Is(err, character.ErrInsufficientGold) {
				return guild.ErrLevelUpGoldDeficit
			}
			return err
		}
		paid = gold
		return nil
	}
	g, err := d.guilds.LevelUp(ctx, e.CharacterID, d.alive(ctx, sess, e), pc.Gold, pay)
	if err != nil {
		if paid > 0 {
			if rerr := d.chars.AddGold(context.WithoutCancel(ctx), e.CharacterID, paid); rerr != nil {
				slog.Warn("guild level-up failed after its gold was taken, and the refund failed",
					"character_id", e.CharacterID, "gold", paid, "levelup_err", err, "refund_err", rerr)
			}
		}
		code := guild.LevelUpCode(err)
		if code == 0 {
			if errors.Is(err, guild.ErrNotInGuild) {
				return fail(guild.CodeNotInGuild)
			}
			return fail(guild.CodeFailed)
		}
		return fail(uint16(code))
	}
	tellGold(ctx, d.chars, d.hub, e.CharacterID, false)
	sendGuild(sess, guild.OpLevelUpResult, guild.EncodeOK())
	guildLevelChanged(ctx, g)
	// Round 844 part 2: the GP history's "Guild Growth" (sm:0x438bb0).
	if _, gp, ok := guild.LevelUpCost(g.Level - 1); ok {
		logGPUse(ctx, d.guilds, g.ID, e.Name, int64(gp), guild.GPUseGuildGrowth)
	}
	return nil
}

// --- the master's hand-over (0x7103) -----------------------------------------

// handleHandOver is s:0x517300 -> 0x5c6900 (READ): the NPC in reach and a
// guild manager, else 3; the target the master himself, 3; no guild 0x4c0d;
// a master-release vote running 0x4c1e (OpenSRO has no vote: never); not the
// master 0x4c1e; a fortress guild in the siege period 0x4c5d and a hired
// guild soldier (timed job (2, 4)) 0x4c55 (OpenSRO has neither: never); the
// target not a member 0x4c1d. The target need not be online, and nothing
// checks its level or penalty. Then (the ShardManager's
// _Guild_Delegate_Master and its notification s:0x5c46e0): 0xB103 {1} to the
// old master, 0x38F5 type 0x16 mask 0x54 {class, permission, siege role} for
// the new and the old master to the members in the world, and to the new
// master type 0x16 mask 0x10 with every other member's permission
// (CGuild::vslot_010 s:0x5c4dc0).
func (d guildOpsDeps) handleHandOver(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 8 {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpHandOverResult, guild.EncodeFail(code))
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(data)) {
		return fail(guild.CodeNotInRange)
	}
	to := int64(binary.LittleEndian.Uint32(data[4:]))
	if to == e.CharacterID {
		return fail(guild.CodeNotInRange)
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeNotInGuild)
	}
	// A master-release vote running: 0x4c1e (s:0x5c6900, CMainProcess::
	// FUN_005d1060 on the guild's vote list; round 844 part 2).
	if voteOfGuild(g.ID) != nil {
		return fail(guild.CodePermissionDenied)
	}
	if g.LeaderID != e.CharacterID {
		return fail(guild.CodePermissionDenied)
	}
	if !isMember(g, to) {
		return fail(guild.CodeCantFindMember)
	}
	// B103 {1} goes before the members' updates, as before the refactor.
	_, err = d.handOver(ctx, g, to, func() { sendGuild(sess, guild.OpHandOverResult, guild.EncodeOK()) })
	if err != nil {
		if errors.Is(err, guild.ErrNotInGuild) {
			return fail(guild.CodeCantFindMember)
		}
		slog.Warn("guild hand-over failed", "guild_id", g.ID, "to", to, "err", err)
		return fail(guild.CodeFailed)
	}
	return nil
}

// handOver makes `to` g's master and tells the members (the ShardManager's
// hand-over notification, s:0x5c46e0): 0x38F5 type 0x16 mask 0x54 for the
// new and the old master, then to the new master type 0x16 mask 0x10 with
// every other member's mask (CGuild::vslot_010 s:0x5c4dc0). The
// master-release vote's win takes the same path (sm:0x4617b0). done, when
// set, runs once the store has moved the guild, before the updates go out
// (the requester's B103).
func (d guildOpsDeps) handOver(ctx context.Context, g *guild.Guild, to int64, done func()) (*guild.Guild, error) {
	m := d.manage()
	if m == nil {
		return nil, errors.New("guild: the store keeps no hand-over")
	}
	from := g.LeaderID
	after, err := m.TransferMaster(ctx, g.ID, to)
	if err != nil {
		return nil, err
	}
	if done != nil {
		done()
	}
	var pair []guild.Member
	for _, id := range []int64{to, from} {
		if mm, ok := memberOf(after, id); ok {
			pair = append(pair, mm)
		}
	}
	d.toMembers(after, guild.OpUpdate, guild.EncodeMembersFields(
		guild.MemberFieldClass|guild.MemberFieldPerm|guild.MemberFieldSiege, pair, nil), 0)
	if ne, ok := reachOf(d.hub, to); ok {
		var others []guild.Member
		for _, mm := range after.Members {
			if mm.CharacterID != to {
				others = append(others, mm)
			}
		}
		if len(others) > 0 {
			sendGuild(ne.Session, guild.OpUpdate, guild.EncodeMembersFields(guild.MemberFieldPerm, others, nil))
		}
	}
	slog.Info("guild master handed over", "guild_id", g.ID, "from", from, "to", to)
	return after, nil
}

func isMember(g *guild.Guild, id int64) bool {
	_, ok := memberOf(g, id)
	return ok
}

func memberOf(g *guild.Guild, id int64) (guild.Member, bool) {
	for _, m := range g.Members {
		if m.CharacterID == id {
			return m, true
		}
	}
	return guild.Member{}, false
}

// --- the permissions (0x7104) ------------------------------------------------

// handlePermissions is s:0x5173e0 -> 0x5c69f0 (READ): no guild 0x4c0d; not
// the master 0x4c1e; more than 12 members holding the union chat bit after
// the change 0x4c4b (s:0x5c49a0); the member using the guild storage losing
// its storage bit 0x4c4c (lane H's storage; OpenSRO asks GuildStorageUser);
// then the masks, 0xB104 {1}, and (s:0x5c4bb0): the master 0x38F5 type 0x16
// mask 0x10 with the changed rows, each changed member type 6 mask 0x10,
// every member in the world type 0x14 with the rows.
//
// OURS: a row for the master or for no member is left out (the client never
// sends either; whether the ShardManager refuses them is OPEN).
func (d guildOpsDeps) handlePermissions(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 1 {
		return nil
	}
	n := int(data[0])
	if len(data) < 1+8*n {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpPermissionResult, guild.EncodeFail(code))
		return nil
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeNotInGuild)
	}
	if g.LeaderID != e.CharacterID {
		return fail(guild.CodePermissionDenied)
	}
	var changes []guild.PermissionChange
	for i := 0; i < n; i++ {
		id := int64(binary.LittleEndian.Uint32(data[1+8*i:]))
		mask := guild.Permission(binary.LittleEndian.Uint32(data[5+8*i:]))
		if id == g.LeaderID || !isMember(g, id) {
			continue
		}
		changes = append(changes, guild.PermissionChange{CharacterID: id, Permission: mask})
	}
	if unionChatHolders(g, changes) > guild.UnionChatMax {
		return fail(guild.CodeUnionChatFull)
	}
	if user := GuildStorageUser(g.ID); user != 0 {
		for _, c := range changes {
			if c.CharacterID == user && !c.Permission.Has(guild.PermWarehouse) {
				return fail(guild.CodeStorageUseIng)
			}
		}
	}
	m := d.manage()
	if m == nil {
		return fail(guild.CodeFailed)
	}
	if len(changes) == 0 {
		sendGuild(sess, guild.OpPermissionResult, guild.EncodeOK())
		return nil
	}
	after, err := m.SetPermissions(ctx, g.ID, changes)
	if err != nil {
		slog.Warn("guild permissions not saved", "guild_id", g.ID, "err", err)
		return fail(guild.CodeFailed)
	}
	sendGuild(sess, guild.OpPermissionResult, guild.EncodeOK())
	var rows []guild.Member
	for _, c := range changes {
		if mm, ok := memberOf(after, c.CharacterID); ok {
			rows = append(rows, mm)
			if me, ok := reachOf(d.hub, c.CharacterID); ok {
				sendGuild(me.Session, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldPerm, mm, guild.MemberLive{}))
			}
		}
	}
	sendGuild(sess, guild.OpUpdate, guild.EncodeMembersFields(guild.MemberFieldPerm, rows, nil))
	d.toMembers(after, guild.OpUpdate, guild.EncodePermissions(changes), 0)
	return nil
}

// unionChatHolders is s:0x5c49a0's count: the members holding the union chat
// bit who are not in the list, plus the list's rows that hold it.
func unionChatHolders(g *guild.Guild, changes []guild.PermissionChange) int {
	listed := map[int64]guild.Permission{}
	for _, c := range changes {
		listed[c.CharacterID] = c.Permission
	}
	n := 0
	for _, m := range g.Members {
		p, in := listed[m.CharacterID]
		if !in {
			p = m.Permission
		}
		if m.CharacterID != g.LeaderID && p.Has(guild.PermUnionChat) {
			n++
		}
	}
	return n
}

// GuildStorageUser is the member using guildID's storage now (0 none), from
// the guild storage's lock (GuildStorageHolder). The permission change
// consults it (s:0x5c69f0, 0x5d0dc0 / guild+0x28).
var GuildStorageUser = func(guildID int64) int64 {
	id, _ := GuildStorageHolder(guildID)
	return id
}

// --- the SP -> GP donation (0x7258) ------------------------------------------

// handleDonate is s:0x517cc0 -> 0x5c7880 (READ): an amount of 0 is 2; dead
// 0x4c07; no guild 0x4c0d; the player's SP below the amount 0x4c32; then the
// ShardManager's job 0x2a and its success (s:0x5c98e0): the SP spent, 0xB258
// {1, u32 amount} (UIIT_MSG_GUILD_GP_SUBSCRIPION_RESULT), and the GP through
// CGuild::AddPoints (0x38F5 type 5 mask 8 and type 6 mask 8 to the members).
func (d guildOpsDeps) handleDonate(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 4 {
		return nil
	}
	amount := int(binary.LittleEndian.Uint32(data))
	fail := func(code uint16) error {
		sendGuild(sess, guild.OpDonateResult, guild.EncodeFail(code))
		return nil
	}
	if amount <= 0 {
		return fail(guild.CodeFailed)
	}
	if !d.alive(ctx, sess, e) {
		return fail(guild.CodeIMDead)
	}
	gid, err := d.guilds.GuildIDOf(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeNotInGuild)
	}
	sp := guildDonateSkills.Load()
	if sp == nil {
		return fail(guild.CodeFailed)
	}
	have, err := (*sp).SkillPoints(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeFailed)
	}
	if have < amount {
		return fail(guild.CodeGPDeficit)
	}
	if _, err := (*sp).AddSkillPoints(ctx, e.CharacterID, -amount); err != nil {
		return fail(guild.CodeFailed)
	}
	if err := d.guilds.AddPoints(ctx, gid, e.CharacterID, amount*GuildDonateRate); err != nil {
		// The SP back: the guild did not take it.
		if _, rerr := (*sp).AddSkillPoints(context.WithoutCancel(ctx), e.CharacterID, amount); rerr != nil {
			slog.Warn("guild donation failed after the SP was spent, and the refund failed",
				"character_id", e.CharacterID, "sp", amount, "err", err, "refund_err", rerr)
		}
		return fail(guild.CodeFailed)
	}
	sendGuild(sess, guild.OpDonateResult, guild.EncodeDonateOK(uint32(amount)))
	if g, err := d.guilds.Get(ctx, gid); err == nil {
		d.toMembers(g, guild.OpUpdate, guild.EncodeGuildFields(guild.GuildFieldGP, g), 0)
		if mm, ok := memberOf(g, e.CharacterID); ok {
			d.toMembers(g, guild.OpUpdate, guild.EncodeMemberFields(guild.MemberFieldGP, mm, guild.MemberLive{}), 0)
		}
	}
	return nil
}
