package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
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
}
