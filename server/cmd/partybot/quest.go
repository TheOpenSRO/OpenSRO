package main

import (
	"encoding/binary"
	"encoding/csv"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/charmsg"
	"github.com/OpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/OpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/session"
	"github.com/OpenSRO/OpenSRO/server/internal/worldmap"
)

// The quest run (round 785): one character takes real quests from the right
// NPC, does them and is paid, on the server's real wire.
//
//	partybot -mode quest -addr HOST:PORT -name Q -race china|europe -level N \
//	         -quests-dir DIR -npcs-csv npcs.csv -npcpos-csv npcpos.csv QUEST [QUEST...]
//
// The character walks nowhere: a GM /tp puts it beside each NPC (from the
// NPC table and npcpos), kills are GM-spawned monsters of the mission's own
// species brought to 1 HP by /damage and finished with a real blow, and
// every quest message is printed.

func isQuestOp(op uint16) bool {
	switch op {
	case quest.OpUpdate, quest.OpTalkPage, quest.OpRewardWindow, quest.OpTakeRewardResult, quest.OpMark, quest.OpUnmark,
		quest.OpLog, quest.OpAbandonResult, quest.OpClaimResult, npctalk.OpSelectResult, npctalk.OpOpenResult, npctalk.OpEndResult,
		charmsg.OpCharInfo:
		return true
	}
	return false
}

type npcSpot struct {
	refID  uint32
	region int
	x, z   float64
}

func loadNPCSpots(npcsCSV, npcposCSV string) (map[string][]npcSpot, error) {
	read := func(p string) ([][]string, error) {
		f, err := os.Open(p)
		if err != nil {
			return nil, err
		}
		defer f.Close()
		return csv.NewReader(f).ReadAll()
	}
	npcs, err := read(npcsCSV)
	if err != nil {
		return nil, err
	}
	pos, err := read(npcposCSV)
	if err != nil {
		return nil, err
	}
	codeOf := map[string]string{}
	for _, r := range npcs[1:] {
		codeOf[r[0]] = r[1]
	}
	out := map[string][]npcSpot{}
	for _, r := range pos[1:] {
		code, ok := codeOf[r[0]]
		if !ok {
			continue
		}
		id, _ := strconv.Atoi(r[0])
		reg, _ := strconv.Atoi(r[1])
		x, _ := strconv.ParseFloat(r[2], 64)
		z, _ := strconv.ParseFloat(r[4], 64)
		out[code] = append(out[code], npcSpot{refID: uint32(id), region: reg, x: x, z: z})
	}
	return out, nil
}

type questRun struct {
	b     *bot
	cat   *quest.Catalog
	spots map[string][]npcSpot
	gold  int64
}

// questMsg waits for the next quest-side message with op (others are printed
// and skipped).
func (r *questRun) questMsg(op uint16, d time.Duration) (*proto.Packet, error) {
	deadline := time.After(d)
	for {
		select {
		case p, open := <-r.b.quest:
			if !open {
				return nil, fmt.Errorf("connection closed waiting for 0x%04x", op)
			}
			r.print(p)
			if p.Opcode == op {
				return p, nil
			}
		case <-deadline:
			return nil, fmt.Errorf("%s: no 0x%04x within %v", r.b.name, op, d)
		}
	}
}

func readStr(b []byte) (string, []byte) {
	if len(b) < 2 {
		return "", nil
	}
	n := int(binary.LittleEndian.Uint16(b))
	if len(b) < 2+n {
		return "", nil
	}
	return string(b[2 : 2+n]), b[2+n:]
}

