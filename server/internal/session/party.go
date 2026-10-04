package session

// The party, on the original's opcodes (round 710). docs/protocol/
// party_protocol.md (round 709) is the contract: every message here is
// retail's, byte for byte, built by internal/party/wire.go. OpenSRO's own
// 0x0080..0x0089 party messages are retired.
//
// Who decides what. Retail splits the party between the GameServer (the invite
// ladders, the member records, the replies) and the ShardManager (the party
// list, formation, join, removal, leader succession). OpenSRO has one process:
// party.Hub is the ShardManager's half, this file the GameServer's.
//
// What is OURS here, each labelled where it is done:
//   - the ids (party.JIDOf; the fixtures README);
//   - the member-update cadence: a 1 s sampler (partyUpdateInterval) where
//     retail raises an event at each change (vslot_323) -- the bytes and the
//     send-only-on-change rule are retail's;
//   - the masteries a record shows (the engine's pick, GS 0x5a1890, is OPEN);
//   - the world id (1);
//   - a target that names no online player.

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"sort"
	"sync"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/guild"
	"github.com/OpenSRO/OpenSRO/server/internal/mana"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/party"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/trade"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// partyWorldID is the world id a member record carries (retail vtable slot 5
// GetWorldID). OURS: OpenSRO has one field world and sends 1, the id of
// _RefGame_World's INS_DEFAULT in the user's shard export (EXTERNAL).
const partyWorldID uint32 = 1

// partyUpdateInterval is how often the member records are sampled for a
// 0x3864 kind-6 update. OURS: retail sends one at each change event
// (CGObjPC::vslot_323, party_protocol.md), and how often its position event
// fires is OPEN. A sampled field is sent only when it changed, by the
// engine's own rule for each (party.HPMPUpdate for HP/MP).
const partyUpdateInterval = time.Second

// PartyDeps is what the party handlers read.
type PartyDeps struct {
	Chars   character.Store
	Hub     *world.Hub
	Parties *party.Hub
	// Trades answers "is this character in an exclusive interaction"
	// (INTERACTMODE, chardata+6; tradebusy.go). Nil: never.
	Trades *trade.Hub
	// Guilds names a member's guild in its record. Nil: no guild.
	Guilds guild.Store
	// Skills gives the masteries a record shows. Nil: none.
	Skills skill.Store
	// Mana is the current MP. Nil: full.
	Mana   *mana.Tracker
	Logger *slog.Logger
}

func (d PartyDeps) busy(characterID int64) bool {
	return d.Trades != nil && d.Trades.Busy(characterID)
}

func (d PartyDeps) log() *slog.Logger {
	if d.Logger != nil {
		return d.Logger
	}
	return slog.Default()
}

func sendParty(sess *gateway.Session, op uint16, data []byte) {
	if sess != nil {
		sess.Send(&proto.Packet{Opcode: op, Data: data})
	}
}

// PartyHandler returns the handler for the party's client messages: 0x7060
// create, 0x7061 leave, 0x7062 invite, 0x7063 kick and the 0x3080 answer.
func PartyHandler(d PartyDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		switch p.Opcode {
		case party.OpCreate:
			handlePartyCreate(ctx, sess, p.Data, d)
		case party.OpInvite:
			handlePartyInvite(ctx, sess, p.Data, d)
		case party.OpInvitation:
			handlePartyAnswer(ctx, sess, p.Data, d)
		case party.OpLeave:
			handlePartyLeave(ctx, sess, d)
		case party.OpKick:
			handlePartyKick(ctx, sess, p.Data, d)
		}
		return nil
	}
}

// memberOf is the party member an entity joins as. Job is JobNone: OpenSRO
// has no job mode yet, and every character's job state is 4.
func (d PartyDeps) memberOf(e world.Entity) party.Member {
	return party.Member{Session: e.Session, CharacterID: e.CharacterID, Name: e.Name, Level: e.Level, Job: party.JobNone}
}

