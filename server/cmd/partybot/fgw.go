package main

// Round 869 lane W3: -mode fgw, the Forgotten World's live check on a lane
// server run with -gameworld-dir, -nest-db-dir, -items-csv, -monsters-csv,
// -npcs-csv and -regions-csv (docs/protocol/forgotten_world.md 11): a whole
// run of one band (Togui 61-70 grade 1 by default) from the hole to the
// boss, the exit, the re-entry refusal, the recall of a party member and the
// pillar's hole drops. The GM aids (OURS) stand in where real time or real
// luck would take hours: /fgwkill kills a layer's live monsters as the GM's
// kills (the triggers hear them), /fgw makes a second gate without an item,
// /fgwpillar loads the band's pillar as the 0.1 % trigger would. Every step
// prints PASS or FAIL with what it saw.

import (
	"encoding/binary"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gameworld"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npctalk"
	"github.com/TheOpenSRO/OpenSRO/server/internal/party"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
)

// fgwOpts are -mode fgw's settings.
type fgwOpts struct {
	hole     int64  // the hole item (35887: Togui 61-70 grade 1)
	world    string // its world (67)
	pillar   string // the band's pillar
	envyDrop string // its ENVY_DROP
	fieldDX  float64
	level    int
	// only "pillar" runs the pillar step alone (on a server whose monsters
	// do not fight back: the pillar's seven champions kill a bare GM).
	only string
}

// fgwLog is one bot's timed packet log.
type fgwLog struct {
	mu   sync.Mutex
	name string
	t0   time.Time
	pkts []fgwPkt
}

type fgwPkt struct {
	at   time.Duration
	op   uint16
	data []byte
}

func (l *fgwLog) tap(p *proto.Packet) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.pkts = append(l.pkts, fgwPkt{time.Since(l.t0), p.Opcode, append([]byte(nil), p.Data...)})
}

// since is every packet of the ops after mark (an index).
func (l *fgwLog) since(mark int, ops ...uint16) []fgwPkt {
	l.mu.Lock()
	defer l.mu.Unlock()
	var out []fgwPkt
	for _, p := range l.pkts[min(mark, len(l.pkts)):] {
		for _, op := range ops {
			if p.op == op {
				out = append(out, p)
			}
		}
	}
	return out
}

func (l *fgwLog) mark() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.pkts)
}