func (r *questRun) print(p *proto.Packet) {
	name := r.b.name
	switch p.Opcode {
	case quest.OpUpdate:
		kind, id := p.Data[0], binary.LittleEndian.Uint32(p.Data[1:])
		q := r.cat.ByID[int64(id)]
		code := "?"
		if q != nil {
			code = q.Code
		}
		line := fmt.Sprintf("[%s] <- 0x30D5 kind %d quest %d %s", name, kind, id, code)
		if (kind == 1 || kind == 2) && len(p.Data) > 9 {
			b := p.Data[5:]
			status := b[3]
			n := int(b[4])
			b = b[5:]
			line += fmt.Sprintf(" status %d missions:", status)
			for i := 0; i < n && len(b) > 2; i++ {
				idx, open := b[0], b[1]
				var text string
				text, b = readStr(b[2:])
				m := int(b[0])
				vals := []string{}
				for j := 0; j < m; j++ {
					vals = append(vals, strconv.Itoa(int(binary.LittleEndian.Uint32(b[1+4*j:]))))
				}
				b = b[1+4*m:]
				line += fmt.Sprintf(" [%d %s open=%d count=%s]", idx, text, open, strings.Join(vals, ","))
			}
		}
		fmt.Println(line)
	case quest.OpTalkPage:
		text, rest := readStr(p.Data[1:])
		line := fmt.Sprintf("[%s] <- 0x30D4 type %d %s", name, p.Data[0], text)
		if p.Data[0] == quest.PageList && len(rest) > 0 {
			n := int(rest[0])
			rest = rest[1:]
			for i := 0; i < n; i++ {
				var l string
				l, rest = readStr(rest)
				line += fmt.Sprintf(" | %d. %s", i+1, l)
			}
		}
		fmt.Println(line)
	case quest.OpRewardWindow:
		text, _ := readStr(p.Data[5:])
		fmt.Printf("[%s] <- 0x3514 reward window quest %d %s\n", name, binary.LittleEndian.Uint32(p.Data), text)
	case quest.OpTakeRewardResult:
		fmt.Printf("[%s] <- 0xB515 % x\n", name, p.Data)
	case quest.OpLog:
		fmt.Printf("[%s] <- 0x00B1 quest log %d bytes: % x\n", name, len(p.Data), p.Data[:min(len(p.Data), 16)])
	case charmsg.OpCharInfo:
		if g, _, err := charmsg.DecodeGold(p.Data); err == nil {
			fmt.Printf("[%s] <- 0x304E gold %d\n", name, g)
			r.gold = g
		}
	case quest.OpMark, quest.OpUnmark:
		// many; not printed one by one
	default:
		fmt.Printf("[%s] <- 0x%04x % x\n", name, p.Opcode, p.Data[:min(len(p.Data), 24)])
	}
}

// goTo teleports beside the NPC code and returns its unique id, read off the
// NPC spawns that arrive.
func (r *questRun) goTo(code string) (uint32, error) {
	spots := r.spots[code]
	if len(spots) == 0 {
		return 0, fmt.Errorf("no placement of %s in npcpos", code)
	}
	var target npcSpot
	var x, z float64
	found := false
	for _, s := range spots {
		rx, ry := worldmap.RegionXY(s.region)
		if wx, wz, ok := worldmap.ToZoneWorld(r.b.zone, rx, ry, s.x, s.z); ok {
			target, x, z, found = s, wx, wz, true
			break
		}
	}
	if !found {
		return 0, fmt.Errorf("%s is not in the %s frame", code, r.b.zone)
	}
	res, err := r.b.gm(fmt.Sprintf("/tp %.1f %.1f", x+8, z))
	if err != nil {
		return 0, err
	}
	fmt.Printf("[%s] /tp %.0f %.0f for %s: %s\n", r.b.name, x+8, z, code, res.Text)
	// The /tp only tells a client where to stand; the client then moves
	// there (botMode's note).
	r.b.moveTo(float32(x+8), r.b.y, float32(z))
	for i := 0; i < 30; i++ {
		time.Sleep(200 * time.Millisecond)
		r.b.mu.Lock()
		uid, ok := r.b.uidByRef[target.refID]
		r.b.mu.Unlock()
		if ok {
			fmt.Printf("[%s] beside %s (uid %d)\n", r.b.name, code, uid)
			return uid, nil
		}
	}
	r.b.mu.Lock()
	seen := len(r.b.uidByRef)
	r.b.mu.Unlock()
	return 0, fmt.Errorf("%s (ref %d) did not spawn near %.0f, %.0f (%d NPCs spawned since the /tp)", code, target.refID, x, z, seen)
}

