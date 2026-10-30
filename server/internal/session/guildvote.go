package session

// Round 844 lane G (part 2): the master-release vote -- the guild's members
// replacing a master who has been away -- as the original's GameServer,
// CVoteManager and ShardManager run it (READ unless marked; the rules and
// their addresses are guild/vote.go's and docs/protocol/guild.md's "The
// master-release vote"):
//
//   - 0x7105 {u32 NPC}: start (any member, at the guild manager's line 0x19).
//   - 0x7106 {u32 vote}: the vote's state for the election window (line 0x1a).
//   - 0x7107 {u32 NPC, u32 vote, u8 index}: a ballot for the list's index-th.
//   - 0x3908: kind 1 started, 3 ended (1 won + the winner, 2 broken), 4 a
//     ballot moved, 5 the time left.
//
// The vote lives in memory, as the ShardManager's does: a server stop ends it
// unannounced (OURS). The winner takes the guild through the hand-over's own
// path (handOver, guildmanage.go).

import (
	"context"
	"encoding/binary"
	"log/slog"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

const (
	OpVoteStart        uint16 = 0x7105
	OpVoteStartResult  uint16 = 0xB105
	OpVoteState        uint16 = 0x7106
	OpVoteStateResult  uint16 = 0xB106
	OpVoteBallot       uint16 = 0x7107
	OpVoteBallotResult uint16 = 0xB107
	OpVoteUpdate       uint16 = 0x3908

	VoteKindStarted = 1
	VoteKindEnded   = 3
	VoteKindBallot  = 4
	VoteKindTime    = 5

	VoteResultWon    = 1
	VoteResultBroken = 2

	// The refusals (READ): category 0x10 for B105, 0x15 for B106 / B107.
	CodeVoteNotTime  uint16 = 0x4c33 // UIIT_MSG_MRELEASEERR_NOTVOTETIME
	CodeVoteRunning  uint16 = 0x4c37 // no text
	CodeVoteUnknown  uint16 = 0x5006 // no text
	CodeVoteNotVoter uint16 = 0x5008 // UIIT_MSG_MRELEASEERR_NOTVOTING
	CodeVoteLeave    uint16 = 0x4c38 // UIIT_MSG_MRELEASEERR_NOTSECEDE
	CodeVoteExpel    uint16 = 0x4c39 // UIIT_MSG_MRELEASEERR_NOTREMOVE
)

// guildVote is one running vote.
type guildVote struct {
	id      uint32
	guildID int64
	list    []int64 // candidates and voters, in the guild's member order
	ballots map[int64]int
	counts  []int
	start   time.Time
	done    chan struct{}
}

var guildVotes = struct {
	mu     sync.Mutex
	byID   map[uint32]*guildVote
	nextID uint32
	// now is the clock (tests move it).
	now func() time.Time
}{byID: map[uint32]*guildVote{}, now: time.Now}

func voteOfGuild(guildID int64) *guildVote {
	guildVotes.mu.Lock()
	defer guildVotes.mu.Unlock()
	for _, v := range guildVotes.byID {
		if v.guildID == guildID {
			return v
		}
	}
	return nil
}

func (v *guildVote) listed(id int64) bool {
	for _, x := range v.list {
		if x == id {
			return true
		}
	}
	return false
}

func (v *guildVote) remaining() time.Duration {
	left := guild.VoteDuration - guildVotes.now().Sub(v.start)
	if left < 0 {
		return 0
	}
	return left
}

// guildVoteBlocks is s:0x5c60b0 -> 0x5d1120: a listed member can neither leave
// (0x4c38) nor be expelled (0x4c39) while a vote runs; 0 when nothing blocks.
func guildVoteBlocks(guildID, characterID int64, expel bool) uint16 {
	v := voteOfGuild(guildID)
	if v == nil || !v.listed(characterID) {
		return 0
	}
	if expel {
		return CodeVoteExpel
	}
	return CodeVoteLeave
}

// appendVoteTail writes the guild block's trailing list (FUN_0099d7e0, READ
// s:0x5e7950): u8 n x {u32 vote id, u8 kind 0, u32 remaining ms}. The block
// guild.EncodeBlock makes ends with that count, 0.
func appendVoteTail(block []byte, guildID int64) []byte {
	v := voteOfGuild(guildID)
	if v == nil || len(block) == 0 || block[len(block)-1] != 0 {
		return block
	}
	block = append(block[:len(block)-1], 1)
	block = binary.LittleEndian.AppendUint32(block, v.id)
	block = append(block, 0)
	return binary.LittleEndian.AppendUint32(block, uint32(v.remaining()/time.Millisecond))
}

// isGuildVoteOp answers whether op is one of this file's requests.
func isGuildVoteOp(op uint16) bool {
	return op == OpVoteStart || op == OpVoteState || op == OpVoteBallot
}

func handleGuildVote(ctx context.Context, sess *gateway.Session, op uint16, data []byte, d guildOpsDeps) error {
	if d.hub == nil {
		return nil
	}
	e, ok := d.hub.EntityBySession(sess.ID())
	if !ok {
		return nil
	}
	switch op {
	case OpVoteStart:
		return d.voteStart(ctx, sess, e, data)
	case OpVoteState:
		return d.voteState(sess, data)
	case OpVoteBallot:
		return d.voteBallot(ctx, sess, e, data)
	}
	return nil
}

// voteStart is s:0x517600 -> 0x5c6ac0: the NPC in reach (else 3), no guild
// 0x4c0d, a vote running 0x4c37, the master online 0x4c33, the master's last
// logout under 45 days 0x4c33 (_Guild_Master_Election_Available; a master
// with no recorded logout counts as not absent, OURS); then the list
// (sm:0x436ea0): every member online now, and every offline member whose
// last logout is 7 days or fewer ago (_Guild_Is_Master_Candidators), the
// master excluded; B105 {1} to the asker and 0x3908 kind 1 to the members in
// the world.
func (d guildOpsDeps) voteStart(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 4 {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, OpVoteStartResult, guild.EncodeFail(code))
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(data)) {
		return fail(guild.CodeNotInRange)
	}
	g, err := d.guilds.GetByCharacter(ctx, e.CharacterID)
	if err != nil {
		return fail(guild.CodeNotInGuild)
	}
	if voteOfGuild(g.ID) != nil {
		return fail(CodeVoteRunning)
	}
	if _, online := entityOf(d.hub, g.LeaderID); online {
		return fail(CodeVoteNotTime)
	}
	ps, _ := d.guilds.(guild.PresenceStore)
	var logouts map[int64]time.Time
	if ps != nil {
		logouts, _ = ps.LastLogouts(ctx, g.ID)
	}
	now := guildVotes.now()
	last, ok := logouts[g.LeaderID]
	if !ok || guild.DaysSince(last, now) < guild.VoteMasterAbsentDays {
		return fail(CodeVoteNotTime)
	}
	v := &guildVote{guildID: g.ID, ballots: map[int64]int{}, start: now, done: make(chan struct{})}
	for _, m := range g.Members {
		if m.CharacterID == g.LeaderID {
			continue
		}
		if _, on := entityOf(d.hub, m.CharacterID); on {
			v.list = append(v.list, m.CharacterID)
			continue
		}
		if at, ok := logouts[m.CharacterID]; ok && guild.DaysSince(at, now) <= guild.VoteEligibleDays {
			v.list = append(v.list, m.CharacterID)
		}
	}
	v.counts = make([]int, len(v.list))
	guildVotes.mu.Lock()
	if guildVotes.nextID == 0 {
		guildVotes.nextID = 1
	}
	v.id = guildVotes.nextID
	guildVotes.nextID++
	guildVotes.byID[v.id] = v
	guildVotes.mu.Unlock()
	sendGuild(sess, OpVoteStartResult, guild.EncodeOK())
	b := []byte{VoteKindStarted}
	b = binary.LittleEndian.AppendUint32(b, v.id)
	b = append(b, 0)
	b = binary.LittleEndian.AppendUint32(b, uint32(guild.VoteDuration/time.Millisecond))
	d.toMembers(g, OpVoteUpdate, b, 0)
	slog.Info("guild master-release vote started", "guild_id", g.ID, "vote", v.id, "list", len(v.list), "by", e.CharacterID)
	go d.voteClock(v)
	return nil
}