// checkCanCreate is CParty::CheckCanCreate (READ, GS 0x513f90), in its order:
// the slot-0x244 test (0x2c19; what it tests is OPEN, OpenSRO never refuses
// it), the character lock (0x2c09; OpenSRO has none), not alive (0x2c09), a
// state byte other than 0 or 4 together with an exclusive interaction (0x2c09),
// then level < 5 (0x2c0a).
func (d PartyDeps) checkCanCreate(e world.Entity) uint16 {
	if e.Life != world.LifeAlive {
		return party.CodeCreateBusy
	}
	if st := d.Parties.State(e.CharacterID); st != party.StateFree && st != party.StateListed && d.busy(e.CharacterID) {
		return party.CodeCreateBusy
	}
	if !party.CanCreate(e.Level) {
		return party.CodeTooLowCreator
	}
	return 1
}

// reachTarget is GObjPC::IsWithinInteractionRange with the 0x26 filter and
// the PC test after it (READ, GS 0x4a8e10, 0x5143b0/0x514560): 1 when target
// names a player within 600 units (3D) in the caller's world; 0 when it names
// nothing (or another world); 4 out of range; 3 when it names something that
// is not a player.
//
// OURS: OpenSRO's monster ids overlap its character ids, so a target is looked
// up among the players only, and only an NPC uid (npcspawn.UIDBase and up)
// can be told apart as "not a player". A monster's id that no player shares
// answers 0.
func (d PartyDeps) reachTarget(caller world.Entity, target uint32) (world.Entity, uint16) {
	if target >= npcspawn.UIDBase {
		return world.Entity{}, party.CodeWrongType
	}
	t, ok := d.Hub.EntityByCharacterID(int64(target))
	if !ok || t.Zone != caller.Zone {
		return world.Entity{}, party.CodeNotFound
	}
	dx, dy, dz := t.Pos.X-caller.Pos.X, t.Pos.Y-caller.Pos.Y, t.Pos.Z-caller.Pos.Z
	if math.Sqrt(dx*dx+dy*dy+dz*dz) > party.InviteRangePC {
		return t, party.CodeTooFar
	}
	return t, 1
}

// checkTargetAvailable is CParty::CheckTargetAvailable (READ, GS 0x514010, in
// its order): locked 0x2c06 (OpenSRO has no lock); not alive and not dead 3
// (a character is always one of the two here); in a party 0x2c12 when it is
// the caller's, else 0x2c18; holding a match entry 0x2c25; then the state byte
// or an exclusive interaction: 1 or 3 give 0x2c1f, 4 gives 0x2c25, anything
// else 0x2c06; a battle-arena opponent 0x2c28 (OpenSRO has no arena).
func (d PartyDeps) checkTargetAvailable(caller, target world.Entity) uint16 {
	if tp, in := d.Parties.Get(target.CharacterID); in {
		if cp, cin := d.Parties.Get(caller.CharacterID); cin && cp.ID == tp.ID {
			return party.CodeExistingMember
		}
		return party.CodeOtherParty
	}
	if _, _, listed := d.Parties.Listing(target.CharacterID); listed {
		return party.CodeListed
	}
	st := d.Parties.State(target.CharacterID)
	if st != party.StateFree || d.busy(target.CharacterID) {
		switch st {
		case party.StatePending, party.StateListedInviting:
			return party.CodeDuplicate
		case party.StateListed:
			return party.CodeListed
		}
		return party.CodeLocked
	}
	return 1
}

