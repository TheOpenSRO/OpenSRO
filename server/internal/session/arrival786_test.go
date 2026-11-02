package session

import (
	"bufio"
	"context"
	"errors"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"io/fs"
	"net"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/ai"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/npcspawn"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 786 (part): the protection after a teleport (arrival.go,
// docs/protocol/arrival_guard.md). A character that arrives anywhere is held
// out of the world until its client's 0x3012 (retail's SR_READY_TO_PLAY,
// whose handler CGame::EnterWorld 0x417240 puts the PC into its block), then
// untouchable for 6.0 s (CGObjPC::vslot_391's SetBodyMode(2, 0, 6.0, 0),
// 0x4df9e0 / 0x5eb2d0 / 0xb45b78), with nothing ending it early. Each test
// turns the guard on for itself (the suite runs with it off, TestMain).

// guardOn turns the arrival guard on for t, with the protection and the hold
// timeout given (0 keeps the production value).
func guardOn(t *testing.T, protection, hold time.Duration) {
	t.Helper()
	arrivalGuardOn.Store(true)
	oldP, oldH := protectionTime, arrivalHoldTimeout
	if protection > 0 {
		protectionTime = protection
	}
	if hold > 0 {
		arrivalHoldTimeout = hold
	}
	t.Cleanup(func() {
		arrivalGuardOn.Store(false)
		protectionTime, arrivalHoldTimeout = oldP, oldH
		arrivals.Lock()
		for id, e := range arrivals.byChar {
			if e.timer != nil {
				e.timer.Stop()
			}
			delete(arrivals.byChar, id)
		}
		arrivals.Unlock()
	})
}

// arrivalRig is Aria (alice, a GM) and Bram (bob) on one server with the
// world, teleport, GM, combat and revive handlers over in-memory stores, and
// a monster standing at Jangan's spawn.
type arrivalRig struct {
	t        *testing.T
	chars    *character.MemStore
	eq       equipment.Store
	hub      *world.Hub
	monsters *combat.Hub
	monster  *combat.Monster
	conns    map[string]net.Conn
	readers  map[string]*bufio.Reader
	ids      map[string]int64
}

func newArrivalRig(t *testing.T) *arrivalRig {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "pw")
	accounts.Add("bob", "pw")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	monsters := combat.NewHub()
	m := monsters.Spawn(spawnZone, "Mangyang", 0, 0, 0, 1000000, 0, 15, 0)
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandlerWithHook(chars, eq, hub, nil, nil),
		TeleportHandler(chars, eq, hub, teleportFixture(t), gm.ParseAccounts("alice"), true, nil, nil),
		GMCommandHandler(chars, gm.ParseAccounts("alice"), &gm.Deps{Equip: eq, Zones: []string{"jangan", "donwhang", "hotan"}}, hub, nil),
		CombatHandler(chars, eq, items, hub, monsters, quest.NewMemStore(), inv, skill.NewMemStore(), nil, nil, nil),
		ReviveHandler(chars, hub, RegenDeps{Equipment: eq}),
	)
	t.Cleanup(func() { InstallDungeonEntries(nil) })
	// With the disconnect handler, as cmd/server wires it: the hold's stale
	// clear closes the session and the disconnect takes the character out.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(srvCtx)
	rig := &arrivalRig{t: t, chars: chars, eq: eq, hub: hub, monsters: monsters, monster: m,
		conns: map[string]net.Conn{}, readers: map[string]*bufio.Reader{},
		ids: map[string]int64{"Aria": aria.ID, "Bram": bram.ID}}
	for _, who := range []struct{ user, name string }{{"alice", "Aria"}, {"bob", "Bram"}} {
		c := dialTestServer(t, addr)
		t.Cleanup(func() { c.Close() })
		rig.conns[who.name], rig.readers[who.name] = c, bufio.NewReader(c)
		rig.send(who.name, OpLogin, (&LoginRequest{Username: who.user, Password: "pw"}).Encode())
		if lr, err := DecodeLoginResult(rig.until(who.name, OpLoginResult).Data); err != nil || !lr.OK {
			t.Fatalf("%s login: %+v %v", who.user, lr, err)
		}
		rig.send(who.name, OpEnterWorld, (&EnterWorldRequest{CharacterName: who.name}).Encode())
		if ewr, err := DecodeEnterWorldResult(rig.until(who.name, OpEnterWorldResult).Data); err != nil || !ewr.OK {
			t.Fatalf("%s enter world: %+v %v", who.name, ewr, err)
		}
	}
	return rig
}

