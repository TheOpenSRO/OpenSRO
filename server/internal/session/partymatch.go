package session

// Party matching on the original's opcodes (round 713, lane S3):
// 0x7069/0xb069 register, 0x706a/0xb06a change, 0x706b/0xb06b delete,
// 0x706c/0xb06c list page, 0x706d both ways (the request, and its relay to the
// entry's leader), 0x306e the leader's answer and 0xb06d the outcome.
// docs/protocol/party_protocol.md (round 709) is the contract; the bytes are
// internal/party/wire.go's, golden-tested.
//
// Who decides what. As in session/party.go, this file is the GameServer's
// half (its ladders, the records it attaches, the replies) and party.Matcher
// the ShardManager's (the listings, the pages, the join ladder, the job and
// its 15 s backstop). Each check is READ at its address unless it says OURS.
//
// OURS here, each labelled where it is done:
//   - the job id the leader's popup echoes (a counter);
//   - an answer is taken only from the entry's leader;
//   - the requester's two masteries (session/party.go's topMasteries);
//   - an entry's pending mark is cleared on every outcome (party.TakeJob);
//   - an accept for an entry that has since moved to a new leader is
//     refused 0x2c1c (resolveJoin);
//   - an answer whose requester JID is not the job's is dropped and the job
//     left pending (handleMatchAnswer; the engine releases it);
//   - an expired entry's owner returns to state 0 at once (party.Sweep; the
//     engine leaves the byte at 4 until a relog).

import (
	"context"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// PartyMatchDeps is what the party-match handlers read: the party's own deps
// and the listings.
type PartyMatchDeps struct {
	PartyDeps
	Match *party.Matcher
}

// PartyMatchHandler returns the handler for the party-match client messages.
func PartyMatchHandler(d PartyMatchDeps) gateway.Handler {
	return func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
		if d.Match == nil || d.Parties == nil || d.Hub == nil {
			return nil
		}
		switch p.Opcode {
		case party.OpMatchRegister:
			handleMatchRegister(ctx, sess, p.Data, d)
		case party.OpMatchChange:
			handleMatchChange(ctx, sess, p.Data, d)
		case party.OpMatchDelete:
			handleMatchDelete(ctx, sess, p.Data, d)
		case party.OpMatchList:
			handleMatchList(ctx, sess, p.Data, d)
		case party.OpMatchJoin:
			handleMatchJoin(ctx, sess, p.Data, d)
		case party.OpMatchAnswer:
			handleMatchAnswer(ctx, sess, p.Data, d)
		}
		return nil
	}
}

// matchRefuse sends [2][code] on op, as the GameServer's dispatch does for
// every party-match handler that fails (READ, GS 0x514750..0x5148b0 ->
// Msg_SendTwoFieldReply 0x4e7250).
func matchRefuse(sess *gateway.Session, op uint16, code uint16) {
	sendParty(sess, op, party.EncodeRefusal(code))
}

// partyIDOf is GObjPC::PartyID: the character's party id, 0 when in none.
func (d PartyMatchDeps) partyIDOf(characterID int64) uint32 {
	if p, in := d.Parties.Get(characterID); in {
		return p.ID
	}
	return 0
}

// checkCanCreateForMatch is CParty::CheckCanCreateForMatch (READ, GS
// 0x514170), in its order:
//   - 0x2c09 locked (OpenSRO has no lock) or not alive;
//   - 0x2c26 when chardata+0x13 is non-zero: what that byte holds is OPEN
//     (party_protocol.md), so the check is left out;
//   - 5 in job mode with an empty alias: OpenSRO has no job mode;
//   - 0x2c24 a state byte other than 0 or 2;
//   - not in a party: 0x2c0a below level 5; in a party: 0x2c1d not its leader;
//   - 0x2c28 an instance that forbids it: OpenSRO has none.
//
// Then Party_PostRequest kind 0xa's purpose rule (READ, GS 0x5bf2a0 ->
// Party_UserMatches 0x5bf240): 0x2c23.
func (d PartyMatchDeps) checkCanCreateForMatch(e world.Entity, purpose uint8) uint16 {
	if e.Life != world.LifeAlive {
		return party.CodeCreateBusy
	}
	if st := d.Parties.State(e.CharacterID); st != party.StateFree && st != party.StateInParty {
		return party.CodeMatchStateBusy
	}
	if p, in := d.Parties.Get(e.CharacterID); !in {
		if !party.CanCreate(e.Level) {
			return party.CodeTooLowCreator
		}
	} else if p.LeaderID != e.CharacterID {
		return party.CodeNotLeader
	}
	if !party.JobFitsPurpose(party.JobNone, purpose) {
		return party.CodeUserMismatch
	}
	return 1
}

