package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/account"
	"github.com/OpenSRO/OpenSRO/server/internal/character"
	"github.com/OpenSRO/OpenSRO/server/internal/combat"
	"github.com/OpenSRO/OpenSRO/server/internal/equipment"
	"github.com/OpenSRO/OpenSRO/server/internal/gateway"
	"github.com/OpenSRO/OpenSRO/server/internal/inventory"
	"github.com/OpenSRO/OpenSRO/server/internal/proto"
	"github.com/OpenSRO/OpenSRO/server/internal/quest"
	"github.com/OpenSRO/OpenSRO/server/internal/refdata"
	"github.com/OpenSRO/OpenSRO/server/internal/skill"
	"github.com/OpenSRO/OpenSRO/server/internal/world"
)

// fightConn is one logged-in player on a combat-only server (round 785's
// keep-up tests).
type fightConn struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
	id   int64
}

func startFight(t *testing.T, ref itemsAndSkills, monsters *combat.Hub) *fightConn {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating character: %v", err)
	}
	eq := fixedEquipment{worn: []equipment.Equipped{{Slot: equipment.SlotWeapon, ItemID: 100, Durability: 50}}}
	hub := world.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		CombatHandler(chars, eq, ref, hub, monsters, quest.NewMemStore(), inventory.NewMemStore(ref), skill.NewMemStore(), nil, nil, nil),
	)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	f := &fightConn{t: t, conn: conn, r: bufio.NewReader(conn), id: c.ID}
	f.write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(f.read().Data); err != nil || !lr.OK {
		t.Fatalf("login: %+v %v", lr, err)
	}
	f.write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(f.read().Data); err != nil || !ewr.OK {
		t.Fatalf("enter: %+v %v", ewr, err)
	}
	return f
}

func (f *fightConn) write(opcode uint16, data []byte) {
	if err := proto.Write(f.conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		f.t.Fatalf("Write: %v", err)
	}
}

func (f *fightConn) read() *proto.Packet {
	f.conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	p, err := proto.Read(f.r, nil, nil)
	if err != nil {
		f.t.Fatalf("Read: %v", err)
	}
	return p
}

// result is the next OpAttackResult and when it came; resync is the last
// OpMonsterMoved that came before it, nil when none did.
func (f *fightConn) result() (ar *AttackResult, at time.Time, resync *MonsterMoved) {
	for {
		p := f.read()
		switch p.Opcode {
		case OpMonsterMoved:
			mv, err := DecodeMonsterMoved(p.Data)
			if err != nil {
				f.t.Fatal(err)
			}
			resync = mv
		case OpAttackResult:
			ar, err := DecodeAttackResult(p.Data)
			if err != nil {
				f.t.Fatal(err)
			}
			return ar, time.Now(), resync
		}
	}
}

func (f *fightConn) attack(target int64) {
	f.write(OpAttack, (&AttackRequest{CharacterName: "Aria", TargetMonsterID: target}).Encode())
}

func swordRef(reuseMs int) itemsAndSkills {
	return itemsAndSkills{
		items:  map[int64]*refdata.Item{100: {ID: 100, TypeID4: 2, PhysAttackMax: 30, Range: 6}},
		skills: map[int64]*refdata.Skill{2: {ID: 2, ReuseDelayMs: reuseMs}},
	}
}

// A click inside the base attack's re-use delay is not dropped: it swings
// when the delay ends (round 785), as the engine's phase 1 waits on its
// cooldown gate. Before, the server answered nothing and the player stood
// idle beside the monster it had clicked (MEASURED on the render box: the
// second monster of a fight, clicked 0.5 s after the first one's kill, was
// never struck).
func TestClickInsideReuseDelaySwingsWhenItEnds(t *testing.T) {
	monsters := combat.NewHub()
	first := monsters.Spawn("jangan", "Mangyang", 2, 0, 0, 1, 0, 0, 0)
	second := monsters.Spawn("jangan", "Mangyang", 0, 0, 2, 100000, 0, 0, 0)
	f := startFight(t, swordRef(600), monsters)
	defer keepUp.Cancel(f.id)

	f.attack(first.ID)
	ar, t0, _ := f.result()
	if ar.Error != "" || !ar.MonsterDied {
		t.Fatalf("first swing: %+v, want the kill", ar)
	}
	f.attack(second.ID)
	ar, t1, _ := f.result()
	if ar.Error != "" || ar.MonsterID != second.ID || ar.MonsterDamage <= 0 {
		t.Fatalf("the click inside the delay: %+v, want a hit on monster %d", ar, second.ID)
	}
	if gap := t1.Sub(t0); gap < 550*time.Millisecond {
		t.Errorf("the deferred swing came %v after the first, inside the 600 ms delay", gap)
	}
	ar, t2, _ := f.result()
	if ar.Error != "" || ar.MonsterID != second.ID {
		t.Fatalf("the keep-up after the deferred swing: %+v", ar)
	}
	if gap := t2.Sub(t1); gap < 550*time.Millisecond {
		t.Errorf("the keep-up repeat came %v after the deferred swing, inside the 600 ms delay", gap)
	}
	// A further click on the target the keep-up already swings at changes
	// nothing: the next result still comes a whole delay after the last.
	f.attack(second.ID)
	ar, t3, _ := f.result()
	if ar.Error != "" || t3.Sub(t2) < 550*time.Millisecond {
		t.Errorf("after a repeated click: %+v, %v after the last swing", ar, t3.Sub(t2))
	}
}

// A keep-up repeat that finds its target out of reach tells the client: the
// monster's position first (resyncMonster), then the refusal naming it, so
// the client walks back in -- the walk the engine's phase 1 makes. Before
// round 785 the run ended in silence.
func TestKeepUpOutOfReachIsReported(t *testing.T) {
	monsters := combat.NewHub()
	m := monsters.Spawn("jangan", "Mangyang", 2, 0, 0, 100000, 0, 0, 0)
	f := startFight(t, swordRef(300), monsters)
	defer keepUp.Cancel(f.id)

	f.attack(m.ID)
	if ar, _, _ := f.result(); ar.Error != "" {
		t.Fatalf("first swing: %+v", ar)
	}
	// The monster leaves reach between swings.
	monsters.SetMotion(m.ID, 400, 0, 1e9, 0)
	for i := 0; i < 3; i++ { // MoverMaxStep caps a step at 160
		monsters.StepCells(1, nil, nil)
	}
	ar, _, resync := f.result()
	if ar.Error != "too far away" || ar.MonsterID != m.ID {
		t.Fatalf("the repeat out of reach: %+v, want \"too far away\" naming monster %d", ar, m.ID)
	}
	if resync == nil || resync.MonsterID != m.ID || resync.X != 400 || resync.DestX != 400 {
		t.Errorf("the monster's position before the refusal: %+v, want monster %d at x 400", resync, m.ID)
	}
	if _, running := keepUp.Target(f.id); running {
		t.Error("the keep-up still runs after reporting its target out of reach")
	}
}