func (rig *arrivalRig) send(name string, op uint16, data []byte) {
	rig.t.Helper()
	if err := proto.Write(rig.conns[name], &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		rig.t.Fatalf("%s: write %#04x: %v", name, op, err)
	}
}

// until reads name's packets until one with op arrives (2 s), failing the test
// otherwise.
func (rig *arrivalRig) until(name string, op uint16) *proto.Packet {
	rig.t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		p := rig.read(name, time.Until(deadline))
		if p == nil {
			break
		}
		if p.Opcode == op {
			return p
		}
	}
	rig.t.Fatalf("%s: no %#04x within 2 s", name, op)
	return nil
}

// read reads one packet of name's, nil when none comes within wait.
func (rig *arrivalRig) read(name string, wait time.Duration) *proto.Packet {
	rig.t.Helper()
	c := rig.conns[name]
	c.SetReadDeadline(time.Now().Add(wait))
	p, err := proto.Read(rig.readers[name], nil, nil)
	if err != nil {
		var ne net.Error
		if errors.As(err, &ne) && ne.Timeout() {
			return nil
		}
		rig.t.Fatalf("%s: read: %v", name, err)
	}
	return p
}

// heard is what one client was sent over a window: the players spawned to it
// and the ones despawned, the body modes it was told, and every opcode.
type heard struct {
	spawned   map[uint32]byte // uid -> the record's body mode
	despawned map[uint32]bool
	modes     []StateChange // 0x30BF kind 4
	ops       []uint16
	packets   []*proto.Packet
}

// listen reads name's packets until none comes for quiet.
func (rig *arrivalRig) listen(name string, quiet time.Duration) heard {
	rig.t.Helper()
	h := heard{spawned: map[uint32]byte{}, despawned: map[uint32]bool{}}
	next := func() *proto.Packet { return rig.read(name, 2*time.Second) }
	for {
		p := rig.read(name, quiet)
		if p == nil {
			return h
		}
		h.ops = append(h.ops, p.Opcode)
		h.packets = append(h.packets, p)
		switch p.Opcode {
		case npcspawn.OpSingleSpawn:
			for _, r := range playerSpawnsIn(rig.t, p, next) {
				h.spawned[r.UID] = r.BodyMode
			}
		case npcspawn.OpSingleDespawn:
			for _, u := range playerDespawnsIn(rig.t, p, next) {
				h.despawned[u] = true
			}
		case npcspawn.OpGroupBegin:
			frames := []npcspawn.GroupFrame{{Opcode: p.Opcode, Data: p.Data}}
			for {
				q := next()
				if q == nil {
					rig.t.Fatalf("%s: a group spawn cut short", name)
				}
				frames = append(frames, npcspawn.GroupFrame{Opcode: q.Opcode, Data: q.Data})
				if q.Opcode == npcspawn.OpGroupEnd {
					break
				}
			}
			recs, uids, kind := decodePlayerGroup(rig.t, frames)
			if kind == npcspawn.GroupSpawn {
				for _, r := range recs {
					h.spawned[r.UID] = r.BodyMode
				}
			} else {
				for _, u := range uids {
					h.despawned[u] = true
				}
			}
		case OpStateChange:
			if s, ok := DecodeStateChange(p.Data); ok && s.Kind == StateKindBodyMode {
				h.modes = append(h.modes, *s)
			}
		}
	}
}

// modeFor is the body modes h was told for character id, in order.
func (h heard) modeFor(id int64) []byte {
	var out []byte
	for _, s := range h.modes {
		if int64(s.ObjectID) == id {
			out = append(out, s.Value)
		}
	}
	return out
}