// wait polls for a packet of op after mark.
func (l *fgwLog) wait(mark int, d time.Duration, op uint16) (fgwPkt, bool) {
	end := time.Now().Add(d)
	for time.Now().Before(end) {
		if ps := l.since(mark, op); len(ps) > 0 {
			return ps[0], true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fgwPkt{}, false
}

func fgwRun(addr, prefix string, o fgwOpts) error {
	mk := func(suffix string, level int) (*bot, *fgwLog, error) {
		name := prefix + suffix
		b, err := connect(addr, strings.ToLower(name), name, level)
		if err != nil {
			return nil, nil, err
		}
		l := &fgwLog{name: name, t0: time.Now()}
		b.tap = l.tap
		go b.run()
		return b, l, nil
	}
	a, la, err := mk("Fa", o.level)
	if err != nil {
		return err
	}
	bm, lb, err := mk("Fb", o.level)
	if err != nil {
		return err
	}
	lo, lc, err := mk("Fc", 30)
	if err != nil {
		return err
	}
	fails := 0
	check := func(what string, ok bool, detail string) {
		if ok {
			fmt.Printf("PASS %s %s\n", what, detail)
		} else {
			fails++
			fmt.Printf("FAIL %s %s\n", what, detail)
		}
	}
	gm := func(b *bot, line string) string {
		r, err := b.gmWait(line, 60*time.Second)
		if err != nil {
			fmt.Printf("[%s] GM %s: %v\n", b.name, line, err)
			if r != nil {
				return r.Text
			}
			return ""
		}
		fmt.Printf("[%s] GM %s -> %q\n", b.name, line, r.Text)
		return r.Text
	}
	slotOf := func(b *bot, l *fgwLog, item int64) int {
		m := l.mark()
		b.send(session.OpInventoryList, (&session.CharacterNameRequest{Name: b.name}).Encode())
		p, ok := l.wait(m, 3*time.Second, session.OpInventoryListResult)
		if !ok {
			return -1
		}
		r, err := session.DecodeInventoryListResult(p.data)
		if err != nil {
			return -1
		}
		for _, s := range r.Slots {
			if s.ItemID == item {
				return s.Slot
			}
		}
		return -1
	}
	use := func(b *bot, l *fgwLog, slot int) (*session.UseItemResult, int) {
		m := l.mark()
		b.send(session.OpUseItem, (&session.UseItemRequest{CharacterName: b.name, InventorySlot: int32(slot)}).Encode())
		p, ok := l.wait(m, 3*time.Second, session.OpUseItemResult)
		if !ok {
			return nil, m
		}
		r, _ := session.DecodeUseItemResult(p.data)
		return r, m
	}
	hex := func(b []byte) string { return fmt.Sprintf("% x", b) }

	// Side by side (the invitation wants the other in view), then the party:
	// Fa leads, Fb joins.
	bm.mu.Lock()
	bx, by, bzz := bm.x, bm.y, bm.z
	bm.mu.Unlock()
	a.moveTo(bx+3, by, bzz)
	a.mu.Lock()
	a.x, a.y, a.z = bx+3, by, bzz
	a.mu.Unlock()
	time.Sleep(time.Second)
	if err := form(a, bm, party.FlagExpShare); err != nil {
		return err
	}
	// Nothing here reads the party channel past the forming: drain it, or a
	// full channel stalls the bot's reader (the 1 s party updates).
	for _, b := range []*bot{a, bm, lo} {
		go func(b *bot) {
			for range b.in {
			}
		}(b)
	}
	a.mu.Lock()
	townZone, tx, ty, tz := a.zone, a.x, a.y, a.z
	a.mu.Unlock()

	if o.only != "pillar" {
		// 1. In the field: 0x184b, the hole kept.
		gm(a, fmt.Sprintf("/give %d", o.hole))
		gm(lo, fmt.Sprintf("/give %d", o.hole))
		slot := slotOf(a, la, o.hole)
		check("hole given", slot >= 0, fmt.Sprintf("slot %d", slot))
		gm(a, fmt.Sprintf("/tp %.0f %.0f", float64(tx)+o.fieldDX, float64(tz)))
		time.Sleep(2 * time.Second)
		if r, _ := use(a, la, slot); r != nil {
			check("field refusal 0x184b", r.Error != "" && r.Code == gameworld.CodeHoleNotTown, fmt.Sprintf("%+v", *r))
		} else {
			check("field refusal 0x184b", false, "no reply")
		}
		gm(a, fmt.Sprintf("/tp %.0f %.0f", tx, tz))
		time.Sleep(2 * time.Second)
		a.moveTo(tx, ty, tz)
		time.Sleep(500 * time.Millisecond)
		// 2. Level 30 in band 61-70: 0x1851.
		if r, _ := use(lo, lc, slotOf(lo, lc, o.hole)); r != nil {
			check("level refusal 0x1851", r.Code == gameworld.CodeHoleLevel, fmt.Sprintf("%+v", *r))
		}

		// 3. In town: the replies in order, the gate.
		mb := lb.mark()
		r, m := use(a, la, slot)
		time.Sleep(time.Second)
		seq := la.since(m, session.OpUseItemResult, session.OpItemUseEffect, session.OpItemMoveResult, npcspawn.OpSingleSpawn)
		var order []string
		var gate uint32
		var t0 time.Duration
		for i, p := range seq {
			if p.op == npcspawn.OpSingleSpawn && (len(p.data) < 8 || binary.LittleEndian.Uint32(p.data) != gameworld.GateRefObjID) {
				continue
			}
			if i == 0 {
				t0 = p.at
			}
			order = append(order, fmt.Sprintf("%04x@+%dms", p.op, (p.at-t0).Milliseconds()))
			if p.op == npcspawn.OpSingleSpawn {
				gate = binary.LittleEndian.Uint32(p.data[4:])
				fmt.Printf("[%s] gate record % x\n", a.name, p.data)
			}
		}
		check("hole use in town", r != nil && r.Error == "" && gate != 0, fmt.Sprintf("%+v order %v", r, order))
		check("reply order B04C 305C B034 3015", len(order) == 4 && strings.HasPrefix(order[0], "008b") && strings.HasPrefix(order[1], "305c") &&
			strings.HasPrefix(order[2], "b034") && strings.HasPrefix(order[3], "3015"), fmt.Sprint(order))
		bs := lb.since(mb, session.OpItemUseEffect, npcspawn.OpSingleSpawn)
		sawGate := false
		for _, p := range bs {
			if p.op == npcspawn.OpSingleSpawn && len(p.data) >= 8 && binary.LittleEndian.Uint32(p.data[4:]) == gate {
				sawGate = true
			}
		}
		check("the member in view got the 305C and the gate's record", sawGate && len(bs) >= 2, fmt.Sprintf("%d packets", len(bs)))
		// A second hole in the cool time.
		gm(a, fmt.Sprintf("/give %d", o.hole))
		if r2, _ := use(a, la, slotOf(a, la, o.hole)); r2 != nil {
			check("cool time 0x185b", r2.Code == gameworld.CodeHoleCoolTime, fmt.Sprintf("%+v", *r2))
		}

		// 4. The gate's select and end.
		m = la.mark()
		a.send(npctalk.OpSelect, npctalk.EncodeEntity(gate))
		sel, _ := la.wait(m, 3*time.Second, npctalk.OpSelectResult)
		check("gate select B045", len(sel.data) == 23 && sel.data[0] == 1 && hex(sel.data[5:9]) == "01 1c 01 02", hex(sel.data))
		m = la.mark()
		a.send(npctalk.OpEnd, npctalk.EncodeEntity(gate))
		end, _ := la.wait(m, 3*time.Second, npctalk.OpEndResult)
		check("gate end B04B {02, 0x1c0d}", hex(end.data) == "02 0d 1c", hex(end.data))

		// 5. Fb (not the creator) through Fa's gate: 0x1c2f.
		mb = lb.mark()
		bm.send(proto.OpTeleportUse, append(binary.LittleEndian.AppendUint32(nil, gate), 3, 0))
		time.Sleep(time.Second)
		var br []string
		for _, p := range lb.since(mb, proto.OpTeleportUseAck) {
			br = append(br, hex(p.data))
		}
		check("non-creator refused 0x1c2f", fmt.Sprint(br) == "[02 01 00 02 2f 1c]", fmt.Sprint(br))

		// 6. Fa enters.
		m = la.mark()
		a.send(proto.OpTeleportUse, append(binary.LittleEndian.AppendUint32(nil, gate), 3, 0))
		time.Sleep(4 * time.Second)
		var ar []string
		for _, p := range la.since(m, proto.OpTeleportUseAck) {
			ar = append(ar, hex(p.data))
		}
		zc := la.since(m, session.OpChangeZoneResult)
		notices := la.since(m, session.OpUniqueNotice, proto.OpTimedJobPush)
		var ns []string
		for _, p := range notices {
			ns = append(ns, fmt.Sprintf("%04x:% x", p.op, p.data[:min(4, len(p.data))]))
		}
		check("entry {2,1} then {1}", fmt.Sprint(ar) == "[02 01 00 01]" && len(zc) == 1, fmt.Sprintf("%v zone changes %d", ar, len(zc)))
		check("entry notices with the arrival, then 0x320C", len(notices) >= 3 && notices[0].op == session.OpUniqueNotice &&
			notices[0].data[2] == 1 && notices[1].data[2] == 2, fmt.Sprint(ns))
		time.Sleep(2 * time.Second)
		a.mu.Lock()
		exitUID, recallUID := a.uidByRef[36032], a.uidByRef[36033]
		inZone := a.zone
		a.mu.Unlock()
		check("exit and recall NPCs spawned", exitUID != 0 && recallUID != 0, fmt.Sprintf("exit %#x recall %#x zone %s", exitUID, recallUID, inZone))

		// 7. The recall: Fa lists, summons Fb, Fb says yes and arrives 5 s later.
		m = la.mark()
		a.send(proto.OpPartyRecallList, binary.LittleEndian.AppendUint32(nil, recallUID))
		lst, _ := la.wait(m, 3*time.Second, proto.OpPartyRecallListAck)
		check("recall list B519", len(lst.data) == 10 && lst.data[0] == 1 && lst.data[1] == 1 && lst.data[6] == gameworld.RecallPossible &&
			int(lst.data[7]) == o.level, hex(lst.data))
		mb = lb.mark()
		m = la.mark()
		a.send(proto.OpPartyRecallSummon, binary.LittleEndian.AppendUint32(nil, uint32(bm.id)))
		push, ok := lb.wait(mb, 3*time.Second, proto.OpPartyRecallSummon)
		check("summon push to the member", ok && len(push.data) >= 14 && binary.LittleEndian.Uint32(push.data[8:]) == 5, hex(push.data))
		check("nothing back to the master", len(la.since(m, proto.OpPartyRecallSummonAck)) == 0, "")
		mb = lb.mark()
		ans := binary.LittleEndian.AppendUint32(nil, binary.LittleEndian.Uint32(push.data))
		ans = append(binary.LittleEndian.AppendUint32(ans, uint32(bm.id)), 1)
		yes := time.Now()
		bm.send(proto.OpPartyRecallAnswer, ans)
		if p, ok := lb.wait(mb, 10*time.Second, session.OpChangeZoneResult); ok {
			ack := lb.since(mb, proto.OpPartyRecallAnswerAck)
			check("member's yes {01}, warped 5 s later", len(ack) == 1 && hex(ack[0].data) == "01" && lb.t0.Add(p.at).Sub(yes) >= 5*time.Second,
				fmt.Sprintf("arrived %.1f s after the yes, zone %q", lb.t0.Add(p.at).Sub(yes).Seconds(), func() string {
					r, _ := session.DecodeChangeZoneResult(p.data)
					return r.Zone
				}()))
		} else {
			check("member's yes {01}, warped 5 s later", false, "no zone change")
		}
		time.Sleep(2 * time.Second)

		// 8. The script to the boss: one real-blow kill, then the GM aid kills
		// what is alive, pass after pass, while the dormant nests wake.
		m = la.mark()
		bossKilled := false
		for pass := 0; pass < 80 && !bossKilled; pass++ {
			txt := gm(a, "/fgwkill")
			for _, p := range la.since(m, session.OpUniqueNotice) {
				if strings.Contains(string(p.data), "BOSS_KILL") {
					bossKilled = true
				}
			}
			if strings.HasPrefix(txt, "killed 0 ") {
				time.Sleep(1500 * time.Millisecond)
			} else {
				time.Sleep(700 * time.Millisecond)
			}
		}
		var keys []string
		for _, p := range la.since(m, session.OpUniqueNotice) {
			if len(p.data) > 5 && p.data[2] == 1 {
				keys = append(keys, strings.TrimPrefix(string(p.data[5:]), "UIIT_MGS_GOD_TRIGGER_NOTICE_COMMON_"))
			}
		}
		doors := la.since(m, proto.OpEventZoneState)
		check("the script to the boss", bossKilled, fmt.Sprintf("banners %v, 0x351E x%d", keys, len(doors)))
		nb := 0
		for _, p := range lb.since(mb, session.OpUniqueNotice) {
			if strings.Contains(string(p.data), "BOSS_KILL") {
				nb++
			}
		}
		check("the member heard the boss's defeat too", nb > 0, fmt.Sprintf("%d", nb))

		// 9. Out by the exit NPC to the gate's spot.
		m = la.mark()
		a.send(proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID))
		time.Sleep(3 * time.Second)
		ex := la.since(m, proto.OpInstanceExitAck)
		back := la.since(m, session.OpChangeZoneResult)
		var bz string
		if len(back) > 0 {
			if r, err := session.DecodeChangeZoneResult(back[0].data); err == nil {
				bz = fmt.Sprintf("%s at %.0f, %.0f", r.Zone, r.X, r.Z)
			}
		}
		check("exit {01} back to the gate's spot", len(ex) == 1 && hex(ex[0].data) == "01" && len(back) == 1, fmt.Sprintf("%s (gate made in %s at %.0f, %.0f)", bz, townZone, tx, tz))

		// 10. Re-entry: another layer refused 0x1c32; the same one let in.
		txt := gm(a, "/fgw "+o.world)
		var gate2 uint32
		if i := strings.Index(txt, "gate 0x"); i >= 0 {
			fmt.Sscanf(txt[i+7:], "%x", &gate2)
		}
		time.Sleep(time.Second)
		m = la.mark()
		a.send(proto.OpTeleportUse, append(binary.LittleEndian.AppendUint32(nil, gate2), 3, 0))
		time.Sleep(time.Second)
		var rr []string
		for _, p := range la.since(m, proto.OpTeleportUseAck) {
			rr = append(rr, hex(p.data))
		}
		check("another layer refused 0x1c32", fmt.Sprint(rr) == "[02 01 00 02 32 1c]", fmt.Sprint(rr))
		m = la.mark()
		a.send(proto.OpTeleportUse, append(binary.LittleEndian.AppendUint32(nil, gate), 3, 0))
		time.Sleep(4 * time.Second)
		rr = nil
		for _, p := range la.since(m, proto.OpTeleportUseAck) {
			rr = append(rr, hex(p.data))
		}
		var left uint32
		for _, p := range la.since(m, proto.OpTimedJobPush) {
			left = binary.LittleEndian.Uint32(p.data[5:])
		}
		check("the same layer let in again, the limit's remaining time", fmt.Sprint(rr) == "[02 01 00 01]" && left > 0 && left < 18000,
			fmt.Sprintf("%v remaining %d s", rr, left))
		m = la.mark()
		a.send(proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID))
		time.Sleep(3 * time.Second)
		a.moveTo(tx, ty, tz)

	}
	// 11. The pillar's holes, in the field: the pillar's death summons its
	// Envies; their kills drop holes (15 / 10 % a kill for grades 1 / 2).
	gm(a, fmt.Sprintf("/tp %.0f %.0f", float64(tx)+o.fieldDX, float64(tz)))
	time.Sleep(2 * time.Second)
	a.mu.Lock()
	fx, fy, fz := a.x, a.y, a.z
	a.mu.Unlock()
	holes, envies, pillars := map[int64]int{}, 0, 0
	for pillars < 8 && holes[o.hole]+holes[o.hole+1] < 2 {
		pillars++
		txt := gm(a, "/fgwpillar "+o.pillar)
		var pid int64
		if i := strings.Index(txt, "#"); i >= 0 {
			fmt.Sscanf(txt[i+1:], "%d", &pid)
		}
		if pid == 0 {
			break
		}
		if !fgwSlay(a, la, pid) {
			fmt.Printf("[%s] pillar #%d did not die\n", a.name, pid)
			continue
		}
		time.Sleep(time.Second)
		for _, mo := range fgwMonsters(a, la) {
			if mo.CodeName != o.envyDrop {
				continue
			}
			mg := la.mark()
			a.moveTo(mo.X, mo.Y, mo.Z)
			time.Sleep(200 * time.Millisecond)
			if fgwSlay(a, la, mo.ID) {
				envies++
				time.Sleep(600 * time.Millisecond)
				for _, p := range la.since(mg, session.OpGroundItemSpawned) {
					s, err := session.DecodeGroundItemListResult(append([]byte{1, 0}, p.data...))
					if err == nil && len(s.Items) == 1 && s.Items[0].ItemID >= 35883 && s.Items[0].ItemID <= 35904 {
						holes[s.Items[0].ItemID]++
					}
				}
			}
		}
		a.moveTo(fx, fy, fz)
	}
	check("pillar summons and hole drops", envies >= 5 && len(holes) > 0, fmt.Sprintf("%d pillars, %d Envies killed, holes %v", pillars, envies, holes))
	if fails > 0 {
		return fmt.Errorf("%d check(s) failed", fails)
	}
	fmt.Println("fgw: all checks passed")
	return nil
}