// handleMatchRegister is 0x7069 (READ, GS OnRegisterPartyReq 0x514750 ->
// 0x5bf4d0 -> Party_PostRequest(10); SM 0x450680). Success is 0xb069 [1] and
// the entry echoed with the number the ShardManager assigned (READ, GS
// trs_sm_partyjob::vslot_002 0x46d3a0 reads it into the request's +0x54) and
// the requester's party id (GS 0x5bf3ed overwrites the client's 0); the
// character's state byte becomes 4 when it is in no party (GS 0x5bf858), which
// the Hub derives from the listing.
func handleMatchRegister(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	e, _, err := party.ReadEntry(data)
	if err != nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	if c := d.checkCanCreateForMatch(me, e.Purpose); c != 1 {
		matchRefuse(sess, party.OpMatchRegAck, c)
		return
	}
	e.PartyID = d.partyIDOf(me.CharacterID)
	l, err := d.Match.Register(me.CharacterID, e)
	if err != nil {
		code, _ := party.Refusal(err)
		matchRefuse(sess, party.OpMatchRegAck, code)
		return
	}
	e.Number = l.Number
	sendParty(sess, party.OpMatchRegAck, party.AppendEntry([]byte{party.ResultOK}, &e))
}

// handleMatchChange is 0x706a (READ, GS PartyMatch_HandleModify 0x5147c0 ->
// 0x5bf500): FUN_00514260's 0x2c09 locked or not alive, 0x2c1d in a party
// but not its leader, 0x2c1c no entry; the purpose rule 0x2c23 (GS
// Party_PostRequest kind 0xb); then the ShardManager's change (SM 0x450990).
// Success is 0xb06a [1] and the entry as the client sent it, the party id
// overwritten (READ, GS 0x5bf870 writes the request's entry).
func handleMatchChange(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	e, _, err := party.ReadEntry(data)
	if err != nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	refuse := func(code uint16) { matchRefuse(sess, party.OpMatchChgAck, code) }
	if me.Life != world.LifeAlive {
		refuse(party.CodeCreateBusy)
		return
	}
	if p, in := d.Parties.Get(me.CharacterID); in && p.LeaderID != me.CharacterID {
		refuse(party.CodeNotLeader)
		return
	}
	if _, _, listed := d.Parties.Listing(me.CharacterID); !listed {
		refuse(party.CodeNoEntry)
		return
	}
	if !party.JobFitsPurpose(party.JobNone, e.Purpose) {
		refuse(party.CodeUserMismatch)
		return
	}
	e.PartyID = d.partyIDOf(me.CharacterID)
	if _, err := d.Match.Change(me.CharacterID, e); err != nil {
		code, _ := party.Refusal(err)
		refuse(code)
		return
	}
	sendParty(sess, party.OpMatchChgAck, party.AppendEntry([]byte{party.ResultOK}, &e))
}

// handleMatchDelete is 0x706b (READ, GS 0x514810 -> 0x5bf530): FUN_005142c0's
// 0x2c09 locked or not alive and 0x2c1c no entry of its own; then the
// ShardManager's delete (SM 0x450ba0). Success is 0xb06b [1][u32] with the
// number the client sent (READ, GS 0x5bf900 writes the request's +0x24, read
// off the wire by Party_PostRequest kind 0xc); the state byte returns to 0
// when in no party, which the Hub derives.
func handleMatchDelete(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	num, err := party.DecodeTarget(data)
	if err != nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	refuse := func(code uint16) { matchRefuse(sess, party.OpMatchDelAck, code) }
	if me.Life != world.LifeAlive {
		refuse(party.CodeCreateBusy)
		return
	}
	if _, _, listed := d.Parties.Listing(me.CharacterID); !listed {
		refuse(party.CodeNoEntry)
		return
	}
	if err := d.Match.Delete(me.CharacterID, num); err != nil {
		code, _ := party.Refusal(err)
		refuse(code)
		return
	}
	sendParty(sess, party.OpMatchDelAck, party.EncodeOKID(num))
}

