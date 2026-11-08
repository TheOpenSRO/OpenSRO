package main

// Round 865 stage 2 (lane AS), a QA aid: the academy's live check on its
// real wire (docs/protocol/academy.md sections 6 and 7) with five
// characters on a running server:
//
//	partybot -mode academy -addr HOST:PORT [-prefix ac] [-keeper 2013]
//
// G (70) founds a camp at the storage keeper (-keeper, its reference id;
// the server needs -npcs-csv / -npcpos-csv), invites X (60, refused 3), A
// (1), S (40) -- a refusal 0x6811, a 30 s timeout 0x000E, an acceptance --,
// chats, writes the notice, logs A out and in again and walks it, takes the
// 24 h refusals, moves the academy clock with the GM's /academytime, bans A
// (and meets its invite penalty), lets S leave, graduates P (1 -> 40), lists
// the honor rank and the matching board and disbands. Every academy message
// each character receives is printed with its time; the run exits 1 on the
// first byte or order that differs from the spec's. The bots' accounts must
// be in -gm-accounts (their levels, gold and the clock are GM commands).

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/academy"
	"github.com/TheOpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

var (
	academyKeeper = flag.Int("keeper", 2013, "academy: the storage keeper's reference id (NPC_CH_WAREHOUSE_M in Jangan)")
	academyAt     = flag.String("academy-at", "24 -32 -26", "academy: where the bots stand (world x y z), beside the keeper")
)

// isAcademyOp is what the academy run reads from the bots' streams.
func isAcademyOp(op uint16) bool {
	switch {
	case op >= 0xB470 && op <= 0xB483, op == proto.OpAcademyUpdate, op == proto.OpAcademyInfo,
		op == proto.OpAcademySaveBuff, op == proto.OpAcademySaveBuffTime, op == proto.OpAcademyReserveBuffTime,
		op == party.OpInvitation, op == charmsg.OpCharInfo, op == npctalk.OpSelectResult,
		op == session.OpChatResult, op == session.OpChatUpdate:
		return true
	}
	return false
}

// acNext is the next academy message b was sent within wait.
func (b *bot) acNext(wait time.Duration) (*proto.Packet, error) {
	select {
	case p, ok := <-b.acad:
		if !ok {
			return nil, fmt.Errorf("%s: connection closed", b.name)
		}
		return p, nil
	case <-time.After(wait):
		return nil, fmt.Errorf("%s: nothing arrived in %s", b.name, wait)
	}
}

// acWant reads b's next message on op (stepping over the others of the
// stream, printed) and checks its body with ok.
func (b *bot) acWant(what string, op uint16, ok func([]byte) bool) ([]byte, error) {
	deadline := time.Now().Add(5 * time.Second)
	for {
		p, err := b.acNext(time.Until(deadline))
		if err != nil {
			return nil, fmt.Errorf("%s: %w", what, err)
		}
		fmt.Printf("%s [%s] <- %04X % x\n", time.Now().Format("15:04:05.000"), b.name, p.Opcode, p.Data)
		if p.Opcode != op {
			if op == proto.OpAcademyUpdate && p.Opcode == charmsg.OpCharInfo {
				continue
			}
			if p.Opcode == session.OpChatUpdate || p.Opcode == npctalk.OpSelectResult || p.Opcode == charmsg.OpCharInfo {
				continue
			}
			return nil, fmt.Errorf("%s: %s got %04X % x, want %04X", b.name, what, p.Opcode, p.Data, op)
		}
		if ok != nil && !ok(p.Data) {
			return nil, fmt.Errorf("%s: %s: got % x", b.name, what, p.Data)
		}
		fmt.Printf("    PASS %s\n", what)
		return p.Data, nil
	}
}

// acExact is acWant with the body exactly want.
func (b *bot) acExact(what string, op uint16, want []byte) error {
	_, err := b.acWant(what, op, func(got []byte) bool { return bytes.Equal(got, want) })
	if err != nil {
		return fmt.Errorf("%w (want % x)", err, want)
	}
	return nil
}

