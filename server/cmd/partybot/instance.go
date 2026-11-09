package main

// Round 869: -mode instance, the game worlds' live check on a lane server
// run with -gameworld-dir (docs/protocol/game_worlds.md 14): a GM bot opens a
// Togui layer with the GM aid /instance (OURS) and is warped in; it counts
// the layer's monsters and finds its exit NPC; it leaves by the exit NPC
// (0x751D -> 0xB51D {1}) to where it stood; the empty layer is aged to its
// 600 s close; a second layer is aged through the 60/10/5-minute warnings
// (0x300C 0x0C1A) to its 2 h end, which takes the bot back to its return
// point. Every step prints PASS or FAIL.

import (
	"encoding/binary"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/session"
	"github.com/TheOpenSRO/OpenSRO/server/internal/worldmap"
)

func instanceRun(addr, name string, level int, world string) error {
	b, err := connect(addr, strings.ToLower(name), name, level)
	if err != nil {
		return err
	}
	var mu sync.Mutex
	var zones []*session.ChangeZoneResult
	var notices, exits, gmText []string
	var lists []*session.MonsterListResult
	b.tap = func(p *proto.Packet) {
		mu.Lock()
		defer mu.Unlock()
		switch p.Opcode {
		case session.OpChangeZoneResult:
			if r, err := session.DecodeChangeZoneResult(p.Data); err == nil {
				zones = append(zones, r)
				fmt.Printf("[%s] <- zone change %q at %.0f, %.0f, %.0f frame %s\n", name, r.Zone, r.X, r.Y, r.Z, r.FrameRegion)
			}
		case session.OpUniqueNotice:
			notices = append(notices, fmt.Sprintf("% x", p.Data))
			fmt.Printf("[%s] <- 0x300C payload % x\n", name, p.Data)
		case proto.OpInstanceExitAck:
			exits = append(exits, fmt.Sprintf("% x", p.Data))
			fmt.Printf("[%s] <- 0xB51D % x\n", name, p.Data)
		case proto.OpTimedJobPush:
			fmt.Printf("[%s] <- 0x320C % x\n", name, p.Data)
		case session.OpMonsterListResult:
			if r, err := session.DecodeMonsterListResult(p.Data); err == nil {
				lists = append(lists, r)
			}
		case session.OpGMCommandResult:
			if r, err := session.DecodeGMCommandResult(p.Data); err == nil && r.Text != "" {
				gmText = append(gmText, r.Text)
				fmt.Printf("[%s] <- GM %q\n", name, r.Text)
			}
		}
	}
	go b.run()
	gm := func(line string, wait time.Duration) {
		b.send(session.OpGMCommand, (&session.GMCommandRequest{Name: name, Line: line}).Encode())
		fmt.Printf("[%s] GM %s\n", name, line)
		time.Sleep(wait)
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
	nZones := func() int { mu.Lock(); defer mu.Unlock(); return len(zones) }
	lastZone := func() *session.ChangeZoneResult {
		mu.Lock()
		defer mu.Unlock()
		if len(zones) == 0 {
			return nil
		}
		return zones[len(zones)-1]
	}
	startZone, sx, sz := b.zone, b.x, b.z

	// 1. Open and enter.
	gm("/instance "+world, 4*time.Second)
	in := lastZone()
	check("enter", nZones() == 1 && in != nil && in.OK, fmt.Sprintf("%+v", in))
	// 2. The layer's monsters (beside nest 30050 of the field hive 675,
	// region 0x7EE3 local (1441, 219), named in the layer's frame) and its
	// exit NPC.
	if in != nil {
		if fx, fy, ok := worldmap.ParseRegionLabel(in.FrameRegion); ok {
			rx, ry := worldmap.RegionXY(0x7EE3)
			x, z := worldmap.ToWorld(rx, ry, 1441, 230, fx, fy)
			gm(fmt.Sprintf("/tp %.0f %.0f", x, z), time.Second)
			b.moveTo(float32(x), in.Y, float32(z))
			time.Sleep(2 * time.Second)
		}
	}
	b.send(session.OpMonsterList, nil)
	time.Sleep(2 * time.Second)
	mu.Lock()
	count := 0
	for _, l := range lists {
		count += len(l.Monsters)
	}
	mu.Unlock()
	check("monsters", count > 0, fmt.Sprintf("%d in view", count))
	b.mu.Lock()
	exitUID := b.uidByRef[36032]
	b.mu.Unlock()
	check("exit NPC spawned", exitUID != 0, fmt.Sprintf("uid %#x", exitUID))
	gm("/instance list", time.Second)
	// 3. Out by the exit NPC. (The /tp inside was a zone change of its own,
	// within the layer.)
	tpZone := lastZone()
	check("tp stays in the layer", tpZone != nil && tpZone.Zone == in.Zone, fmt.Sprintf("%+v", tpZone))
	zonesBefore := nZones()
	b.send(proto.OpInstanceExit, binary.LittleEndian.AppendUint32(nil, exitUID))
	time.Sleep(3 * time.Second)
	mu.Lock()
	ex := append([]string(nil), exits...)
	mu.Unlock()
	back := lastZone()
	check("exit NPC", len(ex) == 1 && ex[0] == "01" && nZones() == zonesBefore+1 && back != nil && back.Zone == startZone,
		fmt.Sprintf("acks %v back %+v (entered %s at %.0f, %.0f)", ex, back, startZone, sx, sz))
	// 4. The empty close: 599 s, then 1 s more.
	// (Aged 9m30s: still open, a few real seconds having passed since the
	// exit; 40 s more: closed.)
	gm("/instance age "+world+".1 9m30s", time.Second)
	gm("/instance list", time.Second)
	mu.Lock()
	open := len(gmText) > 0 && strings.HasPrefix(gmText[len(gmText)-1], world+".1 ")
	mu.Unlock()
	gm("/instance age "+world+".1 40s", 2*time.Second)
	gm("/instance list", time.Second)
	mu.Lock()
	gt := append([]string(nil), gmText...)
	mu.Unlock()
	closed := len(gt) > 0 && gt[len(gt)-1] == "no open instance"
	check("empty close at 600 s", open && closed, fmt.Sprintf("%q", gt[max(0, len(gt)-4):]))
	// 5. A second layer through its warnings to its end.
	gm("/instance "+world, 4*time.Second)
	gm("/instance age 60m", 2*time.Second)
	gm("/instance age 50m", 2*time.Second)
	gm("/instance age 5m", 2*time.Second)
	before := nZones()
	gm("/instance age 5m", 4*time.Second)
	mu.Lock()
	ns := append([]string(nil), notices...)
	mu.Unlock()
	var warn []string
	for _, n := range ns {
		if strings.HasPrefix(n, "1a 0c") {
			warn = append(warn, n)
		}
	}
	check("warnings 60/10/5", fmt.Sprint(warn) == "[1a 0c 3c 1a 0c 0a 1a 0c 05]", fmt.Sprint(warn))
	end := lastZone()
	check("end returns to the return point", nZones() == before+1 && end != nil && end.Zone == startZone, fmt.Sprintf("%+v", end))
	if fails > 0 {
		return fmt.Errorf("%d check(s) failed", fails)
	}
	fmt.Println("instance: all checks passed")
	return nil
}