func (h heard) has(op uint16) bool {
	for _, o := range h.ops {
		if o == op {
			return true
		}
	}
	return false
}

// ready sends name's 0x3012 and returns what name then hears.
func (rig *arrivalRig) ready(name string) heard {
	rig.t.Helper()
	rig.send(name, OpReadyToPlay, nil)
	return rig.listen(name, 300*time.Millisecond)
}

func (rig *arrivalRig) entity(name string) world.Entity {
	rig.t.Helper()
	e, ok := rig.hub.EntityByCharacterID(rig.ids[name])
	if !ok {
		rig.t.Fatalf("%s is not in the world", name)
	}
	return e
}

// bothIn readies both players where they stand and drains what that sends.
func (rig *arrivalRig) bothIn() {
	rig.t.Helper()
	rig.ready("Aria")
	rig.ready("Bram")
	rig.listen("Aria", 300*time.Millisecond)
	rig.listen("Bram", 300*time.Millisecond)
}

// THE RED: a world entry is held. Aria's enter-world puts her in the hub held
// -- no window holds her, Bram (entered after her) is not sent her spawn, and
// neither sees the other -- until her 0x3012; then Bram is sent her spawn and
// body mode 2, and she is sent his. Before this round the spawns went both
// ways with the enter-world result.
func TestRound786WorldEntryIsHeldUntilReady(t *testing.T) {
	guardOn(t, time.Hour, 0)
	rig := newArrivalRig(t)
	if !heldInHub(rig.hub, rig.ids["Aria"]) || !heldInHub(rig.hub, rig.ids["Bram"]) {
		t.Fatalf("after the enter-world results Aria held=%v Bram held=%v; want both held until their 0x3012",
			heldInHub(rig.hub, rig.ids["Aria"]), heldInHub(rig.hub, rig.ids["Bram"]))
	}
	b := rig.listen("Bram", 300*time.Millisecond)
	if _, ok := b.spawned[uint32(rig.ids["Aria"])]; ok {
		t.Fatal("Bram was spawned Aria before either reported its loading done")
	}
	rig.ready("Aria")
	if heldInHub(rig.hub, rig.ids["Aria"]) {
		t.Fatal("Aria still held after her 0x3012")
	}
	if b := rig.listen("Bram", 300*time.Millisecond); len(b.spawned) != 0 {
		t.Fatalf("held Bram was spawned %v", b.spawned)
	}
	a := rig.ready("Bram")
	got := rig.listen("Aria", 300*time.Millisecond)
	_ = a
	if _, ok := got.spawned[uint32(rig.ids["Bram"])]; !ok {
		t.Fatalf("Aria was not spawned Bram after his 0x3012 (ops %#04x)", got.ops)
	}
	if m := got.modeFor(rig.ids["Bram"]); len(m) != 1 || m[0] != bodyModeInvincible {
		t.Fatalf("Aria was told Bram's body modes %v after his arrival, want [2]", m)
	}
}