// handleMatchList is 0x706c (READ, GS 0x514860 -> Party_PostRequest(0xd), no
// GameServer check; SM 0x450d20 answers, relayed verbatim by GS 0x5bf980).
func handleMatchList(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	if len(data) < 1 {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	pages, at, rows, err := d.Match.Page(me.CharacterID, data[0], d.ownerOnline, d.raceOf(ctx))
	if err != nil {
		code, _ := party.Refusal(err)
		matchRefuse(sess, party.OpMatchListAck, code)
		return
	}
	sendParty(sess, party.OpMatchListAck, party.EncodeListPage(pages, at, rows))
}

// ownerOnline is what the page builder asks of an entry's owner (READ, SM
// 0x44f640): the character name (char+0x1a8; for a trade or thief entry the
// job alias, which OpenSRO never lists -- no job mode, and a character not in
// job mode cannot list under purposes 2 and 3). An owner not in the world
// drops its entry, as the page builder does.
func (d PartyMatchDeps) ownerOnline(owner int64) (string, bool) {
	e, ok := d.Hub.EntityByCharacterID(owner)
	if !ok {
		return "", false
	}
	return e.Name, true
}

// raceOf is an owner's race byte (READ, SM 0x44f640: char+0x250, the model's
// Country: 0 China, 1 Europe). A store read, so Page calls it outside its
// lock and only for the rows it sends.
func (d PartyMatchDeps) raceOf(ctx context.Context) party.RaceOf {
	return func(owner int64) uint8 {
		if d.Chars != nil {
			if c, err := d.Chars.GetByID(ctx, owner); err == nil && c != nil {
				return uint8(character.RaceOf(c.Gender))
			}
		}
		return uint8(character.RaceChina)
	}
}

// checkCanRequest is the GameServer's join-request check (READ, GS
// FUN_00514300), in its order: 0x2c06 locked (OpenSRO has no lock); 3 neither
// alive nor dead (a character is always one of the two here, so a dead
// character may ask); 0x2c12 in a party; then with a state byte of 0 and no
// exclusive interaction, the instance check 0x2c28 (OpenSRO has none) and
// success; a state of 1 or 3 is 0x2c1f, 4 is 0x2c25, anything else 0x2c06.
func (d PartyMatchDeps) checkCanRequest(e world.Entity) uint16 {
	if _, in := d.Parties.Get(e.CharacterID); in {
		return party.CodeExistingMember
	}
	st := d.Parties.State(e.CharacterID)
	if st == party.StateFree && !d.busy(e.CharacterID) {
		return 1
	}
	switch st {
	case party.StatePending, party.StateListedInviting:
		return party.CodeDuplicate
	case party.StateListed:
		return party.CodeListed
	}
	return party.CodeLocked
}

// handleMatchJoin is the requester's 0x706d (READ, GS 0x5148b0 -> FUN_005bf570
// -> SM 0x44f850). A refusal from either half is 0xb06d [2][code] (the
// ShardManager's comes back through GS MsgHandler_3c01 0x4169d0, which also
// drops the state byte to 0). On success the entry's leader gets the relayed
// 0x706d: the job id and the requester's JID that SM 0x422230 puts in front,
// then what GS 0x5c2db0 writes -- the entry, the requester's two masteries,
// its job state and its full record (mask 0xff).
func handleMatchJoin(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	num, err := party.DecodeTarget(data)
	if err != nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	refuse := func(code uint16) { matchRefuse(sess, party.OpMatchJoinAck, code) }
	if c := d.checkCanRequest(me); c != 1 {
		refuse(c)
		return
	}
	s := d.sample(ctx, d.memberOf(me), nil, time.Now())
	rec := s.rec
	rec.Mask = s.fullMask
	joiner := party.Joiner{CharacterID: me.CharacterID, Level: uint8(me.Level), Job: party.JobNone}
	leaderJob := func(int64) uint8 { return party.JobNone }
	online := func(c int64) bool { _, ok := d.Hub.EntityByCharacterID(c); return ok }
	job, err := d.Match.Request(joiner, num, leaderJob, online, func(j party.JoinJob) {
		d.resolveJoin(context.Background(), j, party.AnswerClosed)
	})
	if err != nil {
		code, _ := party.Refusal(err)
		refuse(code)
		return
	}
	leader, ok := d.Hub.EntityByCharacterID(job.Leader)
	if !ok {
		return
	}
	req := party.JoinRequest{JobID: job.ID, Requester: party.JIDOf(me.CharacterID), Entry: num,
		Mastery1: rec.Mastery1, Mastery2: rec.Mastery2, Job: party.JobNone, Record: rec}
	sendParty(leader.Session, party.OpMatchJoin, party.EncodeJoinRequest(&req))
}

// handleMatchAnswer is the leader's 0x306e (READ, GS FUN_00514900 forwards it
// as 0xbc00 [job][requester JID][0xb06d][answer], GS 0x4168f0; SM 0x4107e0 ->
// 0x421f70 finds the job by its id and authorizes the answer in 0x421ec0: the
// echoed JID must be the job's requester (`cmp [ebx+0x8],esi` at 0x421f3f; a
// join job's target list is empty, only the 0x7d1b branch of 0x44f850 adds
// one), else the answer is dropped with no reply). An answer other than 0, 1
// or 2 ends the job with no reply (SM 0x44fbe0 asserts and returns).
//
// OURS: only the entry's leader may answer its job -- the engine does not
// compare the sender. And an answer that fails the requester check leaves the
// job pending for the real answer or the backstop, where the engine releases
// it (with the entry's mark left set).
func handleMatchAnswer(ctx context.Context, sess *gateway.Session, data []byte, d PartyMatchDeps) {
	jobID, requester, answer, err := party.DecodeJoinAnswer(data)
	if err != nil {
		return
	}
	me, ok := d.Hub.EntityBySession(sess.ID())
	if !ok {
		return
	}
	pending, ok := d.Match.JobOf(jobID)
	if !ok || pending.Leader != me.CharacterID || requester != party.JIDOf(pending.Requester) {
		return
	}
	job, ok := d.Match.TakeJob(jobID)
	if !ok {
		return
	}
	switch answer {
	case party.AnswerCancel, party.AnswerConfirm, party.AnswerClosed:
		d.resolveJoin(ctx, job, answer)
	}
}

// resolveJoin carries out the answer to a join request, as SM 0x44fbe0 and the
// GameServer's kinds 0x11 (0xb06d, GS 0x5bfac0), 0xf (a party formed, GS
// 0x5bfbe0 -> 0x5bb460) and 0x10 (a member joined, GS 0x5bfc50) do. The job
// has already been taken.
//
//   - 0 cancel, 2 no reply: the requester gets 0xb06d [1][answer].
//   - 1, the requester gone: the leader gets 0xb06d [2][0x2c0f] (SM
//     0x44fc64..0x44fcdb).
//   - 1, the leader gone: the requester gets 0xb06d [2][0x2c0f], before the
//     entry is looked up (SM 0x44fcf4..0x44fd5e).
//   - 1, the entry gone: 0xb06d [2][0x2c1c] to the requester and the leader.
//   - 1, a leader in no party: a party of the leader and the requester, with
//     the entry's flags (SM 0x44e9c0 -> 0x44e100 adds the leader first); the
//     requester gets 0xb06d [1][1] TWICE -- the ShardManager sends the second
//     copy to the leader's GameServer but addresses it to the requester's JID
//     (READ, SM 0x45003d `mov eax,[ebx+0x78]` with ebx the requester, sent to
//     [esp+0x10]+0x1c4, the leader's server), and with one game server it
//     reaches the requester -- the leader gets none. Then the formation as
//     session/party.go's announceFormed sends it.
//   - 1, a leader in a party: the requester joins it (SM 0x44e140); the
//     requester and then the leader get 0xb06d [1][1] (READ, SM 0x450333
//     reloads ebx with the leader for the second copy), then the join as
//     announceJoined sends it.
//   - an accept that fails gives [2][code] to the requester and the leader
//     (READ, SM 0x44fe3b sends the second copy to the leader).
//
// OURS: an entry that has moved to a new leader since the request (its old
// leader left the party) refuses the accept 0x2c1c. The engine keeps the
// job's original leader (job +0x10) and would act on that character's own
// party state, forming a party around an entry it no longer owns.
func (d PartyMatchDeps) resolveJoin(ctx context.Context, job party.JoinJob, answer uint8) {
	requester, rok := d.Hub.EntityByCharacterID(job.Requester)
	leader, lok := d.Hub.EntityByCharacterID(job.Leader)
	toRequester := func(b []byte) {
		if rok {
			sendParty(requester.Session, party.OpMatchJoinAck, b)
		}
	}
	toLeader := func(b []byte) {
		if lok {
			sendParty(leader.Session, party.OpMatchJoinAck, b)
		}
	}
	if answer != party.AnswerConfirm {
		toRequester(party.EncodeJoinResult(uint16(answer)))
		return
	}
	if !rok {
		toLeader(party.EncodeRefusal(party.CodeInvalidUser))
		return
	}
	if !lok {
		toRequester(party.EncodeRefusal(party.CodeInvalidUser))
		return
	}
	fail := func(code uint16) {
		toRequester(party.EncodeRefusal(code))
		toLeader(party.EncodeRefusal(code))
	}
	l, owner, ok := d.Match.Get(job.Entry)
	if !ok || owner != job.Leader {
		fail(party.CodeNoEntry)
		return
	}
	rm, lm := d.memberOf(requester), d.memberOf(leader)
	if p, in := d.Parties.Get(job.Leader); in {
		np, err := d.Parties.Add(p.ID, rm)
		if err != nil {
			code, _ := party.Refusal(err)
			fail(code)
			return
		}
		ok := party.EncodeJoinResult(party.JoinJoined)
		toRequester(ok)
		toLeader(ok)
		d.announceJoined(ctx, np, rm)
		return
	}
	if _, in := d.Parties.Get(job.Requester); in {
		fail(party.CodeExistingMember)
		return
	}
	np, err := d.Parties.Form(lm, rm, l.Flags)
	if err != nil {
		code, _ := party.Refusal(err)
		fail(code)
		return
	}
	ok2 := party.EncodeJoinResult(party.JoinJoined)
	toRequester(ok2)
	toRequester(ok2)
	d.announceFormed(ctx, np)
}

// PartyMatchDisconnectHandler is the gateway's OnDisconnect hook for party
// matching: a party-less owner's entry goes with it (READ, SM 0x4296f0 ->
// 0x451590), and a pending join request no longer holds the requester's state
// byte (party.Matcher.Disconnect). An owner in a party is the party's: run
// PartyDisconnectHandler first, whose removal moves the entry to the next
// leader or drops it with a dissolved party, as SM 0x4296f0 runs the party
// removal 0x44f580 before the entry delete. This reads the session's
// character from the world hub, so it must run before WorldDisconnectHandler.
// A pending job is left to its answer or the 15 s backstop.
func PartyMatchDisconnectHandler(d PartyMatchDeps) func(sess *gateway.Session) {
	return func(sess *gateway.Session) {
		if d.Match == nil || d.Hub == nil {
			return
		}
		e, ok := d.Hub.EntityBySession(sess.ID())
		if !ok {
			return
		}
		d.Match.Disconnect(e.CharacterID)
	}
}

// RunPartyMatchSweep expires old entries every party.SweepInterval, as the
// ShardManager's minute timer does (READ, SM 0x40c703 -> 0x40dd10 ->
// 0x4504c0; party.Matcher.Sweep). Nothing is sent. Returns when ctx ends.
func RunPartyMatchSweep(ctx context.Context, d PartyMatchDeps) {
	if d.Match == nil {
		return
	}
	t := time.NewTicker(party.SweepInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case now := <-t.C:
			if gone := d.Match.Sweep(now); len(gone) > 0 {
				// The numbers themselves only for a handful: a crowd's
				// thousands expire together.
				if len(gone) <= 50 {
					d.log().Info("party match: entries expired", "count", len(gone), "entries", gone, "took", time.Since(now).String())
				} else {
					d.log().Info("party match: entries expired", "count", len(gone), "first", gone[0], "last", gone[len(gone)-1], "took", time.Since(now).String())
				}
			}
		}
	}
}