// handlePartyCreate is the 0x7060 handler (READ, GS 0x5143b0): CheckCanCreate,
// a target that is the caller dropped with no reply, the range and PC tests,
// CheckTargetAvailable, then the formation invitation 0x3080 kind 2. Every
// refusal is 0xb060 [2][code].
func handlePartyCreate(ctx context.Context, sess *gateway.Session, data []byte, d PartyDeps) {
	target, flags, err := party.DecodeCreate(data)
	if err != nil || d.Hub == nil {
		return
	}
	caller, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	refuse := func(code uint16) { sendParty(sess, party.OpCreateAck, party.EncodeRefusal(code)) }
	if c := d.checkCanCreate(caller); c != 1 {
		refuse(c)
		return
	}
	if target == party.JIDOf(caller.CharacterID) {
		return
	}
	t, c := d.reachTarget(caller, target)
	if c != 1 {
		refuse(c)
		return
	}
	if c := d.checkTargetAvailable(caller, t); c != 1 {
		refuse(c)
		return
	}
	inv := party.Invite{Kind: party.InviteForm, Inviter: d.memberOf(caller), Target: d.memberOf(t), Flags: flags}
	if err := d.Parties.Invite(inv, d.inviteTimedOut); err != nil {
		refuse(party.CodePostFailed)
		return
	}
	sendParty(t.Session, party.OpInvitation, party.EncodeInvitation(party.InviteForm, party.JIDOf(caller.CharacterID), flags))
}

// handlePartyInvite is the 0x7062 handler, CParty::CheckCanJoin (READ, GS
// 0x514560): the caller must be in a party, its leader or in a party whose
// bit 2 is set, and the target not the caller -- these fail silently. Then a
// full party 0xb062 [2][0x2c13/0x2c14], the range and PC tests, and
// CheckTargetAvailable, each 0xb062 [2][code]; and a failure to post the
// invitation goes out on 0xb060 [2][2], not 0xb062 (GS 0x5146bb).
func handlePartyInvite(ctx context.Context, sess *gateway.Session, data []byte, d PartyDeps) {
	target, err := party.DecodeTarget(data)
	if err != nil || d.Hub == nil {
		return
	}
	caller, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	p, in := d.Parties.Get(caller.CharacterID)
	if !in || (p.LeaderID != caller.CharacterID && !p.Flags.AnyoneInvite()) || target == party.JIDOf(caller.CharacterID) {
		return
	}
	refuse := func(code uint16) { sendParty(sess, party.OpInviteAck, party.EncodeRefusal(code)) }
	if p.Full() {
		refuse(p.Flags.FullCode())
		return
	}
	t, c := d.reachTarget(caller, target)
	if c != 1 {
		refuse(c)
		return
	}
	if c := d.checkTargetAvailable(caller, t); c != 1 {
		refuse(c)
		return
	}
	inv := party.Invite{Kind: party.InviteJoin, Inviter: d.memberOf(caller), Target: d.memberOf(t), Flags: p.Flags, PartyID: p.ID}
	if err := d.Parties.Invite(inv, d.inviteTimedOut); err != nil {
		sendParty(sess, party.OpCreateAck, party.EncodeRefusal(party.CodePostFailed))
		return
	}
	sendParty(t.Session, party.OpInvitation, party.EncodeInvitation(party.InviteJoin, party.JIDOf(caller.CharacterID), p.Flags))
}

// inviterAck is the opcode an invitation's outcome goes to the inviter on:
// 0xb060 for a formation, 0xb062 for a join (READ, GS 0x5be9b0 / 0x5bea20).
func inviterAck(kind party.InviteKind) uint16 {
	if kind == party.InviteJoin {
		return party.OpInviteAck
	}
	return party.OpCreateAck
}

// failInvite sends an invitation's refusal to both sides: the inviter on
// 0xb060/0xb062, the invitee on 0xb067 (READ, GS 0x5be9b0 / 0x5bea20, and the
// timeout trs_wait_response::OnTimeout 0x46ce44).
func failInvite(inv party.Invite, code uint16) {
	sendParty(inv.Inviter.Session, inviterAck(inv.Kind), party.EncodeRefusal(code))
	sendParty(inv.Target.Session, party.OpJoinAck, party.EncodeRefusal(code))
}

// inviteTimedOut runs when an invitation has had no answer for 30 s: 0x2c10
// to both.
func (d PartyDeps) inviteTimedOut(inv party.Invite) {
	failInvite(inv, party.CodeTimeout)
}