// A gate teleport (and the same for a zone change below): the mover is held
// at the destination, Bram standing there sees nothing until the mover's
// 0x3012, then its spawn followed by body mode 2.
func TestRound786GateTeleportIsHeldUntilReady(t *testing.T) {
	guardOn(t, time.Hour, 0)
	rig := newArrivalRig(t)
	rig.bothIn()
	// Bram goes first and is let in at Donwhang's gate point.
	rig.send("Bram", OpTeleportUse, clientTeleportUse(1, 2))
	rig.until("Bram", OpChangeZoneResult)
	rig.ready("Bram")
	rig.listen("Aria", 300*time.Millisecond)
	// Aria follows: held at the same point.
	rig.send("Aria", OpTeleportUse, clientTeleportUse(1, 2))
	rig.until("Aria", OpChangeZoneResult)
	a := rig.entity("Aria")
	if !heldInHub(rig.hub, rig.ids["Aria"]) || a.Zone != rig.entity("Bram").Zone {
		t.Fatalf("Aria after the gate: held=%v zone %q (Bram %q); want held in Bram's zone", heldInHub(rig.hub, rig.ids["Aria"]), a.Zone, rig.entity("Bram").Zone)
	}
	if rig.hub.Sees(rig.entity("Aria").Session.ID(), rig.entity("Bram").Session.ID()) {
		t.Fatal("the hub has Bram seeing held Aria")
	}
	if b := rig.listen("Bram", 400*time.Millisecond); len(b.spawned) != 0 {
		t.Fatalf("Bram was spawned %v while Aria was loading", b.spawned)
	}
	if !untouchable(rig.hub, rig.ids["Aria"], time.Now()) {
		t.Fatal("held Aria is not untouchable")
	}
	rig.ready("Aria")
	b := rig.listen("Bram", 300*time.Millisecond)
	if _, ok := b.spawned[uint32(rig.ids["Aria"])]; !ok {
		t.Fatalf("Bram was not spawned Aria after her 0x3012 (ops %#04x)", b.ops)
	}
	if m := b.modeFor(rig.ids["Aria"]); len(m) != 1 || m[0] != bodyModeInvincible {
		t.Fatalf("Bram was told Aria's body modes %v, want [2] after her spawn", m)
	}
}

// The protection: 6.0 s READ (the constant), body mode 2 to the players in
// view at the release and 0 at its end; a spawn during it carries 2. While it
// lasts the character's attack is refused (0x3020, attacker in mode 2) and it
// is untouchable; a move does not end it (no SetBodyMode on the move path,
// READ: the 28-site census). After the end the same attack lands.
func TestRound786ProtectionLastsThenEnds(t *testing.T) {
	if ProtectionAfterArrival != 6*time.Second {
		t.Fatalf("ProtectionAfterArrival = %v, want 6.0 s (CGameWorld slot 28, 0x5eb2d0 -> 0xb45b78)", ProtectionAfterArrival)
	}
	guardOn(t, 700*time.Millisecond, 0)
	rig := newArrivalRig(t)
	rig.ready("Bram")
	rig.listen("Aria", 200*time.Millisecond)
	rig.send("Aria", OpReadyToPlay, nil)
	start := time.Now()
	b := rig.listen("Bram", 200*time.Millisecond)
	if m := b.modeFor(rig.ids["Aria"]); len(m) != 1 || m[0] != bodyModeInvincible {
		t.Fatalf("Bram heard Aria's body modes %v at her release, want [2]", m)
	}
	rig.listen("Aria", 100*time.Millisecond)
	// A move does not end it.
	rig.send("Aria", OpMove, (&MoveRequest{X: 1, Z: 1}).Encode())
	// An attack is refused.
	rig.send("Aria", OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: rig.monster.ID}).Encode())
	ar, err := DecodeAttackResult(rig.until("Aria", OpAttackResult).Data)
	if err != nil || ar.Error != untouchableRefusal {
		t.Fatalf("an attack while protected: %+v %v; want refused %q", ar, err, untouchableRefusal)
	}
	if !protectedNow(rig.ids["Aria"], time.Now()) {
		t.Fatal("the protection ended before its time (after a move and a refused attack)")
	}
	if m, _ := rig.monsters.Get(rig.monster.ID); m.HP != m.MaxHP {
		t.Fatalf("the refused attack hurt the monster: %d of %d", m.HP, m.MaxHP)
	}
	// Its end: body mode 0, at the time's end.
	var ended time.Time
	deadline := time.Now().Add(2 * time.Second)
	for ended.IsZero() && time.Now().Before(deadline) {
		h := rig.listen("Bram", 100*time.Millisecond)
		for _, v := range h.modeFor(rig.ids["Aria"]) {
			if v == 0 {
				ended = time.Now()
			}
		}
	}
	if ended.IsZero() {
		t.Fatal("Bram never heard Aria's body mode 0")
	}
	if took := ended.Sub(start); took < 600*time.Millisecond || took > 1500*time.Millisecond {
		t.Fatalf("the protection ended after %v, want its 700 ms", took)
	}
	if protectedNow(rig.ids["Aria"], time.Now()) || untouchable(rig.hub, rig.ids["Aria"], time.Now()) {
		t.Fatal("still protected after the end")
	}
	rig.listen("Aria", 100*time.Millisecond)
	rig.send("Aria", OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: rig.monster.ID}).Encode())
	if ar, _ := DecodeAttackResult(rig.until("Aria", OpAttackResult).Data); ar.Error == untouchableRefusal {
		t.Fatalf("the attack after the protection is still refused: %+v", ar)
	}
}

