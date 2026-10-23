package main

import (
	"encoding/binary"
	"fmt"
	"strings"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/jobs"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

// jobOpts is -mode job (round 802): one character that joins a job at its
// guild NPC, takes an alias, wears the suit (in a town, as the server
// requires), stands at -fight and, with -attack NAME, swings at that
// character on OpAttack's job-PvP target kind -- the other side of a live
// client test of job PvP.
type jobOpts struct {
	kind      int
	guild     string
	suit      int64
	alias     string
	fight     string
	attack    string
	attackID  int64
	hurt      int
	attackFor time.Duration
	stay      time.Duration
	npcsCSV   string
	npcposCSV string
}

var jobRun jobOpts

// jobMsg reports the job side's messages as they come and hands the ones
// the scenario waits on to want.
func (b *bot) jobTap(want chan *proto.Packet) func(*proto.Packet) {
	return func(p *proto.Packet) {
		switch p.Opcode {
		case jobs.OpJoinResult, jobs.OpAliasResult, session.OpEquipmentResult, session.OpInventoryListResult:
			select {
			case want <- p:
			default:
			}
		case session.OpPlayerStruck:
			d := p.Data
			if len(d) >= 22 {
				line := fmt.Sprintf("[%s] <- OpPlayerStruck attacker %d kind %d target %d damage %d flags %d hp %d/%d",
					b.name, binary.LittleEndian.Uint32(d), d[4], binary.LittleEndian.Uint32(d[5:]),
					int32(binary.LittleEndian.Uint32(d[9:])), d[13], int32(binary.LittleEndian.Uint32(d[14:])),
					int32(binary.LittleEndian.Uint32(d[18:])))
				if len(d) >= 30 {
					line += fmt.Sprintf(" (own copy: exp lost %d)", int64(binary.LittleEndian.Uint64(d[22:])))
					// -hurt-when-struck: the first blow on this bot leaves it
					// nearly dead, so the other side's kill comes soon.
					if jobRun.hurt > 0 && !b.hurtDone {
						b.hurtDone = true
						b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: b.name, Line: fmt.Sprintf("/hurt %d", jobRun.hurt)}).Encode())
						line += fmt.Sprintf(" -> /hurt %d", jobRun.hurt)
					}
				}
				fmt.Println(line)
			}
		case session.OpSafeTrade:
			fmt.Printf("[%s] <- 0x34D5 % x\n", b.name, p.Data)
		case session.OpAttackResult:
			if r, err := session.DecodeAttackResult(p.Data); err == nil {
				fmt.Printf("[%s] <- AttackResult target %d type %d error %q damage %d left %d died %v\n", b.name,
					r.MonsterID, r.TargetType, r.Error, r.MonsterDamage, r.MonsterRemainingHP, r.MonsterDied)
			}
		case session.OpEquipBroadcast, session.OpStripStart, session.OpStripCancel:
			fmt.Printf("[%s] <- 0x%04x % x\n", b.name, p.Opcode, p.Data)
		case jobs.OpJobExp:
			fmt.Printf("[%s] <- 0x30E6 job exp % x\n", b.name, p.Data)
		}
	}
}

func (b *bot) awaitJob(want chan *proto.Packet, op uint16, d time.Duration) (*proto.Packet, error) {
	deadline := time.After(d)
	for {
		select {
		case p := <-want:
			if p.Opcode == op {
				return p, nil
			}
		case <-deadline:
			return nil, fmt.Errorf("%s: no 0x%04x within %v", b.name, op, d)
		}
	}
}