// talk opens the NPC's talk page and returns the line for quest q (0-based).
func (r *questRun) talk(uid uint32, q *quest.Quest) (int, error) {
	r.b.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
	p, err := r.questMsg(npctalk.OpSelectResult, 3*time.Second)
	if err != nil {
		return 0, err
	}
	sel, err := npctalk.DecodeSelectNPC(p.Data)
	if err != nil {
		return 0, fmt.Errorf("select refused % x", p.Data)
	}
	if !strings.Contains(string(sel.IDs), string([]byte{npctalk.IDTalk})) {
		return 0, fmt.Errorf("the NPC offers no talk (ids % x)", sel.IDs)
	}
	r.b.send(npctalk.OpOpen, npctalk.EncodeOpen(uid, npctalk.IDTalk))
	if _, err := r.questMsg(npctalk.OpOpenResult, 3*time.Second); err != nil {
		return 0, err
	}
	p, err = r.questMsg(quest.OpTalkPage, 3*time.Second)
	if err != nil {
		return 0, err
	}
	_, rest := readStr(p.Data[1:])
	n := int(rest[0])
	rest = rest[1:]
	for i := 0; i < n; i++ {
		var l string
		l, rest = readStr(rest)
		if l == q.TextName {
			return i, nil
		}
	}
	return 0, fmt.Errorf("%s is not on the page", q.Code)
}

func (r *questRun) end(uid uint32) {
	r.b.send(npctalk.OpEnd, npctalk.EncodeEntity(uid))
	r.questMsg(npctalk.OpEndResult, 2*time.Second)
}

// do runs one quest from acceptance to reward.
func (r *questRun) do(code string) error {
	q := r.cat.ByCode[code]
	if q == nil {
		return fmt.Errorf("no quest %s in the catalogue", code)
	}
	fmt.Printf("== %s (id %d, level %d, %s): start %v, complete %s, %d missions, reward gold %d EXP %d skill EXP %d items %v\n",
		q.Code, q.ID, q.Level, q.Source, q.StartNPCs, q.CompleteNPC(), len(q.Missions), q.Reward.Gold, q.Reward.Exp, q.Reward.SPExp, q.Reward.Items)
	uid, err := r.goTo(q.StartNPCs[0])
	if err != nil {
		return err
	}
	line, err := r.talk(uid, q)
	if err != nil {
		return err
	}
	r.b.send(quest.OpTalkAnswer, []byte{byte(quest.RespListBase + line)})
	if _, err := r.questMsg(quest.OpTalkPage, 3*time.Second); err != nil {
		return err
	}
	r.b.send(quest.OpTalkAnswer, []byte{quest.RespYes})
	if _, err := r.questMsg(quest.OpUpdate, 3*time.Second); err != nil {
		return err
	}
	r.questMsg(quest.OpTalkPage, 3*time.Second)
	r.end(uid)
	for _, m := range q.Missions {
		switch m.Type {
		case quest.MissionKillMonster, quest.MissionGatherFromMonster:
			need := quest.Required(m)
			got := 0
			for kills := 0; got < need && kills < need*30+20; kills++ {
				if _, err := r.b.kill(m.Targets[0]); err != nil {
					return err
				}
				if p, err := r.questMsg(quest.OpUpdate, 1500*time.Millisecond); err == nil && p.Data[0] == quest.UpdateChange {
					got++
				}
			}
			if got < need {
				return fmt.Errorf("%s mission %d: %d of %d after the kills", q.Code, m.Index, got, need)
			}
		case quest.MissionDeliverItem, quest.MissionDialog:
			npc := m.NPC
			if m.Type == quest.MissionDialog {
				npc = q.CompleteNPC()
			}
			uid, err := r.goTo(npc)
			if err != nil {
				return err
			}
			line, err := r.talk(uid, q)
			if err != nil {
				return err
			}
			r.b.send(quest.OpTalkAnswer, []byte{byte(quest.RespListBase + line)})
			if _, err := r.questMsg(quest.OpUpdate, 3*time.Second); err != nil {
				return err
			}
			if npc != q.CompleteNPC() {
				r.questMsg(quest.OpTalkPage, 2*time.Second)
				r.end(uid)
			} else {
				return r.claim(uid, q, true)
			}
		}
	}
	uid, err = r.goTo(q.CompleteNPC())
	if err != nil {
		return err
	}
	return r.claim(uid, q, false)
}