// A player who comes into view during the protection is spawned with body
// mode 2 in the record (chardata[3], READ 0x4a9b70).
func TestRound786SpawnDuringTheProtectionCarriesMode2(t *testing.T) {
	guardOn(t, time.Hour, 0)
	rig := newArrivalRig(t)
	rig.ready("Aria")
	got := rig.ready("Bram")
	mode, ok := got.spawned[uint32(rig.ids["Aria"])]
	if !ok || mode != bodyModeInvincible {
		t.Fatalf("Bram's spawn of protected Aria: present=%v body mode %d, want 2", ok, mode)
	}
}

// The hold's timeout is retail's 300.0 s stale-player clear (READ,
// CLobby_RemoveStalePlayers 0x437a50, 0xb45c40): a client that never sends
// 0x3012 is disconnected, never put into the world, and nobody was spawned
// it.
func TestRound786HoldTimesOut(t *testing.T) {
	if got := arrivalHoldTimeout; got != 300*time.Second {
		t.Fatalf("arrivalHoldTimeout = %v, want retail's 300 s", got)
	}
	guardOn(t, time.Hour, 400*time.Millisecond)
	rig := newArrivalRig(t)
	rig.ready("Bram")
	// Aria never reports.
	deadline := time.Now().Add(3 * time.Second)
	closed := false
	for time.Now().Before(deadline) && !closed {
		rig.conns["Aria"].SetReadDeadline(time.Now().Add(200 * time.Millisecond))
		_, err := proto.Read(rig.readers["Aria"], nil, nil)
		if err != nil {
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			closed = errors.Is(err, io.EOF) || err != nil
		}
	}
	if !closed {
		t.Fatal("Aria's session was not closed after the hold's timeout")
	}
	if !waitFor(t, time.Second, func() bool { _, in := rig.hub.EntityByCharacterID(rig.ids["Aria"]); return !in }) {
		t.Fatal("Aria is still in the hub after the stale clear")
	}
	if b := rig.listen("Bram", 200*time.Millisecond); len(b.spawned) != 0 {
		t.Fatalf("Bram was spawned %v; a stale arrival is never put into the world", b.spawned)
	}
}

