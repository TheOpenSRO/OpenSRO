package session

// Round 636's negative: the same file runs against dev 5a82339 (before the
// round) and after it. Its skill rows are the six rows it casts, in the
// export's CSV layout -- typed here as test data, no archive in the repo -- read
// through refdata.LoadSkillsCSV: an export made before round 636 stops at
// column 63, and the loader ignores what it does not know, so the file
// compiles and runs on both sides and only the rule differs.

import (
	"bufio"
	"context"
	"errors"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/combat"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gm"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/mana"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/quest"
	"github.com/TheOpenSRO/OpenSRO/server/internal/refdata"
	"github.com/TheOpenSRO/OpenSRO/server/internal/skill"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// The six rows in the export's column layout (cmd/export-refdata -mode
// skills), typed with only the values the cast path reads -- id, group,
// code, level, the no-blow flags, the buff columns 47..63 and the recast
// columns 64..76 -- MEASURED on the RE box's export; every other column is
// zero (SYNTHETIC): Cold Protection A lv1 (93), Grass Walk - Flow lv1/lv2
// (113/1276), - Speed lv1 (115), E lv1 (8148), Fire Protection A lv1 (133).
const stack636CSV = `93,240,SKILL_CH_COLD_GANGGI_A_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,-1875767296,1,0,0,0,0,0,"defp:2,0,0",0,0,0,2,0,0,0,0,0,0,0,0,0,SKILL_CH_COLD_GANGGI_A,2,0
113,260,SKILL_CH_LIGHTNING_GYEONGGONG_A_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,355462,0,0,0,0,0,0,hste:20,0,0,0,6,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_A,1,0
115,262,SKILL_CH_LIGHTNING_GYEONGGONG_C_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,557143,0,0,0,0,0,0,hste:55,0,0,0,6,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_C,1,0
133,280,SKILL_CH_FIRE_GANGGI_A_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,-1875767296,1,0,0,0,0,0,"defp:0,6,0",0,0,0,3,0,0,0,0,0,0,0,0,0,SKILL_CH_FIRE_GANGGI_A,2,0
8148,493,SKILL_CH_LIGHTNING_GYEONGGONG_E_01,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,829412,0,0,0,0,0,0,hste:93,0,0,0,6,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_E,1,0
1276,260,SKILL_CH_LIGHTNING_GYEONGGONG_A_02,0,2,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,,0,0,0,0,0,0,0,0,0,0,,0,1,1,0,0,0,0,0,0,0,0,0,0,0,3,0,0,0,0,0,370588,0,0,0,0,0,0,hste:23,0,0,0,6,0,0,0,0,0,0,0,0,0,SKILL_CH_LIGHTNING_GYEONGGONG_A,1,0
`

type csvSkillRef map[int64]*refdata.Skill

func (r csvSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	if s, ok := r[id]; ok {
		cp := *s
		return &cp, nil
	}
	return nil, errors.New("no such skill")
}

type stackWorld struct {
	aria int64
	conn net.Conn
	r    *bufio.Reader
	held []*proto.Packet
}

func startStackWorld(t *testing.T) *stackWorld {
	t.Helper()
	ctx := context.Background()
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(stack636CSV))
	if err != nil || len(rows) != 6 {
		t.Fatalf("the rows: %d, %v", len(rows), err)
	}
	ref := csvSkillRef{}
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	inv.AddItem(ctx, c.ID, 100, 1)
	eq := equipment.NewMemStore(inv)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)
	skills := skill.NewMemStore()
	for i := range rows {
		// The costs and the re-use delay are zeroed (SYNTHETIC) so every
		// cast reaches the recast rule: the gate tests the cooldown and the
		// MP before row 16, and a level-1 character's MP runs out.
		rows[i].ConsumeMP, rows[i].ConsumeHP, rows[i].ReuseDelayMs, rows[i].CooldownGroup = 0, 0, 0, 0
		// A learn cost (SYNTHETIC; the rows above carry none): a mastery-less
		// row with none is a monster's shape, which a player may not cast
		// (playerHoldRefusal, the round 691 review).
		rows[i].ReqLearnSP = 1
		ref[rows[i].ID] = &rows[i]
		if err := skills.Learn(ctx, c.ID, rows[i].ID); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, combat.NewHub(), quest.NewMemStore(), inv, ref, nil, mana.NewTracker(), nil),
		BuffHandler(chars, hub),
		GMCommandHandler(chars, gm.ParseAccounts("alice"), nil, hub, nil),
	)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	sctx, cancel := context.WithCancel(context.Background())
	go srv.ListenAndServe(sctx)
	t.Cleanup(cancel)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	w := &stackWorld{aria: c.ID, conn: conn, r: bufio.NewReader(conn)}
	t.Cleanup(func() {
		buffBooks.EndAll(c.ID)
		motions.clear(c.ID)
		// A /speed left set would outlive the test (it is kept outside the
		// book): the base has no such command, so this is a GM line.
		w.write(t, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/speed off"}).Encode())
	})
	w.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(w.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login: %v %+v", err, lr)
	}
	w.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(w.expect(t, OpEnterWorldResult).Data); err != nil || !ewr.OK {
		t.Fatalf("enter world: %v %+v", err, ewr)
	}
	return w
}

