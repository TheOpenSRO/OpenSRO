package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// botGuild844 (round 844, lane G, a QA aid): the guild master's own
// requests from a bot.
//   - -guild-perm "NAME=MASK@20s;NAME2=MASK@40s" sends 0x7104 {1, {NAME's id,
//     MASK}} that long after entry, once NAME is in view (its id is the
//     spawned player's unique id, which is its character id here).
var botGuild844 struct {
	perm string
}

func init() {
	flag.StringVar(&botGuild844.perm, "guild-perm", "", "bot (round 844 G): \"NAME=MASK@20s;...\" -- the master's 0x7104 for NAME at that time after entry")
}

type guildPermStep struct {
	name string
	mask uint32
	at   time.Duration
}

func parseGuildPerm(s string) []guildPermStep {
	var out []guildPermStep
	for _, item := range splitSemi(s) {
		eq := strings.IndexByte(item, '=')
		atI := strings.IndexByte(item, '@')
		if eq <= 0 || atI <= eq {
			continue
		}
		mask, err := strconv.ParseUint(item[eq+1:atI], 0, 32)
		d, derr := time.ParseDuration(item[atI+1:])
		if err != nil || derr != nil {
			continue
		}
		out = append(out, guildPermStep{name: item[:eq], mask: uint32(mask), at: d})
	}
	return out
}

var guild844State = struct {
	start time.Time
	done  map[int]bool
}{done: map[int]bool{}}

// guild844Tick runs the timed steps (the loop's 500 ms tick).
func (b *bot) guild844Tick(name string) {
	st := &guild844State
	if st.start.IsZero() {
		st.start = time.Now()
	}
	for i, s := range parseGuildPerm(botGuild844.perm) {
		if st.done[i] || time.Since(st.start) < s.at {
			continue
		}
		id, ok := b.idOf(s.name)
		if !ok {
			continue
		}
		st.done[i] = true
		req := []byte{1}
		req = binary.LittleEndian.AppendUint32(req, uint32(id))
		req = binary.LittleEndian.AppendUint32(req, s.mask)
		_ = b.send(guild.OpPermission, req)
		fmt.Printf("[%s] -> 0x7104 permission %s(%d) = %#x\n", name, s.name, uint32(id), s.mask)
	}
	if botGuild844b.quitAfter > 0 && time.Since(st.start) >= botGuild844b.quitAfter {
		fmt.Printf("[%s] quitting (-quit-after %s)\n", name, botGuild844b.quitAfter)
		os.Exit(0)
	}
}

// Round 844 lane G part 2 (QA aids):
//   - -guild-recall-answer yes|no answers the guild recall's 0x7030 with
//     0x7031 {job, caster, yes} after -guild-recall-delay;
//   - -quit-after 60s leaves the game that long after entry (a member's
//     logout, for the master-release vote).
var botGuild844b struct {
	recallAnswer string
	recallDelay  time.Duration
	quitAfter    time.Duration
}

func init() {
	flag.StringVar(&botGuild844b.recallAnswer, "guild-recall-answer", "", "bot (round 844 G): answer the guild recall's 0x7030 yes or no")
	flag.DurationVar(&botGuild844b.recallDelay, "guild-recall-delay", 2*time.Second, "bot (round 844 G): how long before the recall answer")
	flag.DurationVar(&botGuild844b.quitAfter, "quit-after", 0, "bot (round 844 G): leave the game this long after entry")
}

// isGuild844Op: the part 2 packets the bot loop sees.
func isGuild844Op(op uint16) bool {
	switch op {
	case session.OpRecallAsk, session.OpRecallAnswerResult, session.OpVoteUpdate, session.OpGPHistoryResult:
		return true
	}
	return false
}

// guild844Packet answers the recall and prints the part 2 packets.
func (b *bot) guild844Packet(name string, p *proto.Packet) {
	if !isGuild844Op(p.Opcode) {
		return
	}
	fmt.Printf("[%s] GUILD844 %#04x % x\n", name, p.Opcode, p.Data)
	if p.Opcode != session.OpRecallAsk || len(p.Data) < 8 || botGuild844b.recallAnswer == "" {
		return
	}
	yes := byte(0)
	if botGuild844b.recallAnswer == "yes" {
		yes = 1
	}
	req := append([]byte(nil), p.Data[:8]...)
	req = append(req, yes)
	time.AfterFunc(botGuild844b.recallDelay, func() {
		_ = b.send(session.OpRecallAnswer, req)
		fmt.Printf("[%s] -> 0x7031 recall answer %d\n", name, yes)
	})
}