// handlePartyAnswer is the invitee's 0x3080 answer (READ, GS 0x46cb30 ->
// 0x5be350). A decline refuses 0x2c0c for a formation and 0x2c17 for a join;
// an inviter no longer online refuses 0x2c0e. A yes forms the party or adds to
// it. An answer with no invitation pending (it timed out) is dropped: the
// engine's "no longer pending" refusal 3 needs the inviter, whom nothing names
// any more (OURS).
func handlePartyAnswer(ctx context.Context, sess *gateway.Session, data []byte, d PartyDeps) {
	accept, err := party.DecodeAnswer(data)
	if err != nil || d.Hub == nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	inv, ok := d.Parties.TakeInvite(me.CharacterID)
	if !ok {
		return
	}
	inv.Target.Session = sess
	if !accept {
		code := party.CodeCreateRefused
		if inv.Kind == party.InviteJoin {
			code = party.CodeJoinRefused
		}
		failInvite(inv, code)
		return
	}
	inviter, online := d.Hub.EntityByCharacterID(inv.Inviter.CharacterID)
	if !online {
		failInvite(inv, party.CodeCantFindCreator)
		return
	}
	inv.Inviter.Session = inviter.Session
	inv.Inviter.Level = inviter.Level
	inv.Target.Level = me.Level
	if inv.Kind == party.InviteForm {
		p, err := d.Parties.Form(inv.Inviter, inv.Target, inv.Flags)
		if err != nil {
			code, _ := party.Refusal(err)
			failInvite(inv, code)
			return
		}
		d.announceFormed(ctx, p)
		return
	}
	p, err := d.Parties.Add(inv.PartyID, inv.Target)
	if err != nil {
		code, _ := party.Refusal(err)
		failInvite(inv, code)
		return
	}
	d.announceJoined(ctx, p, inv.Target)
}

// announceFormed sends a new party's messages in the GameServer's order (READ,
// trs_sm_partyjob::FUN_005be710, FUN_005bc210, FUN_005bb930): the inviter its
// 0xb060 [1][own JID] and then, as the party's first member, a 0x3065 holding
// itself; the invitee its 0xb067 [1][own JID]; the kind-2 record of the
// invitee to the members already in the party (the inviter); then the invitee
// its 0x3065 with both. Lane S3 calls it for a party-match accept that forms a
// party.
func (d PartyDeps) announceFormed(ctx context.Context, p *party.Party) {
	leader, joiner := p.Members[0], p.Members[1]
	lrec := d.fullRecord(ctx, leader)
	sendParty(leader.Session, party.OpCreateAck, party.EncodeOKID(leader.JID()))
	sendParty(leader.Session, party.OpInfo, party.EncodeInfo(&party.Info{PartyID: p.ID, Leader: p.LeaderJID(), Flags: p.Flags, Members: []party.Record{lrec}}))
	sendParty(joiner.Session, party.OpJoinAck, party.EncodeOKID(joiner.JID()))
	jrec := d.fullRecord(ctx, joiner)
	sendParty(leader.Session, party.OpEvent, party.EncodeJoined(&jrec))
	sendParty(joiner.Session, party.OpInfo, party.EncodeInfo(&party.Info{PartyID: p.ID, Leader: p.LeaderJID(), Flags: p.Flags, Members: []party.Record{lrec, jrec}}))
}

// announceJoined sends a join into an existing party (READ, GS
// trs_sm_partyjob::FUN_005be940 then FUN_005bc210): the joiner its 0xb067
// [1][own JID]; the members already there the joiner's kind-2 record; the
// joiner the 0x3065 of the whole party. The inviter gets no 0xb062 on success
// (READ, the 0x062 handler replies only on a refusal). Lane S3 calls it for a
// party-match accept into an existing party.
func (d PartyDeps) announceJoined(ctx context.Context, p *party.Party, joiner party.Member) {
	sendParty(joiner.Session, party.OpJoinAck, party.EncodeOKID(joiner.JID()))
	recs := make([]party.Record, len(p.Members))
	for i, m := range p.Members {
		recs[i] = d.fullRecord(ctx, m)
	}
	var jrec party.Record
	for i, m := range p.Members {
		if m.CharacterID == joiner.CharacterID {
			jrec = recs[i]
		}
	}
	msg := party.EncodeJoined(&jrec)
	for _, m := range p.Members {
		if m.CharacterID != joiner.CharacterID {
			sendParty(m.Session, party.OpEvent, msg)
		}
	}
	sendParty(joiner.Session, party.OpInfo, party.EncodeInfo(&party.Info{PartyID: p.ID, Leader: p.LeaderJID(), Flags: p.Flags, Members: recs}))
}

