package main

// Round 873 (OURS, a QA aid): an academy at honor rank 1 for a real client.
//
//	partybot -mode honor -addr HOST:PORT [-prefix hb] [-keeper 2013]
//
// <prefix>G (level 70) founds an academy at the storage keeper, <prefix>P
// (level 1) joins, levels to 40 and graduates, then the GM's /academytime
// 25h runs the daily rank update: the camp, the only one with points, ranks
// 1, and G is sent its four honor buffs (0x3C80 0c, then OpBuffStart for
// SKILL_TC_CROWN/GOLD/SILVER/COPPER_BUFF_01). Both then log out, so a real
// client logs in as G (account <prefix>g, password partybot-pw) as the
// academy's guardian. Both accounts must be GM accounts on the server.

import (
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

func honorRun(addr, prefix string) error {
	g, err := connect(addr, prefix+"g", prefix+"G", 70)
	if err != nil {
		return err
	}
	// Two apprentices: a graduation at level 40 pays the camp 5 evaluation
	// points (MemStore.Graduate) and a rank needs academy.RankMinPoints, 10.
	var aps []*bot
	for _, n := range []string{"p", "q"} {
		b, err := connect(addr, prefix+n, prefix+strings.ToUpper(n), 1)
		if err != nil {
			return err
		}
		aps = append(aps, b)
	}
	starts := make(chan *session.BuffStart, 64)
	g.tap = func(pk *proto.Packet) {
		if pk.Opcode == session.OpBuffStart {
			if bs, err := session.DecodeBuffStart(pk.Data); err == nil && bs.OwnerID == g.id {
				select {
				case starts <- bs:
				default:
				}
			}
		}
	}
	go func() {
		for range g.in {
		}
	}()
	for _, b := range aps {
		go func(b *bot) {
			for range b.in {
			}
		}(b)
	}
	var ax, ay, az float32
	fmt.Sscanf(*academyAt, "%f %f %f", &ax, &ay, &az)
	// A GM's /tp (the bots start where the character table puts them, and
	// a long walk is not trusted), then the step beside the keeper.
	for i, b := range append([]*bot{g}, aps...) {
		if _, err := b.gm(fmt.Sprintf("/tp %.0f %.0f", ax+float32(i), az+float32(i))); err != nil {
			return err
		}
	}
	time.Sleep(2 * time.Second)
	g.moveTo(ax, ay, az)
	for i, b := range aps {
		b.moveTo(ax+float32(i+1), ay, az+float32(i+1))
	}
	time.Sleep(time.Second)
	var keeper uint32
	for i := 0; i < 40 && keeper == 0; i++ {
		g.mu.Lock()
		keeper = g.uidByRef[uint32(*academyKeeper)]
		g.mu.Unlock()
		time.Sleep(100 * time.Millisecond)
	}
	if keeper == 0 {
		return fmt.Errorf("the storage keeper %d is not in G's view", *academyKeeper)
	}
	if _, err := g.gm("/gold 200000"); err != nil {
		return err
	}
	g.send(npctalk.OpSelect, le32(keeper))
	if _, err := g.acWant("0xB045", npctalk.OpSelectResult, nil); err != nil {
		return err
	}
	g.send(proto.OpAcademyOpenRequest, le32(keeper))
	if _, err := g.acWant("0xB470 founded", proto.OpAcademyOpenAck, func(d []byte) bool { return d[0] == 1 }); err != nil {
		return err
	}
	// The 24 h a new academy waits before it takes a member.
	if _, err := g.gm("/academytime 25h"); err != nil {
		return err
	}
	for _, p := range aps {
		g.send(proto.OpAcademyInviteRequest, le32(uint32(p.id)))
		if _, err := p.acWant("0x3080", party.OpInvitation, nil); err != nil {
			return err
		}
		p.send(party.OpInvitation, []byte{1, 1})
		if err := p.acSkipTo("0a 01", proto.OpAcademyUpdate, func(d []byte) bool { return d[0] == academy.PushJoin && d[1] == 1 }); err != nil {
			return err
		}
		if _, err := p.gm("/level 40"); err != nil {
			return err
		}
		time.Sleep(500 * time.Millisecond)
		p.send(proto.OpAcademyGraduationRequest, []byte{4})
		if err := p.acSkipTo("0xB475 graduated", proto.OpAcademyGraduationAck, func(d []byte) bool { return len(d) > 0 && d[0] == 1 }); err != nil {
			return err
		}
	}
	// The next day's 00:00: the rank update (academyClockMoved).
	if _, err := g.gm("/academytime 25h"); err != nil {
		return err
	}
	if err := g.acSkipTo("0x3C80 0c rank 1", proto.OpAcademyUpdate, func(d []byte) bool {
		return len(d) == 2 && d[0] == 0x0c && d[1] == 1
	}); err != nil {
		return err
	}
	got := map[int64]uint32{}
	deadline := time.After(5 * time.Second)
	for len(got) < 4 {
		select {
		case bs := <-starts:
			got[bs.SkillID] = bs.Token
			fmt.Printf("    G honor buff: skill %d token %d\n", bs.SkillID, bs.Token)
		case <-deadline:
			return fmt.Errorf("G was sent %d honor buffs, want 4: %v", len(got), got)
		}
	}
	fmt.Println("honor run: G's academy is at rank 1 with its four honor buffs; logging out")
	g.conn.Close()
	for _, b := range aps {
		b.conn.Close()
	}
	time.Sleep(500 * time.Millisecond)
	return nil
}

// acSkipTo reads b's academy stream to the first message on op that ok
// accepts, stepping over every other (printed), within 10 s.
func (b *bot) acSkipTo(what string, op uint16, ok func([]byte) bool) error {
	deadline := time.Now().Add(10 * time.Second)
	for {
		p, err := b.acNext(time.Until(deadline))
		if err != nil {
			return fmt.Errorf("%s: %w", what, err)
		}
		fmt.Printf("%s [%s] <- %04X % x\n", time.Now().Format("15:04:05.000"), b.name, p.Opcode, p.Data)
		if p.Opcode == op && (ok == nil || ok(p.Data)) {
			fmt.Printf("    PASS %s\n", what)
			return nil
		}
	}
}