// acQuiet checks b is sent no academy message for a moment.
func (b *bot) acQuiet(what string, op uint16) error {
	end := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(end) {
		p, err := b.acNext(time.Until(end))
		if err != nil {
			break
		}
		fmt.Printf("%s [%s] <- %04X % x\n", time.Now().Format("15:04:05.000"), b.name, p.Opcode, p.Data)
		if p.Opcode == op {
			return fmt.Errorf("%s: %s: unexpected % x", b.name, what, p.Data)
		}
	}
	fmt.Printf("    PASS %s\n", what)
	return nil
}

func le32(v uint32) []byte { return binary.LittleEndian.AppendUint32(nil, v) }

func lestr(s string) []byte {
	return append(binary.LittleEndian.AppendUint16(nil, uint16(len(s))), s...)
}

func cat(parts ...[]byte) []byte { return bytes.Join(parts, nil) }

func online(id int64, on bool) []byte {
	st := academy.PlayOffline
	if on {
		st = academy.PlayOnline
	}
	return academy.EncodeFieldU8(id, academy.FieldPlayState, st)
}

// isPos checks a 0x3C80 0d about id with name and the open world.
func isPos(id int64, name string) func([]byte) bool {
	return func(d []byte) bool {
		return len(d) > 5 && d[0] == academy.PushPosition && binary.LittleEndian.Uint32(d[1:]) == uint32(id) &&
			bytes.HasPrefix(d[5:], cat(lestr(name), le32(academy.WorldOpen)))
	}
}

// isJoined checks a 0x3C80 02 about id: play state 1, no place, no name.
func isJoined(campID uint32, id int64, name string) func([]byte) bool {
	return func(d []byte) bool {
		head := cat([]byte{academy.PushJoined}, le32(campID), le32(uint32(id)))
		tail := cat([]byte{academy.PlayOffline}, make([]byte, 4+2+6), lestr(""))
		return bytes.HasPrefix(d, head) && bytes.HasSuffix(d, tail) && bytes.Contains(d, lestr(name))
	}
}