// handlePartyLeave is 0x7061 (READ, GS 0x514530 -> 0x5144e0(2)): leave with
// reason 2. Not in a party: nothing.
func handlePartyLeave(ctx context.Context, sess *gateway.Session, d PartyDeps) {
	if d.Hub == nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	d.removeMember(me.CharacterID, party.ReasonLeave)
}

// handlePartyKick is 0x7063 (READ, GS Party_HandleExpelMember_063 0x5146d0):
// the caller must be in a party and its leader, the target another member;
// anything else fails silently. Reason 4.
func handlePartyKick(ctx context.Context, sess *gateway.Session, data []byte, d PartyDeps) {
	jid, err := party.DecodeTarget(data)
	if err != nil || d.Hub == nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	p, in := d.Parties.Get(me.CharacterID)
	if !in || p.LeaderID != me.CharacterID || jid == party.JIDOf(me.CharacterID) {
		return
	}
	for _, m := range p.Members {
		if m.JID() == jid {
			d.removeMember(m.CharacterID, party.ReasonKicked)
			return
		}
	}
}

// removeMember takes characterID out of its party and tells the members (READ,
// SM 0x44f580; GS CMainProcess::FUN_005bc390): a party of two is dissolved,
// both told by kind 1 with 0x2c0b; otherwise every member, the leaver
// included, gets kind 3 with the JID and the reason, and when the leader left,
// the rest get kind 9 with the new leader.
func (d PartyDeps) removeMember(characterID int64, reason uint8) {
	r, err := d.Parties.Remove(characterID, reason)
	if err != nil {
		return
	}
	partyRecords.forget(characterID)
	if r.Dissolved {
		msg := party.EncodeDissolved(party.CodeDissolved)
		for _, m := range r.Before.Members {
			partyRecords.forget(m.CharacterID)
			sendParty(m.Session, party.OpEvent, msg)
		}
		return
	}
	left := party.EncodeLeft(party.JIDOf(characterID), reason)
	for _, m := range r.Before.Members {
		sendParty(m.Session, party.OpEvent, left)
	}
	if r.NewLeader != 0 {
		msg := party.EncodeLeader(party.JIDOf(r.NewLeader))
		for _, m := range r.After.Members {
			sendParty(m.Session, party.OpEvent, msg)
		}
	}
}

// PartyDisconnectHandler is the gateway's OnDisconnect hook for parties: a
// member who leaves the world is removed with reason 1, LOGOUT (READ as a
// value, the client's table; the trigger is OURS -- retail's ShardManager
// removes on its own user cleanup, SM 0x4296f0, which this stands in for).
// Its pending invitations are left to answer or time out: an invitee who
// answers after its inviter left is refused 0x2c0e, as the engine does.
func PartyDisconnectHandler(d PartyDeps) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		if d.Parties == nil {
			return
		}
		characterID, ok := d.Parties.CharacterOfSession(sess.ID())
		if !ok {
			return
		}
		d.removeMember(characterID, party.ReasonLogout)
	}
}

// fullRecord is a member's record with every field (mask 0xff), as the
// GameServer builds it from the character (READ, GS 0x5bae80), and remembers
// it as what the members last heard.
func (d PartyDeps) fullRecord(ctx context.Context, m party.Member) party.Record {
	s := d.sample(ctx, m)
	s.rec.Mask = party.MaskFull
	partyRecords.set(m.CharacterID, s)
	return s.rec
}

// memberSample is a member's fields now: the record, its HP/MP as a full
// record's tenths, and the raw values the update path computes its own tenths
// from (party.HPMPUpdate).
type memberSample struct {
	rec                  party.Record
	hp, maxHP, mp, maxMP int
}