// voteTickEvery is the clock's period (guild.VoteTick; tests shorten it).
var voteTickEvery = guild.VoteTick

// voteClock is the ShardManager's 10 s check: after the first 60 s the time
// left (kind 5) on each check; at 10 minutes kind 3 {id, 2} (broken).
func (d guildOpsDeps) voteClock(v *guildVote) {
	t := time.NewTicker(voteTickEvery)
	defer t.Stop()
	for {
		select {
		case <-v.done:
			return
		case <-t.C:
		}
		left := v.remaining()
		if left <= 0 {
			d.voteEnd(context.Background(), v, VoteResultBroken, 0)
			return
		}
		if guildVotes.now().Sub(v.start) >= guild.VoteTimeAfter {
			b := []byte{VoteKindTime}
			b = binary.LittleEndian.AppendUint32(b, v.id)
			b = binary.LittleEndian.AppendUint32(b, uint32(left/time.Millisecond))
			d.voteToMembers(v, b)
		}
	}
}

func (d guildOpsDeps) voteToMembers(v *guildVote, b []byte) {
	g, err := d.guilds.Get(context.Background(), v.guildID)
	if err != nil {
		return
	}
	d.toMembers(g, OpVoteUpdate, b, 0)
}

// voteState is CVoteManager s:0x5e7f00: an unknown vote 0x5006 (category
// 0x15, no text); else B106 {1, u32 id, u32 ms left, u8 n, n x {u32
// character, u8 votes}}. Nothing else is checked (READ).
func (d guildOpsDeps) voteState(sess *gateway.Session, data []byte) error {
	if len(data) < 4 {
		return nil
	}
	id := binary.LittleEndian.Uint32(data)
	guildVotes.mu.Lock()
	v := guildVotes.byID[id]
	var b []byte
	if v != nil {
		b = []byte{1}
		b = binary.LittleEndian.AppendUint32(b, v.id)
		b = binary.LittleEndian.AppendUint32(b, uint32(v.remaining()/time.Millisecond))
		b = append(b, byte(len(v.list)))
		for i, c := range v.list {
			b = binary.LittleEndian.AppendUint32(b, uint32(c))
			b = append(b, byte(v.counts[i]))
		}
	}
	guildVotes.mu.Unlock()
	if v == nil {
		sendGuild(sess, OpVoteStateResult, guild.EncodeFail(CodeVoteUnknown))
		return nil
	}
	sendGuild(sess, OpVoteStateResult, b)
	return nil
}