func (r *questRun) claim(uid uint32, q *quest.Quest, opened bool) error {
	if !opened {
		line, err := r.talk(uid, q)
		if err != nil {
			return err
		}
		r.b.send(quest.OpTalkAnswer, []byte{byte(quest.RespListBase + line)})
	}
	if _, err := r.questMsg(quest.OpRewardWindow, 3*time.Second); err != nil {
		return err
	}
	_, gains := r.b.lastGain()
	r.b.send(quest.OpTakeReward, append(binary.LittleEndian.AppendUint32(nil, uint32(q.ID)), 0))
	p, err := r.questMsg(quest.OpTakeRewardResult, 3*time.Second)
	if err != nil {
		return err
	}
	if p.Data[0] != 1 {
		return fmt.Errorf("%s: reward refused % x", q.Code, p.Data)
	}
	time.Sleep(300 * time.Millisecond)
	if g, n := r.b.lastGain(); n > gains {
		fmt.Printf("[%s] reward EXP %d skill EXP %d level-up %v\n", r.b.name, g.Exp, g.SkillExp, g.LevelUp)
	}
	r.end(uid)
	fmt.Printf("== %s done\n", q.Code)
	return nil
}

func questScenario(addr, name, race string, level int, questsDir, npcsCSV, npcposCSV string, codes []string) error {
	cat, err := quest.LoadDir(questsDir)
	if err != nil {
		return err
	}
	spots, err := loadNPCSpots(npcsCSV, npcposCSV)
	if err != nil {
		return err
	}
	create := chinaKit
	if race == "europe" {
		create = europeKit
	}
	b, err := connectAs(addr, strings.ToLower(name), name, level, create)
	if err != nil {
		return err
	}
	r := &questRun{b: b, cat: cat, spots: spots}
	if _, err := r.questMsg(quest.OpLog, 5*time.Second); err != nil {
		return err
	}
	for _, code := range codes {
		if err := r.do(code); err != nil {
			return err
		}
	}
	return nil
}

var (
	chinaKit  = session.LobbyRequest{Action: session.LobbyCreate, RefObjID: 1909, Scale: 0x22, Chest: 3643, Legs: 3644, Feet: 3645, Weapon: 3632}
	europeKit = session.LobbyRequest{Action: session.LobbyCreate, RefObjID: 14875, Scale: 0x22, Chest: 11620, Legs: 11621, Feet: 11622, Weapon: 10891}
)

// noteNPCs files the NPC records of a group spawn by reference id.
func (b *bot) noteNPCs(frames []npcspawn.GroupFrame) {
	kind, recs, _, err := npcspawn.DecodeGroup(frames)
	if os.Getenv("PARTYBOT_TRACE") != "" {
		fmt.Printf("[%s] group kind %d records %d err %v\n", b.name, kind, len(recs), err)
	}
	if kind != npcspawn.GroupSpawn {
		return
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.uidByRef == nil {
		b.uidByRef = map[uint32]uint32{}
	}
	for _, r := range recs {
		b.uidByRef[r.RefID] = r.UID
	}
}