// sample reads a member's fields now.
func (d PartyDeps) sample(ctx context.Context, m party.Member) memberSample {
	var s memberSample
	r := party.Record{JID: m.JID(), Name: m.Name, Level: uint8(m.Level), Job: party.JobNone, WorldID: partyWorldID}
	if m.Job != 0 {
		r.Job = m.Job
	}
	if d.Hub != nil {
		if e, ok := d.Hub.EntityByCharacterID(m.CharacterID); ok {
			r.Name, r.Level = e.Name, uint8(e.Level)
			r.Region, r.X, r.Y, r.Z = partyPosition(e)
		}
	}
	if d.Chars != nil {
		if c, err := d.Chars.GetByID(ctx, m.CharacterID); err == nil && c != nil {
			r.RefObjID = uint32(c.RefObjID)
			maxMP := c.MaxMP()
			mp := maxMP
			if d.Mana != nil {
				mp = d.Mana.Current(m.CharacterID, maxMP)
			}
			s.hp, s.maxHP, s.mp, s.maxMP = c.HP, c.MaxHP(), mp, maxMP
			r.HPMP = party.HPMPFull(s.hp, s.maxHP, s.mp, s.maxMP)
		}
	}
	if d.Guilds != nil {
		if g, err := d.Guilds.GetByCharacter(ctx, m.CharacterID); err == nil && g != nil {
			r.Guild = g.Name
		} else if err != nil && !errors.Is(err, guild.ErrNotInGuild) {
			d.log().Debug("party record: guild lookup", "character", m.CharacterID, "error", err)
		}
	}
	if d.Skills != nil {
		if lv, err := d.Skills.MasteryLevels(ctx, m.CharacterID); err == nil {
			r.Mastery1, r.Mastery2 = topMasteries(lv)
		}
	}
	s.rec = r
	return s
}

// partyPosition is a record's position: the region and the region-local x,
// y (height), z, each truncated to an integer as ftol does (READ, GS
// 0x5bb030..0x5bb05d, from pc+0x84..+0x90).
func partyPosition(e world.Entity) (region uint16, x, y, z int32) {
	fx, fy, ok := entityFrame(e.Zone)
	if !ok {
		return 0, int32(e.Pos.X), int32(e.Pos.Y), int32(e.Pos.Z)
	}
	rx, ry, lx, lz := worldmap.FromWorld(e.Pos.X, e.Pos.Z, fx, fy)
	return uint16(worldmap.RegionID(rx, ry)), int32(lx), int32(e.Pos.Y), int32(lz)
}

// topMasteries is the two masteries a record shows. OURS: the engine's pick
// (GObjPC::FUN_005a1890) is OPEN; OpenSRO shows the two highest-levelled
// masteries above level 0, the lower id first on a tie, and 0 for an empty
// slot (a new character shows none, as the user's screenshot 08 does).
func topMasteries(levels map[int64]int) (uint32, uint32) {
	type ml struct {
		id  int64
		lvl int
	}
	var all []ml
	for id, lvl := range levels {
		if lvl > 0 {
			all = append(all, ml{id, lvl})
		}
	}
	sort.Slice(all, func(i, j int) bool {
		if all[i].lvl != all[j].lvl {
			return all[i].lvl > all[j].lvl
		}
		return all[i].id < all[j].id
	})
	var m [2]uint32
	for i := 0; i < len(all) && i < 2; i++ {
		m[i] = uint32(all[i].id)
	}
	return m[0], m[1]
}

// partyRecordBook is what the members last heard of each member: the record
// the updates compare against (retail keeps it in the party's member list, GS
// FUN_005bb0c0's edi), with the raw HP/MP it was last sampled at.
type partyRecordBook struct {
	mu sync.Mutex
	m  map[int64]memberSample
}

var partyRecords = &partyRecordBook{m: map[int64]memberSample{}}