// voteBallot is s:0x517730 -> 0x5e7ea0 and sm:0x461a50: the NPC (else 3), an
// unknown vote 0x5006, a voter not on the list 0x5008, an index past the list
// 2 (OURS: the GameServer does not check it); then the ballot moves (a second
// ballot takes the first back), 0x3908 kind 4 {id, old index or 0xff, new
// index, new count} to the members, and a candidate at 60 % of the list wins
// at once. No B107 on success (READ: never sent).
func (d guildOpsDeps) voteBallot(ctx context.Context, sess *gateway.Session, e world.Entity, data []byte) error {
	if len(data) < 9 {
		return nil
	}
	fail := func(code uint16) error {
		sendGuild(sess, OpVoteBallotResult, guild.EncodeFail(code))
		return nil
	}
	if !guildNPCInReach(e, binary.LittleEndian.Uint32(data)) {
		return fail(guild.CodeNotInRange)
	}
	id := binary.LittleEndian.Uint32(data[4:])
	idx := int(data[8])
	guildVotes.mu.Lock()
	v := guildVotes.byID[id]
	if v == nil {
		guildVotes.mu.Unlock()
		return fail(CodeVoteUnknown)
	}
	if !v.listed(e.CharacterID) {
		guildVotes.mu.Unlock()
		return fail(CodeVoteNotVoter)
	}
	if idx >= len(v.list) {
		guildVotes.mu.Unlock()
		return fail(guild.CodeFailed)
	}
	old, had := v.ballots[e.CharacterID]
	oldByte := byte(0xff)
	if had {
		v.counts[old]--
		oldByte = byte(old)
	}
	v.ballots[e.CharacterID] = idx
	v.counts[idx]++
	newCount := v.counts[idx]
	won := guild.VoteWins(newCount, len(v.list))
	winner := v.list[idx]
	guildVotes.mu.Unlock()
	b := []byte{VoteKindBallot}
	b = binary.LittleEndian.AppendUint32(b, v.id)
	b = append(b, oldByte, byte(idx), byte(newCount))
	d.voteToMembers(v, b)
	if won {
		d.voteEnd(ctx, v, VoteResultWon, winner)
	}
	return nil
}

// voteEnd removes v and tells the members: kind 3 {id, result, [winner]}; a
// win then hands the guild over (sm:0x4617b0 -> _Guild_Delegate_Master, the
// hand-over's own notification).
func (d guildOpsDeps) voteEnd(ctx context.Context, v *guildVote, result byte, winner int64) {
	guildVotes.mu.Lock()
	if guildVotes.byID[v.id] != v {
		guildVotes.mu.Unlock()
		return
	}
	delete(guildVotes.byID, v.id)
	close(v.done)
	guildVotes.mu.Unlock()
	b := []byte{VoteKindEnded}
	b = binary.LittleEndian.AppendUint32(b, v.id)
	b = append(b, result)
	if result == VoteResultWon {
		b = binary.LittleEndian.AppendUint32(b, uint32(winner))
	}
	d.voteToMembers(v, b)
	slog.Info("guild master-release vote ended", "guild_id", v.guildID, "vote", v.id, "result", result, "winner", winner)
	if result != VoteResultWon {
		return
	}
	g, err := d.guilds.Get(ctx, v.guildID)
	if err != nil {
		return
	}
	if _, err := d.handOver(ctx, g, winner); err != nil {
		slog.Warn("guild vote: the hand-over failed", "guild_id", v.guildID, "winner", winner, "err", err)
	}
}

// guildVoteDisbanded drops a disbanded guild's vote silently (the
// ShardManager deletes it without a message, READ).
func guildVoteDisbanded(guildID int64) {
	if v := voteOfGuild(guildID); v != nil {
		guildVotes.mu.Lock()
		if guildVotes.byID[v.id] == v {
			delete(guildVotes.byID, v.id)
			close(v.done)
		}
		guildVotes.mu.Unlock()
	}
}

// guildMemberLoggedOut records a member's logout for the vote's day counts.
func guildMemberLoggedOut(ctx context.Context, guilds guild.Store, characterID int64) {
	if ps, ok := guilds.(guild.PresenceStore); ok {
		if err := ps.SetLastLogout(ctx, characterID, time.Now()); err != nil {
			slog.Debug("guild: last logout not saved", "character_id", characterID, "err", err)
		}
	}
}