func academyRun(addr, prefix string) error {
	type who struct {
		user, name string
		level      int
	}
	people := []who{{prefix + "g", prefix + "G", 70}, {prefix + "x", prefix + "X", 60}, {prefix + "a", prefix + "A", 1},
		{prefix + "s", prefix + "S", 40}, {prefix + "p", prefix + "P", 1}}
	bots := map[string]*bot{}
	for _, w := range people {
		b, err := connect(addr, w.user, w.name, w.level)
		if err != nil {
			return err
		}
		go func(b *bot) {
			for range b.in {
			}
		}(b)
		bots[w.name[len(prefix):]] = b
	}
	g, x, a, s, p := bots["G"], bots["X"], bots["A"], bots["S"], bots["P"]
	// Everyone beside the keeper (-at, world x y z of the Jangan frame:
	// NPC_CH_WAREHOUSE_M stands at local 980.8, 989.1 of region 25000).
	var ax, ay, az float32
	fmt.Sscanf(*academyAt, "%f %f %f", &ax, &ay, &az)
	g.moveTo(ax, ay, az)
	g.x, g.y, g.z = ax, ay, az
	for i, b := range []*bot{x, a, s, p} {
		b.moveTo(ax+float32(i+1), ay, az+1)
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
		return fmt.Errorf("the storage keeper %d is not in G's view (start the server with -npcs-csv / -npcpos-csv)", *academyKeeper)
	}
	if _, err := g.gm("/gold 200000"); err != nil {
		return err
	}
	fail := academy.EncodeFail
	steps := []struct {
		what string
		do   func() error
	}{
		{"G selects the keeper", func() error {
			g.send(npctalk.OpSelect, le32(keeper))
			_, err := g.acWant("0xB045", npctalk.OpSelectResult, nil)
			return err
		}},
		{"founding: 0x304E, 0xB470 {1, CampInfo} (own play state 1), 05 field 1 = 0", func() error {
			g.send(proto.OpAcademyOpenRequest, le32(keeper))
			if _, err := g.acWant("0x304E gold", charmsg.OpCharInfo, func(d []byte) bool { return d[0] == charmsg.CharInfoGold }); err != nil {
				return err
			}
			res, err := g.acWant("0xB470 ok", proto.OpAcademyOpenAck, func(d []byte) bool { return d[0] == 1 })
			if err != nil {
				return err
			}
			academyCamp = binary.LittleEndian.Uint32(res[1:])
			return g.acExact("05 G online", proto.OpAcademyUpdate, online(g.id, true))
		}},
		{"invite a level-60 X: 0xB472 {2, 3}", func() error {
			g.send(proto.OpAcademyInviteRequest, le32(uint32(x.id)))
			return g.acExact("0xB472 3", proto.OpAcademyInviteAck, fail(3))
		}},
		{"invite A: 0x3080 kind 9, accept, 02 / 0a / 0d / 05", func() error {
			g.send(proto.OpAcademyInviteRequest, le32(uint32(a.id)))
			if err := a.acExact("0x3080 kind 9", party.OpInvitation, academy.EncodeInvitation(uint32(g.id), g.name)); err != nil {
				return err
			}
			a.send(party.OpInvitation, []byte{1, 1})
			if _, err := g.acWant("02 A", proto.OpAcademyUpdate, isJoined(academyCamp, a.id, a.name)); err != nil {
				return err
			}
			if _, err := a.acWant("0a 01", proto.OpAcademyUpdate, func(d []byte) bool { return d[0] == academy.PushJoin && d[1] == 1 }); err != nil {
				return err
			}
			if _, err := g.acWant("0d A", proto.OpAcademyUpdate, isPos(a.id, a.name)); err != nil {
				return err
			}
			if err := g.acExact("05 A online (G)", proto.OpAcademyUpdate, online(a.id, true)); err != nil {
				return err
			}
			if err := a.acExact("05 A online (A)", proto.OpAcademyUpdate, online(a.id, true)); err != nil {
				return err
			}
			return g.acQuiet("no 0xB472 on success", proto.OpAcademyInviteAck)
		}},
		{"S refuses: 0x6811 both ways", func() error {
			g.send(proto.OpAcademyInviteRequest, le32(uint32(s.id)))
			if _, err := s.acWant("0x3080", party.OpInvitation, nil); err != nil {
				return err
			}
			s.send(party.OpInvitation, []byte{2, 0, 0})
			if err := g.acExact("0xB472 0x6811", proto.OpAcademyInviteAck, fail(0x6811)); err != nil {
				return err
			}
			return s.acExact("0a 02 0x6811", proto.OpAcademyUpdate, academy.EncodeJoinFail(0x6811))
		}},
		{"S does not answer: 0x000E both ways after 30 s", func() error {
			g.send(proto.OpAcademyInviteRequest, le32(uint32(s.id)))
			t0 := time.Now()
			if _, err := s.acWant("0x3080", party.OpInvitation, nil); err != nil {
				return err
			}
			r, err := g.acNext(32 * time.Second)
			if err != nil {
				return err
			}
			fmt.Printf("%s [%s] <- %04X % x\n", time.Now().Format("15:04:05.000"), g.name, r.Opcode, r.Data)
			if r.Opcode != proto.OpAcademyInviteAck || !bytes.Equal(r.Data, fail(0x000e)) {
				return fmt.Errorf("timeout reply %04X % x", r.Opcode, r.Data)
			}
			fmt.Printf("    PASS 0xB472 0e 00 after %.1f s\n", time.Since(t0).Seconds())
			return s.acExact("0a 02 0e 00", proto.OpAcademyUpdate, academy.EncodeJoinFail(0x000e))
		}},
		{"S accepts (assistant)", func() error {
			g.send(proto.OpAcademyInviteRequest, le32(uint32(s.id)))
			if _, err := s.acWant("0x3080", party.OpInvitation, nil); err != nil {
				return err
			}
			s.send(party.OpInvitation, []byte{1, 1})
			for _, b := range []*bot{g, a} {
				if _, err := b.acWant("02 S", proto.OpAcademyUpdate, isJoined(academyCamp, s.id, s.name)); err != nil {
					return err
				}
				if _, err := b.acWant("0d S", proto.OpAcademyUpdate, isPos(s.id, s.name)); err != nil {
					return err
				}
				if err := b.acExact("05 S online", proto.OpAcademyUpdate, online(s.id, true)); err != nil {
					return err
				}
			}
			if _, err := s.acWant("0a 01", proto.OpAcademyUpdate, func(d []byte) bool { return d[0] == academy.PushJoin && d[1] == 1 }); err != nil {
				return err
			}
			return s.acExact("05 S online (S)", proto.OpAcademyUpdate, online(s.id, true))
		}},
		{"chat: the result to A, the line to every member", func() error {
			a.send(session.OpChatSend, (&session.ChatSendRequest{Type: session.ChatAcademy, Index: 7, Message: "academy hi"}).Encode())
			if _, err := a.acWant("chat result", session.OpChatResult, func(d []byte) bool {
				r, err := session.DecodeChatResult(d)
				return err == nil && r.OK && r.Type == session.ChatAcademy && r.Index == 7
			}); err != nil {
				return err
			}
			for _, b := range []*bot{g, a, s} {
				if err := waitChat(b, a.name, "academy hi"); err != nil {
					return err
				}
			}
			return nil
		}},
		{"notice: 07 to every member, then 0xB477 {1}", func() error {
			g.send(proto.OpAcademyNoticeRequest, cat(lestr("Hello Academy"), lestr("Test notice line")))
			n := academy.EncodeNotice("Hello Academy", "Test notice line")
			if err := g.acExact("07 (writer)", proto.OpAcademyUpdate, n); err != nil {
				return err
			}
			if err := g.acExact("0xB477", proto.OpAcademyNoticeAck, []byte{1}); err != nil {
				return err
			}
			for _, b := range []*bot{a, s} {
				if err := b.acExact("07", proto.OpAcademyUpdate, n); err != nil {
					return err
				}
			}
			return nil
		}},
		{"A walks: 0d to the others", func() error {
			a.moveTo(g.x+25, g.y, g.z+25)
			for _, b := range []*bot{g, s} {
				if _, err := b.acWant("0d A", proto.OpAcademyUpdate, isPos(a.id, a.name)); err != nil {
					return err
				}
			}
			return nil
		}},
		{"A logs out: 05 field 1 = 1 to the others", func() error {
			a.conn.Close()
			for _, b := range []*bot{g, s} {
				if err := b.acExact("05 A offline", proto.OpAcademyUpdate, online(a.id, false)); err != nil {
					return err
				}
			}
			return nil
		}},
		{"A logs in: 0x3C81 then 05 to A; 0d then 05 to the others", func() error {
			nb, err := connect(addr, prefix+"a", a.name, 1)
			if err != nil {
				return err
			}
			go func() {
				for range nb.in {
				}
			}()
			a = nb
			info, err := a.acWant("0x3C81", proto.OpAcademyInfo, nil)
			if err != nil {
				return err
			}
			if !bytes.Contains(info, cat([]byte{academy.PlayOffline}, le32(academy.WorldOpen))) || !bytes.Contains(info, lestr(a.name)) {
				return fmt.Errorf("0x3C81 % x: want A's own entry at play state 1 with its name", info)
			}
			if err := a.acExact("05 A online (A)", proto.OpAcademyUpdate, online(a.id, true)); err != nil {
				return err
			}
			for _, b := range []*bot{g, s} {
				if _, err := b.acWant("0d A", proto.OpAcademyUpdate, isPos(a.id, a.name)); err != nil {
					return err
				}
				if err := b.acExact("05 A online", proto.OpAcademyUpdate, online(a.id, true)); err != nil {
					return err
				}
			}
			return nil
		}},
		{"inside 24 h: leave 0x6821 on 0xB473, ban 0x6820", func() error {
			a.send(proto.OpAcademyLeaveRequest, nil)
			if err := a.acExact("leave", proto.OpAcademyBanAck, fail(0x6821)); err != nil {
				return err
			}
			g.send(proto.OpAcademyBanRequest, lestr(a.name))
			return g.acExact("ban", proto.OpAcademyBanAck, fail(0x6820))
		}},
		{"disband inside 7 days: 0xB471 {2, 0x681d, u32 seconds}", func() error {
			g.send(proto.OpAcademyDisbandRequest, nil)
			_, err := g.acWant("0xB471 0x681d", proto.OpAcademyDisbandAck, func(d []byte) bool {
				return len(d) == 7 && bytes.HasPrefix(d, fail(0x681d)) && binary.LittleEndian.Uint32(d[3:]) > 604000
			})
			return err
		}},
		{"/academytime 25h; ban A: 0xB473 {1}, 03 reason 2 to all", func() error {
			if _, err := g.gm("/academytime 25h"); err != nil {
				return err
			}
			g.send(proto.OpAcademyBanRequest, lestr(a.name))
			if err := g.acExact("ban ok", proto.OpAcademyBanAck, []byte{1}); err != nil {
				return err
			}
			for _, b := range []*bot{g, a, s} {
				if err := b.acExact("03 A 2", proto.OpAcademyUpdate, academy.EncodeRemoved(a.id, academy.RemoveBanned)); err != nil {
					return err
				}
			}
			g.send(proto.OpAcademyInviteRequest, le32(uint32(a.id)))
			return g.acExact("the guardian's invite penalty 0x681f", proto.OpAcademyInviteAck, fail(0x681f))
		}},
		{"S leaves: 0xB474 {1}, 03 reason 1", func() error {
			s.send(proto.OpAcademyLeaveRequest, nil)
			if err := s.acExact("0xB474", proto.OpAcademyLeaveAck, []byte{1}); err != nil {
				return err
			}
			for _, b := range []*bot{g, s} {
				if err := b.acExact("03 S 1", proto.OpAcademyUpdate, academy.EncodeRemoved(s.id, academy.RemoveLeft)); err != nil {
					return err
				}
			}
			return nil
		}},
		{"/academytime 25h; P joins, levels to 40, graduates: 05 6 / 2, 0xB475, 04 kind 1, honor", func() error {
			if _, err := g.gm("/academytime 25h"); err != nil {
				return err
			}
			g.send(proto.OpAcademyInviteRequest, le32(uint32(p.id)))
			if _, err := p.acWant("0x3080", party.OpInvitation, nil); err != nil {
				return err
			}
			p.send(party.OpInvitation, []byte{1, 1})
			if _, err := p.acWant("0a 01", proto.OpAcademyUpdate, func(d []byte) bool { return d[0] == academy.PushJoin && d[1] == 1 }); err != nil {
				return err
			}
			p.acExact("05 P online", proto.OpAcademyUpdate, online(p.id, true))
			for i := 0; i < 3; i++ {
				g.acNext(time.Second)
			}
			p.send(proto.OpAcademyGraduationRequest, []byte{4})
			if err := p.acExact("too low 0x681a", proto.OpAcademyGraduationAck, fail(0x681a)); err != nil {
				return err
			}
			if _, err := p.gm("/level 40"); err != nil {
				return err
			}
			for _, b := range []*bot{g, p} {
				if err := b.acExact("05 P 6", proto.OpAcademyUpdate, academy.EncodeFieldU8(p.id, academy.FieldCurLevel, 40)); err != nil {
					return err
				}
				if err := b.acExact("05 P 2", proto.OpAcademyUpdate, academy.EncodeFieldU8(p.id, academy.FieldMaxLevel, 40)); err != nil {
					return err
				}
			}
			p.send(proto.OpAcademyGraduationRequest, []byte{4})
			if err := p.acExact("0xB475", proto.OpAcademyGraduationAck, []byte{1}); err != nil {
				return err
			}
			for _, b := range []*bot{g, p} {
				if err := b.acExact("04 P 1", proto.OpAcademyUpdate, academy.EncodeGraduated(p.id, 1)); err != nil {
					return err
				}
			}
			return g.acExact("05 G 3 honor 39", proto.OpAcademyUpdate, academy.EncodeFieldU32(g.id, academy.FieldHonor, 39))
		}},
		{"honor rank list at the keeper: 0xB478 {1, 0}", func() error {
			g.send(npctalk.OpSelect, le32(keeper))
			g.acWant("0xB045", npctalk.OpSelectResult, nil)
			g.send(proto.OpAcademyHonorRankRequest, le32(keeper))
			return g.acExact("0xB478", proto.OpAcademyHonorRankAck, []byte{1, 0})
		}},
		{"matching board: register, list, delete", func() error {
			g.send(proto.OpAcademyMatchList, []byte{0})
			if err := g.acExact("0xB47D empty", proto.OpAcademyMatchListAck, []byte{1, 0, 0, 0}); err != nil {
				return err
			}
			g.send(proto.OpAcademyMatchEntry, cat(le32(0), le32(academyCamp), []byte{1}, lestr("Join us")))
			if err := g.acExact("0xB47A", proto.OpAcademyMatchEntryAck, cat([]byte{1}, le32(1), le32(academyCamp), []byte{1}, lestr("Join us"), le32(1))); err != nil {
				return err
			}
			g.send(proto.OpAcademyMatchList, []byte{0})
			if _, err := g.acWant("0xB47D one row", proto.OpAcademyMatchListAck, func(d []byte) bool {
				return bytes.HasPrefix(d, []byte{1, 1, 0, 1}) && bytes.Contains(d, lestr(g.name))
			}); err != nil {
				return err
			}
			g.send(proto.OpAcademyMatchDelete, le32(1))
			return g.acExact("0xB47C", proto.OpAcademyMatchDeleteAck, cat([]byte{1}, le32(1)))
		}},
		{"/academytime 7d; disband: 0xB471 {1}, 01; reopen 0x681c + 604,800 s", func() error {
			if _, err := g.gm("/academytime 168h"); err != nil {
				return err
			}
			g.send(proto.OpAcademyDisbandRequest, nil)
			if err := g.acExact("0xB471", proto.OpAcademyDisbandAck, []byte{1}); err != nil {
				return err
			}
			if err := g.acExact("01", proto.OpAcademyUpdate, []byte{1}); err != nil {
				return err
			}
			g.send(npctalk.OpSelect, le32(keeper))
			g.acWant("0xB045", npctalk.OpSelectResult, nil)
			g.send(proto.OpAcademyOpenRequest, le32(keeper))
			return g.acExact("reopen", proto.OpAcademyOpenAck, academy.EncodeFailSeconds(0x681c, 604800))
		}},
	}
	for i, st := range steps {
		fmt.Printf("== step %d: %s\n", i+1, st.what)
		if err := st.do(); err != nil {
			return fmt.Errorf("step %d (%s): %w", i+1, st.what, err)
		}
	}
	fmt.Println("academy run: every step passed")
	return nil
}

// academyCamp is the camp the run founded.
var academyCamp uint32

// waitChat reads b's stream to the academy line from sender.
func waitChat(b *bot, sender, text string) error {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		p, err := b.acNext(time.Until(deadline))
		if err != nil {
			return err
		}
		fmt.Printf("%s [%s] <- %04X % x\n", time.Now().Format("15:04:05.000"), b.name, p.Opcode, p.Data)
		if p.Opcode != session.OpChatUpdate {
			continue
		}
		if u, err := session.DecodeChatUpdate(p.Data); err == nil && u.Type == session.ChatAcademy && u.Sender == sender && u.Message == text {
			fmt.Printf("    PASS %s hears the line\n", b.name)
			return nil
		}
	}
	return fmt.Errorf("%s: no academy line from %s", b.name, sender)
}
