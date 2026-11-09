package main

// Round 866 follow-up, a QA aid (OURS): fills a guardian's academy with
// graduates so the honor ranking can be tried on a running server.
//
//	partybot -mode academyfill -addr HOST:PORT -guardian NAME [-prefix acadbot] [-count 20] [-first 1]
//
// One bot at a time: it registers (or reuses) its account, makes or starts a
// level-1 character, finds the guardian's row on the Guardian Matching board
// (the guardian must have registered one) and applies with 0x747E. The
// guardian answers the "Join request sent" box in the game; an unanswered or
// refused application is retried (-tries). Once in, the bot takes level 40
// with the GM's /level (its account must be a GM account), graduates itself
// rating the guardian "Very satisfied" (0x7475 {4}: +5 evaluation points) and
// logs out; then the next bot applies.

import (
	"encoding/binary"
	"flag"
	"fmt"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

var (
	fillGuardian = flag.String("guardian", "", "academyfill: the guardian whose Guardian Matching entry the bots apply to")
	fillCount    = flag.Int("count", 20, "academyfill: how many bots graduate")
	fillFirst    = flag.Int("first", 1, "academyfill: the first bot's number (to resume a run)")
	fillTries    = flag.Int("tries", 5, "academyfill: applications per bot before it gives up")
)

// matchEntryOf is the entry id of guardian's row on a 0xB47D page, 0 when
// the page has none. MatchRow: u32 entry, u32 camp, u8 type, str title, u32
// time, u8 level, u8 max level, u32 RefObjID, str name, u32 graduates, u8
// rank, u32 assistants, u32 apprentices (docs/protocol/academy.md).
func matchEntryOf(d []byte, guardian string) uint32 {
	if len(d) < 4 || d[0] != 1 {
		return 0
	}
	n := int(d[3])
	p := 4
	str := func() (string, bool) {
		if p+2 > len(d) {
			return "", false
		}
		l := int(binary.LittleEndian.Uint16(d[p:]))
		p += 2
		if p+l > len(d) {
			return "", false
		}
		s := string(d[p : p+l])
		p += l
		return s, true
	}
	for i := 0; i < n; i++ {
		if p+9 > len(d) {
			return 0
		}
		entry := binary.LittleEndian.Uint32(d[p:])
		p += 9
		if _, ok := str(); !ok {
			return 0
		}
		p += 4 + 1 + 1 + 4
		name, ok := str()
		if !ok {
			return 0
		}
		p += 4 + 1 + 4 + 4
		if name == guardian {
			return entry
		}
	}
	return 0
}

func academyFillRun(addr, prefix string) error {
	if *fillGuardian == "" {
		return fmt.Errorf("academyfill needs -guardian NAME")
	}
	done := 0
	for i := *fillFirst; i < *fillFirst+*fillCount; i++ {
		user := fmt.Sprintf("%s%02d", prefix, i)
		name := fmt.Sprintf("AcadBot%02d", i)
		if err := academyFillOne(addr, user, name); err != nil {
			fmt.Printf("[%s] stopped: %v\n", name, err)
			return fmt.Errorf("%d of %d graduated; resume with -first %d: %w", done, *fillCount, i, err)
		}
		done++
		fmt.Printf("== %d of %d graduated\n", done, *fillCount)
	}
	fmt.Printf("academyfill: %d bots graduated from %s's academy\n", done, *fillGuardian)
	return nil
}

func academyFillOne(addr, user, name string) error {
	b, err := connect(addr, user, name, 1)
	if err != nil {
		return err
	}
	defer b.conn.Close()
	go func() {
		for range b.in {
		}
	}()
	time.Sleep(time.Second)
	joined := false
	for try := 1; try <= *fillTries && !joined; try++ {
		b.send(proto.OpAcademyMatchList, []byte{0})
		page, err := b.acWantFor("0xB47D", proto.OpAcademyMatchListAck, 10*time.Second)
		if err != nil {
			return err
		}
		entry := matchEntryOf(page, *fillGuardian)
		if entry == 0 {
			return fmt.Errorf("%s has no Guardian Matching entry (register one in the Matching window)", *fillGuardian)
		}
		fmt.Printf("[%s] applying to %s (entry %d), try %d: accept the box in the game\n", name, *fillGuardian, entry, try)
		b.send(proto.OpAcademyMatchJoin, le32(entry))
		res, err := b.acWantFor("0xB47E", proto.OpAcademyMatchJoinAck, 25*time.Second)
		if err != nil {
			return err
		}
		switch {
		case len(res) >= 2 && res[0] == 1 && res[1] == 1:
			joined = true
		case len(res) >= 2 && res[0] == 1:
			fmt.Printf("[%s] not accepted (cancelled); applying again\n", name)
			time.Sleep(2 * time.Second)
		default:
			return fmt.Errorf("join refused: % x", res)
		}
	}
	if !joined {
		return fmt.Errorf("not accepted after %d tries", *fillTries)
	}
	if _, err := b.gm("/level 40"); err != nil {
		return err
	}
	time.Sleep(2 * time.Second)
	b.send(proto.OpAcademyGraduationRequest, []byte{4})
	res, err := b.acWantFor("0xB475", proto.OpAcademyGraduationAck, 10*time.Second)
	if err != nil {
		return err
	}
	if len(res) < 1 || res[0] != 1 {
		return fmt.Errorf("graduation refused: % x", res)
	}
	fmt.Printf("[%s] graduated, rating %s Very satisfied\n", name, *fillGuardian)
	return nil
}

// acWantFor reads b's academy stream to the first op message within wait.
func (b *bot) acWantFor(what string, op uint16, wait time.Duration) ([]byte, error) {
	deadline := time.Now().Add(wait)
	for time.Now().Before(deadline) {
		p, err := b.acNext(time.Until(deadline))
		if err != nil {
			return nil, err
		}
		if p.Opcode == op {
			return p.Data, nil
		}
	}
	return nil, fmt.Errorf("%s: no %s within %v", b.name, what, wait)
}

// academyGuardianRun is academyfill's stand-in guardian for a dry run on a
// lane server (OURS, QA): -prefix's G founds an academy at the keeper,
// registers a Guardian Matching entry and accepts every join request
// (0x747E push -> 0x347F {job, key, 1}) until killed.
func academyGuardianRun(addr, prefix string) error {
	g, err := connect(addr, prefix+"g", prefix+"G", 70)
	if err != nil {
		return err
	}
	go func() {
		for range g.in {
		}
	}()
	var ax, ay, az float32
	fmt.Sscanf(*academyAt, "%f %f %f", &ax, &ay, &az)
	g.moveTo(ax, ay, az)
	time.Sleep(time.Second)
	var keeper uint32
	for i := 0; i < 40 && keeper == 0; i++ {
		g.mu.Lock()
		keeper = g.uidByRef[uint32(*academyKeeper)]
		g.mu.Unlock()
		time.Sleep(100 * time.Millisecond)
	}
	if keeper == 0 {
		return fmt.Errorf("the storage keeper %d is not in view", *academyKeeper)
	}
	if _, err := g.gm("/gold 200000"); err != nil {
		return err
	}
	g.send(npctalk.OpSelect, le32(keeper))
	time.Sleep(500 * time.Millisecond)
	g.send(proto.OpAcademyOpenRequest, le32(keeper))
	res, err := g.acWantFor("0xB470", proto.OpAcademyOpenAck, 10*time.Second)
	if err != nil || len(res) < 5 || res[0] != 1 {
		return fmt.Errorf("founding: % x %v", res, err)
	}
	camp := binary.LittleEndian.Uint32(res[1:])
	g.send(proto.OpAcademyMatchEntry, cat(le32(0), le32(camp), []byte{1}, lestr("Join us")))
	if _, err := g.acWantFor("0xB47A", proto.OpAcademyMatchEntryAck, 10*time.Second); err != nil {
		return err
	}
	fmt.Printf("[%s] academy %d on the board; accepting every request\n", g.name, camp)
	for {
		p, err := g.acNext(time.Hour)
		if err != nil {
			return err
		}
		if p.Opcode == proto.OpAcademyMatchJoin && len(p.Data) >= 8 {
			g.send(proto.OpAcademyMatchJoinAnswer, cat(p.Data[0:8], []byte{1}))
			fmt.Printf("[%s] accepted a request % x\n", g.name, p.Data[:8])
		}
	}
}
