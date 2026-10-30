package main

import (
	"encoding/binary"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/guild"
)

// Round 844 (QA aids, guild war): a bot master answers a proclamation of war
// (-war-answer), proclaims one itself (-war-declare), or proposes the end of
// its first war (-war-surrender-after). Every war message is logged as a
// "WAR" line.

var botWar struct {
	answer         string
	declare        string
	after          time.Duration
	surrenderAfter time.Duration
	surrendering   bool
}

func warLog(b *bot, format string, args ...any) {
	fmt.Printf("%s [%s] WAR %s\n", time.Now().Format("15:04:05.000"), b.name, fmt.Sprintf(format, args...))
}

// noteWar reads the war's messages.
func (b *bot) noteWar(op uint16, data []byte) {
	switch {
	case op == guild.OpRequest && len(data) > 0 && data[0] == guild.RequestKindWar:
		warLog(b, "proclamation 0x3080 % x", data)
		if botWar.answer == "" {
			return
		}
		ans := byte(0)
		if botWar.answer == "accept" {
			ans = 1
		}
		b.later(func() {
			warLog(b, "answers {1, %d} (0x3080)", ans)
			_ = b.send(guild.OpRequest, []byte{1, ans})
		})
	case op == guild.OpHostileList:
		warLog(b, "hostile list 0x3109 % x", data)
	case op == guild.OpWarDeclareR || op == guild.OpWarEndR || op == guild.OpWarAskR || op == guild.OpWarClaimR:
		warLog(b, "reply %#04x % x", op, data)
	case op == guild.OpUpdate && len(data) > 0 && data[0] >= guild.UpdateWarStarted && data[0] <= guild.UpdateWarTime:
		warLog(b, "0x38F5 type %#02x % x", data[0], data[1:])
		if data[0] == guild.UpdateWarStarted && len(data) >= 5 && botWar.surrenderAfter > 0 && !botWar.surrendering {
			botWar.surrendering = true
			id := binary.LittleEndian.Uint32(data[1:])
			go func() {
				time.Sleep(botWar.surrenderAfter)
				warLog(b, "proposes the end of war %d (0x7112)", id)
				_ = b.send(guild.OpWarEnd, binary.LittleEndian.AppendUint32(nil, id))
			}()
		}
	}
}

// warSteps sends -war-declare after -war-after.
func (b *bot) warSteps() {
	if botWar.declare == "" {
		return
	}
	parts := strings.Split(botWar.declare, ",")
	if len(parts) != 6 {
		warLog(b, "-war-declare wants 6 fields, got %q", botWar.declare)
		return
	}
	n := make([]int, 5)
	for i := range n {
		v, err := strconv.Atoi(strings.TrimSpace(parts[i+1]))
		if err != nil {
			warLog(b, "-war-declare: bad number %q", parts[i+1])
			return
		}
		n[i] = v
	}
	dec := guild.WarDeclaration{Target: strings.TrimSpace(parts[0]), VictoryIndex: byte(n[0]),
		Period: guild.PackWarPeriod(n[1], n[2], n[3]), Stake: uint32(n[4])}
	go func() {
		time.Sleep(botWar.after)
		warLog(b, "proclaims war on %s (0x7110) % x", dec.Target, dec.Encode())
		_ = b.send(guild.OpWarDeclare, dec.Encode())
	}()
}
