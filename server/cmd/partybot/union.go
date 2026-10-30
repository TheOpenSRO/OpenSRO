package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// botUnion (round 844, lane U, a QA aid): the union flow from a bot's side.
//   - -union-request NAME asks NAME's guild into a union (0x70FB) once NAME
//     is in view and -union-request-after has passed;
//   - the request box (0x3080 kind 6) is answered by -accept (the bot's
//     generic answer: yes {1, 1}, no {2, code}); -union-box-wait waits first;
//   - -union-chat-reply answers the first union line it hears from someone
//     else with one of its own ("-<guild>): <text>", as the client's 0x7ada5a);
//   - -union-chat "20s=text;40s=text" says union lines at times after entry;
//   - -union-leave-after leaves (0x70FC) that long after its union formed.
var botUnion struct {
	request      string
	requestAfter time.Duration
	chatReply    string
	chat         string
	leaveAfter   time.Duration
}

func init() {
	flag.StringVar(&botUnion.request, "union-request", "", "bot (round 844): ask this character's guild into a union (0x70FB) once it is in view")
	flag.DurationVar(&botUnion.requestAfter, "union-request-after", 0, "bot (round 844): wait this long after first seeing the -union-request character")
	flag.StringVar(&botUnion.chatReply, "union-chat-reply", "", "bot (round 844): answer the first union line heard from someone else with this text")
	flag.StringVar(&botUnion.chat, "union-chat", "", "bot (round 844): union lines at times after entry, \"20s=hello;40s=bye\"")
	flag.DurationVar(&botUnion.leaveAfter, "union-leave-after", 0, "bot (round 844): leave the union (0x70FC) this long after it formed")
}

// unionState is one bot's progress through botUnion's steps.
type unionState struct {
	seen      time.Time
	requested bool
	retries   int
	replied   bool
	formed    bool
	leaveC    <-chan time.Time
	start     time.Time
	said      map[int]bool
	index     byte
}

var botUnionState = unionState{said: map[int]bool{}}

func isUnionOp(op uint16) bool {
	switch op {
	case guild.OpUnionInfo, guild.OpUnionRequestResult, guild.OpUnionLeaveResult, guild.OpUnionExpelResult:
		return true
	}
	return false
}

// unionSay sends one union line with the guild prefix.
func (b *bot) unionSay(name, text string) {
	st := &botUnionState
	st.index++
	msg := fmt.Sprintf("-%s): %s", botGuild.create, text)
	_ = b.send(session.OpChatSend, (&session.ChatSendRequest{Type: session.ChatUnion, Index: st.index, Message: msg}).Encode())
	fmt.Printf("[%s] -> union chat %q\n", name, msg)
}

// unionPacket looks at one packet of the bot's loop.
func (b *bot) unionPacket(name string, p *proto.Packet) {
	st := &botUnionState
	switch {
	case isUnionOp(p.Opcode):
		fmt.Printf("[%s] UNION %#04x % x\n", name, p.Opcode, p.Data)
		// A request refused while the target is still far (3), guildless
		// (0x4c25) or not yet levelled (0x4c2b) -- a client still loading
		// is in the world long before it stands near -- is asked again.
		if p.Opcode == guild.OpUnionRequestResult && len(p.Data) >= 3 && p.Data[0] == 2 && st.retries < 20 {
			switch binary.LittleEndian.Uint16(p.Data[1:]) {
			case 3, guild.ErrAllianceCantFindTargetGuild, guild.ErrAllianceJoinerTooLow:
				st.retries++
				st.requested = false
				st.seen = time.Now().Add(-botUnion.requestAfter + 10*time.Second)
				fmt.Printf("[%s] union request refused for now; again in 10 s (%d)\n", name, st.retries)
			}
		}
		if p.Opcode == guild.OpUnionInfo && !st.formed {
			st.formed = true
			if botUnion.leaveAfter > 0 {
				st.leaveC = time.After(botUnion.leaveAfter)
			}
		}
	case p.Opcode == guild.OpUpdate && len(p.Data) > 0 && (p.Data[0] == guild.UpdateUnionJoined || p.Data[0] == guild.UpdateUnionOut):
		fmt.Printf("[%s] UNION 0x38F5 % x\n", name, p.Data)
	case p.Opcode == party.OpInvitation && len(p.Data) >= 5 && p.Data[0] == guild.RequestUnion:
		fmt.Printf("[%s] UNION request box from %d\n", name, binary.LittleEndian.Uint32(p.Data[1:]))
	case p.Opcode == session.OpChatUpdate:
		u, err := session.DecodeChatUpdate(p.Data)
		if err == nil && u.Type == session.ChatUnion && u.Sender != name && botUnion.chatReply != "" && !st.replied {
			st.replied = true
			go func() {
				time.Sleep(2 * time.Second)
				b.unionSay(name, botUnion.chatReply)
			}()
		}
	}
}

// unionTick runs the timed steps (the loop's 500 ms tick).
func (b *bot) unionTick(name string) {
	st := &botUnionState
	if st.start.IsZero() {
		st.start = time.Now()
	}
	if botUnion.request != "" && !st.requested {
		if id, ok := b.idOf(botUnion.request); ok {
			if st.seen.IsZero() {
				st.seen = time.Now()
			}
			if time.Since(st.seen) >= botUnion.requestAfter {
				_ = b.send(guild.OpUnionRequest, binary.LittleEndian.AppendUint32(nil, uint32(id)))
				fmt.Printf("[%s] -> 0x70FB union request %s(%d)\n", name, botUnion.request, uint32(id))
				st.requested = true
			}
		}
	}
	for i, item := range splitTimed(botUnion.chat) {
		if !st.said[i] && time.Since(st.start) >= item.at {
			st.said[i] = true
			b.unionSay(name, item.text)
		}
	}
	if st.leaveC != nil {
		select {
		case <-st.leaveC:
			st.leaveC = nil
			_ = b.send(guild.OpUnionLeave, nil)
			fmt.Printf("[%s] -> 0x70FC union leave\n", name)
		default:
		}
	}
}

type timedText struct {
	at   time.Duration
	text string
}

// splitTimed reads "20s=text;40s=text".
func splitTimed(s string) []timedText {
	var out []timedText
	for _, item := range splitSemi(s) {
		var at time.Duration
		for i := 0; i < len(item); i++ {
			if item[i] == '=' {
				d, err := time.ParseDuration(item[:i])
				if err == nil {
					at = d
					out = append(out, timedText{at: at, text: item[i+1:]})
				}
				break
			}
		}
	}
	return out
}

func splitSemi(s string) []string {
	var out []string
	start := 0
	for i := 0; i <= len(s); i++ {
		if i == len(s) || s[i] == ';' {
			if i > start {
				out = append(out, s[start:i])
			}
			start = i + 1
		}
	}
	return out
}