func (b *partyRecordBook) set(id int64, s memberSample) {
	b.mu.Lock()
	b.m[id] = s
	b.mu.Unlock()
}

func (b *partyRecordBook) get(id int64) (memberSample, bool) {
	b.mu.Lock()
	defer b.mu.Unlock()
	s, ok := b.m[id]
	return s, ok
}

// replace stores s for id only while id is still filed: a sample taken just
// before the member left must not file it again.
func (b *partyRecordBook) replace(id int64, s memberSample) {
	b.mu.Lock()
	if _, ok := b.m[id]; ok {
		b.m[id] = s
	}
	b.mu.Unlock()
}

func (b *partyRecordBook) forget(id int64) {
	b.mu.Lock()
	delete(b.m, id)
	b.mu.Unlock()
}

// partyUpdate compares a member's sample with what the members last heard and
// returns the kind-6 record of what changed (mask 0 when nothing did), by
// FUN_005bb0c0's rules (READ): level; HP/MP by the update formula
// (party.HPMPUpdate), sent only when a step moved; position; guild; masteries;
// name and model. An update never carries the JID or the job.
//
// The engine evaluates HP/MP only on its HP/MP event (bit 2 of vslot_323,
// raised by GObjPC::FUN_004a8510 when a value changes). A sampler must not
// evaluate it on every sample, or a full record's HP of 10 would turn into
// the update formula's 11 with nothing having happened; so the rule runs only
// when a raw HP, MP or maximum moved since the last sample (OURS, the
// sampler's stand-in for the event).
func partyUpdate(prev, now memberSample) party.Record {
	u := now.rec
	u.Mask = 0
	if now.rec.Level != prev.rec.Level {
		u.Mask |= party.MaskLevel
	}
	u.HPMP = prev.rec.HPMP
	if now.hp != prev.hp || now.maxHP != prev.maxHP || now.mp != prev.mp || now.maxMP != prev.maxMP {
		if b, changed := party.HPMPUpdate(prev.rec.HPMP, now.hp, now.maxHP, now.mp, now.maxMP); changed {
			u.Mask |= party.MaskHPMP
			u.HPMP = b
		}
	}
	p, n := prev.rec, now.rec
	if n.Region != p.Region || n.X != p.X || n.Y != p.Y || n.Z != p.Z || n.WorldID != p.WorldID {
		u.Mask |= party.MaskPosition
	}
	if n.Guild != p.Guild {
		u.Mask |= party.MaskGuild
	}
	if n.Mastery1 != p.Mastery1 || n.Mastery2 != p.Mastery2 {
		u.Mask |= party.MaskMastery
	}
	if n.Name != p.Name || n.RefObjID != p.RefObjID {
		u.Mask |= party.MaskName
	}
	return u
}

// RunPartyUpdates samples every party member's record each
// partyUpdateInterval and sends the changes as 0x3864 kind 6 to the other
// members (READ, GS 0x5bdbd0: BroadcastToLocalMember(msg, jid) skips the
// member updated). Returns when ctx ends.
func RunPartyUpdates(ctx context.Context, d PartyDeps) {
	if d.Parties == nil {
		return
	}
	t := time.NewTicker(partyUpdateInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.sendPartyUpdates(ctx)
		}
	}
}

func (d PartyDeps) sendPartyUpdates(ctx context.Context) {
	for _, p := range d.Parties.All() {
		for _, m := range p.Members {
			prev, ok := partyRecords.get(m.CharacterID)
			if !ok {
				continue
			}
			now := d.sample(ctx, m)
			u := partyUpdate(prev, now)
			// What the members now hold: the new fields, with the HP/MP byte
			// the update formula left (unchanged unless it was sent).
			now.rec.HPMP = u.HPMP
			partyRecords.replace(m.CharacterID, now)
			if u.Mask == 0 {
				continue
			}
			msg := party.EncodeUpdate(m.JID(), &u)
			for _, o := range p.Members {
				if o.CharacterID != m.CharacterID {
					sendParty(o.Session, party.OpEvent, msg)
				}
			}
		}
	}
}