// Every server path that relocates a character across a load holds it until
// its 0x3012 (the census in docs/protocol/arrival_guard.md). Each case starts
// from a fresh rig with both players in, runs its path for Aria, and checks
// she is held with the path's label; the scroll paths are in
// TestRound786ScrollsAreHeld, the walk-in portal in
// TestRound786EveryRelocationGoesThroughWarpVia.
func TestRound786EveryTeleportPathIsHeld(t *testing.T) {
	cases := []struct {
		via string
		run func(rig *arrivalRig)
	}{
		{"gate teleport", func(rig *arrivalRig) {
			rig.send("Aria", OpTeleportUse, clientTeleportUse(1, 2))
			rig.until("Aria", OpChangeZoneResult)
		}},
		{"zone change", func(rig *arrivalRig) { // a GM's (Aria): the developer panel (round 854)
			rig.send("Aria", OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
			rig.until("Aria", OpChangeZoneResult)
		}},
		{"gm /tp", func(rig *arrivalRig) {
			rig.send("Aria", OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/tp 300 300"}).Encode())
			res, err := DecodeGMCommandResult(rig.until("Aria", OpGMCommandResult).Data)
			if err != nil || res.Refused || res.HasPos {
				rig.t.Fatalf("/tp reply %+v %v; want accepted with no client move (the server warps)", res, err)
			}
			czr, err := DecodeChangeZoneResult(rig.until("Aria", OpChangeZoneResult).Data)
			if err != nil || !czr.OK || czr.X != 300 || czr.Z != 300 {
				rig.t.Fatalf("/tp's arrival %+v %v; want (300, 300)", czr, err)
			}
		}},
		{"/unstuck", func(rig *arrivalRig) {
			rig.send("Aria", OpUnstuck, nil)
			rig.until("Aria", OpUnstuckResult)
			rig.until("Aria", OpChangeZoneResult)
		}},
		{"death: return point", func(rig *arrivalRig) {
			deadStateForTest(rig.t, true)
			killForTest(rig, "Aria")
			rig.send("Aria", OpRevive, []byte{byte(ReviveOptionReturnPoint)})
			rig.until("Aria", OpChangeZoneResult)
		}},
		{"death: respawn after a kill", func(rig *arrivalRig) {
			returnAfterKill(context.Background(), rig.chars, rig.eq, rig.hub, rig.ids["Aria"])
			rig.until("Aria", OpChangeZoneResult)
		}},
	}
	for _, c := range cases {
		t.Run(c.via, func(t *testing.T) {
			guardOn(t, time.Hour, 0)
			rig := newArrivalRig(t)
			rig.bothIn()
			c.run(rig)
			if !heldInHub(rig.hub, rig.ids["Aria"]) {
				t.Fatalf("%s: Aria not held after the arrival", c.via)
			}
			arrivals.Lock()
			e := arrivals.byChar[rig.ids["Aria"]]
			via := ""
			if e != nil {
				via = e.why
			}
			arrivals.Unlock()
			if via != c.via {
				t.Fatalf("held via %q, want %q", via, c.via)
			}
			if b := rig.listen("Bram", 300*time.Millisecond); len(b.spawned) != 0 {
				t.Fatalf("%s: Bram was spawned %v while Aria was loading", c.via, b.spawned)
			}
			rig.ready("Aria")
			if heldInHub(rig.hub, rig.ids["Aria"]) || !protectedNow(rig.ids["Aria"], time.Now()) {
				t.Fatalf("%s: after 0x3012 held=%v protected=%v; want released and protected", c.via,
					heldInHub(rig.hub, rig.ids["Aria"]), protectedNow(rig.ids["Aria"], time.Now()))
			}
		})
	}
}

// killForTest leaves name dead the way a monster's blow does under
// -player-dead-state: HP 0 and life state 2.
func killForTest(rig *arrivalRig, name string) {
	rig.t.Helper()
	ctx := context.Background()
	c, _ := rig.chars.GetByID(ctx, rig.ids[name])
	if _, _, err := rig.chars.ApplyDamage(ctx, c.ID, c.HP); err != nil {
		rig.t.Fatal(err)
	}
	if !rig.hub.SetLifeState(c.ID, world.LifeAlive, world.LifeDead, time.Now()) {
		rig.t.Fatalf("%s could not be marked dead", name)
	}
}

// A revive in place sets body mode 2 for 6.0 s (GObjPC::Revive,
// 0x4df463..0x4df496, READ): protected at once, no hold (it does not leave
// the world).
func TestRound786ReviveInPlaceIsProtected(t *testing.T) {
	guardOn(t, time.Hour, 0)
	deadStateForTest(t, true)
	rig := newArrivalRig(t)
	rig.bothIn()
	killForTest(rig, "Aria")
	rig.send("Aria", OpRevive, []byte{byte(ReviveOptionPresentPoint)})
	rig.until("Aria", OpReviveResult)
	if heldInHub(rig.hub, rig.ids["Aria"]) || !protectedNow(rig.ids["Aria"], time.Now()) {
		t.Fatalf("after a revive in place held=%v protected=%v; want protected in place",
			heldInHub(rig.hub, rig.ids["Aria"]), protectedNow(rig.ids["Aria"], time.Now()))
	}
	if m := rig.listen("Bram", 300*time.Millisecond).modeFor(rig.ids["Aria"]); len(m) == 0 || m[len(m)-1] != bodyModeInvincible {
		t.Fatalf("Bram heard Aria's body modes %v after her revive, want 2", m)
	}
}

// The scrolls (round 778's rig): the return scroll and the reverse return
// scroll's death point each hold the caster at the arrival.
func TestRound786ScrollsAreHeld(t *testing.T) {
	for _, c := range []struct {
		via    string
		item   int64
		option byte
	}{
		{"return scroll", fixtureReturnScroll, 0},
		{"reverse return scroll", fixtureReverseScroll, ReverseOptionMap},
	} {
		t.Run(c.via, func(t *testing.T) {
			guardOn(t, time.Hour, 0)
			rig := newScrollRig(t, 50)
			rig.roundTrip(OpReadyToPlay, nil) // released; its spawns and mode 2 follow
			for rig.read(200*time.Millisecond) != nil {
			}
			var target uint32
			if c.option == ReverseOptionMap {
				target = 24
			}
			if res := rig.use(c.item, c.option, target); res.Error != "" {
				t.Fatalf("use: %+v", res)
			}
			rig.fire()
			_, ok := rig.hub.EntityByCharacterID(rig.charID)
			if !ok || !heldInHub(rig.hub, rig.charID) {
				t.Fatalf("%s: after the cast held=%v (in world %v); want held", c.via, heldInHub(rig.hub, rig.charID), ok)
			}
			arrivals.Lock()
			via := arrivals.byChar[rig.charID].why
			arrivals.Unlock()
			if via != c.via {
				t.Fatalf("held via %q, want %q", via, c.via)
			}
		})
	}
}

// Monsters: an untouchable player -- held, or protected -- is never noticed,
// and a monster in BATTLE on one releases it at its next tick and swings no
// more (AITactics_IsValidTarget refuses body modes 2-4 and life state != 1,
// 0x540e2f/0x540e33, READ).
func TestRound786MonstersIgnoreAndDropAnUntouchablePlayer(t *testing.T) {
	arrivalGuardOn.Store(true)
	t.Cleanup(func() { arrivalGuardOn.Store(false) })
	battleForTest(t, true)
	deadStateForTest(t, true)
	aggroForTest(t, true)

	t.Run("not noticed while protected", func(t *testing.T) {
		f := startBattleFixture(t, 786, 50, 0)
		protectForTest(t, f.aria, time.Hour)
		m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
		now := aiT0
		if _, noticed := tickUntilBattle(t, f.a, m.ID, now, 30); noticed {
			t.Fatal("a monster noticed a protected player 50 units off")
		}
	})
	t.Run("not noticed while held", func(t *testing.T) {
		f := startBattleFixture(t, 787, 50, 0)
		changeZoneHeldForTest(f.hub, f.ariaSession(t), "jangan", world.Position{X: 50})
		m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
		if _, noticed := tickUntilBattle(t, f.a, m.ID, aiT0, 30); noticed {
			t.Fatal("a monster noticed a held player 50 units off")
		}
	})
	t.Run("dropped when it becomes protected", func(t *testing.T) {
		f := startBattleFixture(t, 788, 50, 0)
		m := f.monsters.SpawnSpecies("jangan", chaseMangyang, 0, 0, 0, 1000, 0, 15, 0)
		now, noticed := tickUntilBattle(t, f.a, m.ID, aiT0, 16)
		if !noticed {
			t.Fatal("setup: the monster never noticed her")
		}
		protectForTest(t, f.aria, time.Hour)
		monsterAITick(now)
		now = now.Add(MonsterAITick)
		if st := stateOf(t, f.a, m.ID); st == ai.StateBattle {
			t.Fatalf("state %v the tick after she became protected, want the target dropped", st)
		}
		f.rec.reset()
		for i := 0; i < 60; i++ {
			monsterAITick(now)
			now = now.Add(MonsterAITick)
		}
		time.Sleep(50 * time.Millisecond)
		if n := len(f.rec.strikesOf(m.ID)); n != 0 {
			t.Fatalf("%d blow(s) on a protected player", n)
		}
	})
}

// protectForTest marks id protected for d without the broadcast (the AI
// fixture's sessions have no connection).
func protectForTest(t *testing.T, id int64, d time.Duration) {
	t.Helper()
	arrivals.Lock()
	arrivals.byChar[id] = &arrivalEntry{until: time.Now().Add(d)}
	arrivals.Unlock()
	t.Cleanup(func() { forgetArrival(id) })
}

// The census, pinned (docs/protocol/arrival_guard.md): every call in this
// package that moves a character in the hub to a new place -- a zone change,
// a world entry, a server relocation -- is one of these, so a new teleport
// path cannot bypass the hold without failing here. warpVia is the one door
// (ChangeZoneHeld under the guard); the world entry's EnterHeld; the two
// Relocate calls left are Ghost Walk's in-world skill move (READ: no
// re-entry on that path, FUN_005862e0 -> CGObjPC::vslot_305 0x4ef300 ->
// MoveTo) and /unstuck's guard-off fallback.
func TestRound786EveryRelocationGoesThroughWarpVia(t *testing.T) {
	fset := token.NewFileSet()
	pkgs, err := parser.ParseDir(fset, ".", func(fi fs.FileInfo) bool { return !strings.HasSuffix(fi.Name(), "_test.go") }, 0)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string][]string{} // callee -> "func" or "func:label"
	for _, pkg := range pkgs {
		for _, f := range pkg.Files {
			for _, d := range f.Decls {
				fn, ok := d.(*ast.FuncDecl)
				if !ok || fn.Body == nil {
					continue
				}
				ast.Inspect(fn.Body, func(n ast.Node) bool {
					switch x := n.(type) {
					case *ast.SelectorExpr:
						switch x.Sel.Name {
						case "Enter", "EnterHeld", "ChangeZone", "ChangeZoneHeld", "Relocate", "Release":
							if id, ok := x.X.(*ast.Ident); ok && id.Name == "hub" {
								got[x.Sel.Name] = append(got[x.Sel.Name], fn.Name.Name)
							}
						}
					case *ast.CallExpr:
						if id, ok := x.Fun.(*ast.Ident); ok && (id.Name == "warpVia" || id.Name == "warpHome" || id.Name == "warpTo") {
							label := ""
							if last, ok := x.Args[len(x.Args)-1].(*ast.BasicLit); ok && id.Name != "warpTo" {
								label = ":" + strings.Trim(last.Value, `"`)
							}
							got[id.Name] = append(got[id.Name], fn.Name.Name+label)
						}
					}
					return true
				})
			}
		}
	}
	want := map[string][]string{
		"ChangeZone":     {"warpVia"},
		"ChangeZoneHeld": {"warpVia"},
		"Enter":          {"enterOwned"},
		"EnterHeld":      {"enterOwned"},
		"Release":        {"releaseArrival"},
		"Relocate":       {"handleUnstuck", "moveBySkill"},
		"warpTo":         {"handleChangeZone"},
		"warpHome": {"returnAfterKill:death: respawn after a kill", "returnToPoint:death: return point", "complete:return scroll",
			"skillReset:skill reset scroll"}, // round 838, servicescroll.go
		"warpVia": {"handleUnstuck:/unstuck", "use:gate teleport", "walkIn:walk-in teleport", "complete:reverse return scroll",
			"warpHome", "warpTo:zone change", "GMCommandHandler", "GMCommandHandler", // round 854: /goto <zone> too
			"handleRecallAnswer:guild recall"}, // round 844 lane G part 2, guildrecall.go
	}
	for k, w := range want {
		g := append([]string(nil), got[k]...)
		sort.Strings(g)
		sort.Strings(w)
		if strings.Join(g, "|") != strings.Join(w, "|") {
			t.Errorf("%s is called from %v, want %v -- a new relocation must go through warpVia (arrival.go's hold)", k, g, w)
		}
	}
}