func (w *stackWorld) write(t *testing.T, op uint16, data []byte) {
	t.Helper()
	if err := proto.Write(w.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

func (w *stackWorld) expect(t *testing.T, op uint16) *proto.Packet {
	t.Helper()
	for i, p := range w.held {
		if p.Opcode == op {
			w.held = append(w.held[:i], w.held[i+1:]...)
			return p
		}
	}
	for i := 0; i < 16; i++ {
		w.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(w.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for 0x%04X: %v", op, err)
		}
		if p.Opcode == op {
			return p
		}
		w.held = append(w.held, p)
	}
	t.Fatalf("no 0x%04X", op)
	return nil
}

func (w *stackWorld) cast(t *testing.T, id int64) string {
	t.Helper()
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Aria", SkillID: id, TargetType: TargetNone, HasTargetType: true}).Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	return ar.Error
}

// Fire Protection twice: the second is refused and one record stays.
func TestRound636FireProtectionTwice(t *testing.T) {
	w := startStackWorld(t)
	if e := w.cast(t, 133); e != "" {
		t.Fatalf("the first Fire Protection: %q", e)
	}
	if e := w.cast(t, 133); e != overlapRefusal {
		t.Errorf("the second Fire Protection: %q, want %q", e, overlapRefusal)
	}
	if n := len(buffBooks.Active(w.aria)); n != 1 {
		t.Errorf("%d Fire Protection records, want 1", n)
	}
	if e := w.cast(t, 93); e != "" {
		t.Errorf("Cold Protection beside it: %q", e)
	}
}

// Grass Walk A then C, then E: only A runs; A lv2 then replaces A lv1.
func TestRound636GrassWalkVariants(t *testing.T) {
	w := startStackWorld(t)
	if e := w.cast(t, 113); e != "" {
		t.Fatalf("Grass Walk A: %q", e)
	}
	for _, id := range []int64{115, 8148} {
		if e := w.cast(t, id); e != overlapRefusal {
			t.Errorf("skill %d over Grass Walk A: %q, want %q", id, e, overlapRefusal)
		}
	}
	if n, s := len(buffBooks.Active(w.aria)), buffBooks.RunSpeed(w.aria); n != 1 || s != 60 {
		t.Errorf("%d records at run speed %d, want Grass Walk A alone at 60", n, s)
	}
	if e := w.cast(t, 1276); e != "" {
		t.Errorf("Grass Walk A lv2 over lv1: %q", e)
	}
	if e := w.cast(t, 113); e != overlapRefusal {
		t.Errorf("Grass Walk A lv1 under lv2: %q, want %q", e, overlapRefusal)
	}
}

// /speed 3 sets the GM's run speed to 150.
func TestRound636SpeedCommand(t *testing.T) {
	w := startStackWorld(t)
	w.write(t, OpGMCommand, (&GMCommandRequest{Name: "Aria", Line: "/speed 3"}).Encode())
	res, err := DecodeGMCommandResult(w.expect(t, OpGMCommandResult).Data)
	if err != nil || res.Refused {
		t.Fatalf("/speed 3: %+v %v", res, err)
	}
	if s := buffBooks.RunSpeed(w.aria); s != 150 {
		t.Errorf("run speed %d after /speed 3, want 150", s)
	}
}