func jobScenario(addr, name string, level int, o jobOpts) error {
	spots, err := loadNPCSpots(o.npcsCSV, o.npcposCSV)
	if err != nil {
		return err
	}
	b, err := connect(addr, strings.ToLower(name), name, level)
	if err != nil {
		return err
	}
	want := make(chan *proto.Packet, 64)
	b.tap = b.jobTap(want)
	if _, err := b.gm("/gold 100000000"); err != nil {
		return err
	}
	if _, err := b.gm(fmt.Sprintf("/give %d", o.suit)); err != nil {
		return err
	}
	r := &questRun{b: b, spots: spots}
	uid, err := r.goTo(o.guild)
	if err != nil {
		return err
	}
	b.send(npctalk.OpSelect, npctalk.EncodeEntity(uid))
	if _, err := r.questMsg(npctalk.OpSelectResult, 3*time.Second); err != nil {
		return err
	}
	b.send(jobs.OpJoin, append(binary.LittleEndian.AppendUint32(nil, uid), byte(o.kind)))
	p, err := b.awaitJob(want, jobs.OpJoinResult, 3*time.Second)
	if err != nil {
		return err
	}
	fmt.Printf("[%s] join kind %d: % x\n", name, o.kind, p.Data)
	if p.Data[0] != 1 {
		return fmt.Errorf("%s: the join was refused: % x", name, p.Data)
	}
	alias := append(binary.LittleEndian.AppendUint32(nil, uid), 1)
	alias = binary.LittleEndian.AppendUint16(alias, uint16(len(o.alias)))
	b.send(jobs.OpAlias, append(alias, o.alias...))
	if p, err = b.awaitJob(want, jobs.OpAliasResult, 3*time.Second); err != nil {
		return err
	}
	fmt.Printf("[%s] alias %s: % x\n", name, o.alias, p.Data)
	r.end(uid)
	// The suit from the bag onto slot 8: the server holds it 10 s first
	// (jobsuit.go), standing still.
	b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: name}).Encode())
	if p, err = b.awaitJob(want, session.OpInventoryListResult, 3*time.Second); err != nil {
		return err
	}
	list, err := session.DecodeInventoryListResult(p.Data)
	if err != nil {
		return err
	}
	bagSlot := -1
	for _, s := range list.Slots {
		if s.ItemID == o.suit {
			bagSlot = s.Slot
		}
	}
	if bagSlot < 0 {
		return fmt.Errorf("%s: the suit %d is not in the bag", name, o.suit)
	}
	b.send(session.OpEquip, (&session.EquipRequest{CharacterName: name, Slot: equipment.SlotJobSuit, InventorySlot: bagSlot}).Encode())
	fmt.Printf("[%s] -> wear the suit %d from bag slot %d; waiting 12 s\n", name, o.suit, bagSlot)
	if p, err := b.awaitJob(want, session.OpEquipmentResult, 3*time.Second); err == nil {
		fmt.Printf("[%s] <- equipment result % x\n", name, p.Data[:min(len(p.Data), 48)])
	} else {
		fmt.Printf("[%s] no equipment result (%v)\n", name, err)
	}
	time.Sleep(12 * time.Second)
	b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: name}).Encode())
	if p, err := b.awaitJob(want, session.OpEquipmentResult, 3*time.Second); err == nil {
		fmt.Printf("[%s] <- equipment result after the wait % x\n", name, p.Data[:min(len(p.Data), 48)])
	}
	if o.fight != "" {
		var region int
		var lx, lz float64
		if _, err := fmt.Sscanf(o.fight, "%d %f %f", &region, &lx, &lz); err != nil {
			return fmt.Errorf("-fight wants \"region localX localZ\": %w", err)
		}
		rx, ry := worldmap.RegionXY(region)
		x, z, ok := zoneWorld(b.zone, rx, ry, lx, lz)
		if !ok {
			return fmt.Errorf("%s: region %d is not in the %s frame", name, region, b.zone)
		}
		res, err := b.gm(fmt.Sprintf("/tp %.1f %.1f", x, z))
		if err != nil {
			return err
		}
		b.moveTo(float32(x), b.y, float32(z))
		fmt.Printf("[%s] /tp %.1f %.1f (region %d local %.0f, %.0f): %s\n", name, x, z, region, lx, lz, res.Text)
	}
	if o.attack != "" || o.attackID != 0 {
		target := o.attackID
		for i := 0; i < 600 && target == 0 && o.attack != ""; i++ {
			if id, ok := b.idOf(o.attack); ok {
				target = id
				break
			}
			time.Sleep(time.Second)
		}
		if target == 0 {
			return fmt.Errorf("%s: %s never came into view", name, o.attack)
		}
		fmt.Printf("[%s] %s is in view (id %d); attacking for %v\n", name, o.attack, target, o.attackFor)
		end := time.Now().Add(o.attackFor)
		for time.Now().Before(end) {
			// One request starts the server's keep-up; a refusal or a
			// death ends it, so it is sent again every 3 s.
			b.send(session.OpAttack, (&session.AttackRequest{CharacterName: name, TargetMonsterID: target,
				TargetKind: session.PvPTargetCharacter}).Encode())
			time.Sleep(3 * time.Second)
		}
	}
	fmt.Printf("[%s] staying %v\n", name, o.stay)
	time.Sleep(o.stay)
	return nil
}