// fgwMonsters is the monsters the bot's list request names.
func fgwMonsters(b *bot, l *fgwLog) []session.MonsterSnapshot {
	m := l.mark()
	b.send(session.OpMonsterList, nil)
	time.Sleep(time.Second)
	var out []session.MonsterSnapshot
	for _, p := range l.since(m, session.OpMonsterListResult) {
		if r, err := session.DecodeMonsterListResult(p.data); err == nil {
			out = append(out, r.Monsters...)
		}
	}
	return out
}

// fgwSlay wounds a monster to 1 HP with /damage and kills it with a real
// blow (the combat path: the kill credit, the drops, the triggers).
func fgwSlay(b *bot, l *fgwLog, id int64) bool {
	var hp int32
	for _, mo := range fgwMonsters(b, l) {
		if mo.ID == id {
			hp = mo.HP
			b.moveTo(mo.X+2, mo.Y, mo.Z)
			time.Sleep(200 * time.Millisecond)
		}
	}
	if hp > 1 {
		if _, err := b.gm(fmt.Sprintf("/damage %d %d", hp-1, id)); err != nil {
			fmt.Printf("[%s] /damage: %v\n", b.name, err)
		}
	}
	for i := 0; i < 20; i++ {
		// The pillar's Envies are aggressive champions: the GM keeps itself
		// alive between blows.
		b.gmWait("/heal", 5*time.Second)
		b.send(session.OpAttack, (&session.AttackRequest{CharacterName: b.name, TargetMonsterID: id}).Encode())
		p, err := b.awaitOther(session.OpAttackResult, 5*time.Second)
		if err != nil {
			return false
		}
		ar, err := session.DecodeAttackResult(p.Data)
		if err != nil {
			return false
		}
		if ar.MonsterDied {
			return true
		}
		if ar.Error != "" {
			fmt.Printf("[%s] attack #%d: %s\n", b.name, id, ar.Error)
		}
		time.Sleep(700 * time.Millisecond)
	}
	return false
}

// gmWait is gm with a longer wait (a /fgwkill of a whole layer).
func (b *bot) gmWait(line string, d time.Duration) (*session.GMCommandResult, error) {
	b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: b.name, Line: line}).Encode())
	p, err := b.awaitOther(session.OpGMCommandResult, d)
	if err != nil {
		return nil, err
	}
	r, err := session.DecodeGMCommandResult(p.Data)
	if err != nil {
		return nil, err
	}
	if r.Refused {
		return r, fmt.Errorf("%s: %s refused: %s", b.name, line, r.Text)
	}
	return r, nil
}
