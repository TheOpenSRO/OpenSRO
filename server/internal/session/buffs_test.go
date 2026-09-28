package session

// Round 616: buffs, self-casts and Ghost Walk through the real handlers. The
// skill rows are synthetic, typed with the values the spec MEASURED on the
// retail rows (no game data in the repo).

import (
	"bufio"
	"context"
	"errors"
	"math"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/buff"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/combat"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/mana"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/quest"
	"github.com/OpenSRO/srrevamp/server/internal/refdata"
	"github.com/OpenSRO/srrevamp/server/internal/skill"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

// buffSkillRef serves the shapes this round routes.
type buffSkillRef struct{}

const (
	skGrassWalkA1 = 113  // SKILL_CH_LIGHTNING_GYEONGGONG_A_01
	skGrassWalkA2 = 1130 // its level 2 (a synthetic id)
	skGhostWalkB1 = 114  // SKILL_CH_LIGHTNING_GYEONGGONG_B_01
	skImbueA1     = 90   // SKILL_CH_COLD_GIGONGTA_A_01: kind 3 WITH 'att'
	skNbufSelf    = 8001 // a synthetic self-cast 'nbuf' buff
	skExplosionA1 = 8002 // SKILL_EU_BARD_BATTLAA_EXPLOSION_A's shape: TR 0, kind 0, 'att'
	skSmashA1     = 3    // SKILL_CH_SWORD_SMASH_A_01's shape: TR 1, hostile only
)

func (buffSkillRef) GetSkill(_ context.Context, id int64) (*refdata.Skill, error) {
	switch id {
	case skGrassWalkA1:
		return &refdata.Skill{ID: id, GroupID: 260, BasicLevel: 1, ActionKind: 3, DuraMs: 355462,
			BuffParams: "hste:20", NoCombatParam: true, ZeroDamage: true}, nil
	case skGrassWalkA2:
		return &refdata.Skill{ID: id, GroupID: 260, BasicLevel: 2, ActionKind: 3, DuraMs: 370588,
			BuffParams: "hste:23", NoCombatParam: true, ZeroDamage: true}, nil
	case skGhostWalkB1:
		return &refdata.Skill{ID: id, GroupID: 261, BasicLevel: 1, ActionKind: 0, TargetRequired: true,
			TargetLand: true, Tele0: 500, Tele1: 100, NoCombatParam: true, ZeroDamage: true}, nil
	case skImbueA1:
		return &refdata.Skill{ID: id, GroupID: 30, BasicLevel: 1, ActionKind: 3, DuraMs: 15000,
			AttackPercent: 100, DamageMin: 16, DamageMax: 26, AttackType: 8, Range: 0}, nil
	case skExplosionA1:
		return &refdata.Skill{ID: id, GroupID: 9000, BasicLevel: 1, ActionKind: 0, AttackPercent: 368,
			DamageMin: 106, DamageMax: 130, AttackType: 8}, nil
	case skSmashA1:
		return &refdata.Skill{ID: id, GroupID: 174, BasicLevel: 1, ActionKind: 0, TargetRequired: true,
			AttackPercent: 143, DamageMin: 15, DamageMax: 18, AttackType: 4}, nil
	case skNbufSelf:
		return &refdata.Skill{ID: id, GroupID: 8001, BasicLevel: 1, ActionKind: 3, DuraMs: 60000,
			Nbuf: true, NoCombatParam: true, ZeroDamage: true}, nil
	}
	return nil, errors.New("no such skill")
}

type buffWorld struct {
	aria    int64
	hub     *world.Hub
	monster int64
	conn    net.Conn
	r       *bufio.Reader
}

func startBuffWorld(t *testing.T) *buffWorld {
	t.Helper()
	ctx := context.Background()
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
	for _, id := range []int64{skGrassWalkA1, skGrassWalkA2, skGhostWalkB1, skImbueA1, skNbufSelf, skExplosionA1, skSmashA1} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	monsters := combat.NewHub()
	// Far out of any reach: a buff must not care where the target is.
	m := monsters.Spawn("jangan", "Mangyang", 1, 5000, 0, 5000, 100000, 0, 0)
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, monsters, quest.NewMemStore(), inv, buffSkillRef{}, nil, mana.NewTracker(), nil),
		BuffHandler(chars, hub),
	)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	conn := dialTestServer(t, addr)
	t.Cleanup(func() { conn.Close() })
	w := &buffWorld{aria: c.ID, hub: hub, monster: m.ID, conn: conn, r: bufio.NewReader(conn)}
	t.Cleanup(func() { buffBooks.EndAll(c.ID); motions.clear(c.ID) })
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

func (w *buffWorld) write(t *testing.T, op uint16, data []byte) {
	t.Helper()
	if err := proto.Write(w.conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

// expect reads until a packet with op arrives, skipping others.
func (w *buffWorld) expect(t *testing.T, op uint16) *proto.Packet {
	t.Helper()
	for i := 0; i < 16; i++ {
		w.conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(w.r, nil, nil)
		if err != nil {
			t.Fatalf("waiting for 0x%04X: %v", op, err)
		}
		if p.Opcode == op {
			return p
		}
	}
	t.Fatalf("no 0x%04X", op)
	return nil
}

// expectNone reports a packet with op arriving within d.
func (w *buffWorld) expectNone(t *testing.T, op uint16, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		w.conn.SetReadDeadline(deadline)
		p, err := proto.Read(w.r, nil, nil)
		if err != nil {
			return // the deadline: nothing came
		}
		if p.Opcode == op {
			t.Fatalf("an unexpected 0x%04X: % x", op, p.Data)
		}
	}
}

func (w *buffWorld) cast(t *testing.T, req *UseSkillRequest) *AttackResult {
	t.Helper()
	req.CharacterName = "Aria"
	w.write(t, OpUseSkill, req.Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil {
		t.Fatal(err)
	}
	return ar
}

// Grass Walk A lv1 needs no target, starts a buff whose OpBuffStart carries
// the duration and the new run speed 60 (from 50), and a cancel ends it with
// the run speed back at 50.
func TestGrassWalkStartsABuffAndMovesRunSpeed50To60(t *testing.T) {
	w := startBuffWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	if ar.Error != "" {
		t.Fatalf("Grass Walk refused: %q", ar.Error)
	}
	start, err := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if start.OwnerID != w.aria || start.SkillID != skGrassWalkA1 || start.Token == 0 {
		t.Fatalf("OpBuffStart %+v", start)
	}
	if start.DurationMs != 355462 || start.RemainingMs <= 355000 || start.RemainingMs > 355462 {
		t.Fatalf("OpBuffStart duration %d remaining %d, want 355462", start.DurationMs, start.RemainingMs)
	}
	if start.RunSpeed != 60 {
		t.Fatalf("OpBuffStart run speed %d, want 60", start.RunSpeed)
	}

	w.write(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: skGrassWalkA1, Token: start.Token}).Encode())
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil {
		t.Fatal(err)
	}
	if end.OwnerID != w.aria || len(end.Tokens) != 1 || end.Tokens[0] != start.Token || end.RunSpeed != 50 {
		t.Fatalf("OpBuffEnd %+v, want token %d and run speed 50", end, start.Token)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Fatalf("%d records after the cancel", n)
	}
}

// The ticker ends the buff at its end time, with OpBuffEnd and the run speed.
func TestBuffTickerEndsTheBuffWithOpBuffEnd(t *testing.T) {
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	start, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	rec := buffBooks.Active(w.aria)[0]
	expireBuffs(w.hub, rec.EndsAt())
	w.expectNone(t, OpBuffEnd, 150*time.Millisecond)
	expireBuffs(w.hub, rec.EndsAt().Add(time.Millisecond))
	end, err := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if err != nil || len(end.Tokens) != 1 || end.Tokens[0] != start.Token || end.RunSpeed != 50 {
		t.Fatalf("OpBuffEnd %+v %v", end, err)
	}
}

// A recast at a lower level is refused with the OVERLAP text before it costs
// anything; a higher level ends the old record and starts the new one.
func TestBuffRecastRule(t *testing.T) {
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA2, TargetType: TargetNone, HasTargetType: true})
	first, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true}); ar.Error != overlapRefusal {
		t.Fatalf("a lower-level recast: %q, want the overlap refusal", ar.Error)
	}
	if ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA2, TargetType: TargetNone, HasTargetType: true}); ar.Error != "" {
		t.Fatalf("an equal-level recast refused: %q", ar.Error)
	}
	end, _ := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if len(end.Tokens) != 1 || end.Tokens[0] != first.Token {
		t.Fatalf("the recast ended %+v, want %d", end, first.Token)
	}
	second, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if second.Token == first.Token || second.RunSpeed != uint32(math.Round(50*1.23)) {
		t.Fatalf("second start %+v", second)
	}
}

// An imbue is a kind-3 buff that carries 'att': it starts a buff on the
// caster, does not attack the (far) target, and is not refused as too far.
func TestImbueStartsABuffInsteadOfAnAttack(t *testing.T) {
	w := startBuffWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skImbueA1, TargetMonsterID: w.monster, TargetType: TargetEntity, HasTargetType: true})
	if ar.Error != "" || ar.MonsterDamage != 0 {
		t.Fatalf("imbue answered %+v, want a clean cast with no blow", ar)
	}
	start, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if start.SkillID != skImbueA1 || start.RunSpeed != 0 || start.DurationMs != 15000 {
		t.Fatalf("OpBuffStart %+v", start)
	}
}

// The dispel of an 'nbuf' buff another caster put on Aria is refused
// silently; her own 'nbuf' buff ends.
func TestBuffCancelNbufRefusal(t *testing.T) {
	w := startBuffWorld(t)
	other, _, _ := buffBooks.Start(w.aria, buff.Spec{SkillID: 8002, GroupID: 8002, Level: 1, CasterID: w.aria + 1000,
		DuraMs: 60000, Nbuf: true}, time.Now())
	w.write(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: 8002, Token: other.Token}).Encode())
	w.expectNone(t, OpBuffEnd, 300*time.Millisecond)
	if n := len(buffBooks.Active(w.aria)); n != 1 {
		t.Fatalf("%d records, want the refused one kept", n)
	}
	w.cast(t, &UseSkillRequest{SkillID: skNbufSelf, TargetType: TargetNone, HasTargetType: true})
	own, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	w.write(t, OpBuffCancel, (&BuffCancelRequest{CharacterName: "Aria", SkillID: skNbufSelf}).Encode())
	end, _ := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if len(end.Tokens) != 1 || end.Tokens[0] != own.Token {
		t.Fatalf("OpBuffEnd %+v, want %d", end, own.Token)
	}
}

// Ghost Walk: a point 150 away with tele[1] = 100 lands 100 along the line; a
// point 80 away lands on the point. The hub stores it and OpSkillMove says it.
func TestGhostWalkClampsToTele1(t *testing.T) {
	w := startBuffWorld(t)
	e, _ := w.hub.EntityByCharacterID(w.aria)
	from := e.Pos
	for _, tc := range []struct {
		name     string
		dx, dz   float64
		wantDist float64
	}{
		{"150 away clamps to 100", 90, 120, 100},
		{"80 away lands on the point", 0, 80, 80},
	} {
		t.Run(tc.name, func(t *testing.T) {
			to := world.Position{X: from.X + tc.dx, Y: from.Y, Z: from.Z + tc.dz}
			ar := w.cast(t, &UseSkillRequest{SkillID: skGhostWalkB1, TargetType: TargetGround, HasTargetType: true,
				X: float32(to.X), Y: float32(to.Y), Z: float32(to.Z)})
			if ar.Error != "" {
				t.Fatalf("Ghost Walk refused: %q", ar.Error)
			}
			mv, err := DecodeSkillMove(w.expect(t, OpSkillMove).Data)
			if err != nil {
				t.Fatal(err)
			}
			got := math.Hypot(float64(mv.X)-from.X, float64(mv.Z)-from.Z)
			if math.Abs(got-tc.wantDist) > 1e-3 || mv.CharacterID != w.aria || mv.SkillID != skGhostWalkB1 {
				t.Fatalf("landed %v from the start (%+v), want %v", got, mv, tc.wantDist)
			}
			// Along the line: the landing and the point share a direction.
			k := tc.wantDist / math.Hypot(tc.dx, tc.dz)
			if math.Abs(float64(mv.X)-(from.X+tc.dx*k)) > 1e-3 || math.Abs(float64(mv.Z)-(from.Z+tc.dz*k)) > 1e-3 {
				t.Fatalf("landed off the line: %+v", mv)
			}
			now, _ := w.hub.EntityByCharacterID(w.aria)
			if math.Abs(now.Pos.X-float64(mv.X)) > 1e-3 || math.Abs(now.Pos.Z-float64(mv.Z)) > 1e-3 {
				t.Fatalf("the hub holds %+v, the move said %+v", now.Pos, mv)
			}
			// Put her back for the next case.
			w.hub.Move(e.Session, from)
		})
	}
	// A Ghost Walk with no point is refused (the context builder aborts).
	if ar := w.cast(t, &UseSkillRequest{SkillID: skGhostWalkB1, TargetType: TargetNone, HasTargetType: true}); ar.Error != groundRefusal {
		t.Fatalf("Ghost Walk without a point: %q", ar.Error)
	}
	// A ground point for a skill with no ground move is refused.
	if ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetGround, HasTargetType: true}); ar.Error != groundRefusal {
		t.Fatalf("Grass Walk on the ground: %q", ar.Error)
	}
}

// A death clears the book and tells the zone.
func TestDeathEndsEveryBuff(t *testing.T) {
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	start, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if !markDead(strikeDeps{hub: w.hub}, w.aria, time.Now()) {
		t.Fatal("markDead did not change the state")
	}
	end, _ := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if len(end.Tokens) != 1 || end.Tokens[0] != start.Token || end.RunSpeed != 50 {
		t.Fatalf("OpBuffEnd %+v", end)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Fatalf("%d records after death", n)
	}
}

// An OpUseSkill without the suffix -- every client before round 617 --
// decodes as an entity target; the ground suffix round-trips.
func TestUseSkillRequestSuffix(t *testing.T) {
	old := encodeStrings("Aria")
	old = append(old, encodeInt64(7)...)
	old = append(old, encodeInt64(42)...)
	got, err := DecodeUseSkillRequest(old)
	if err != nil || got.Target() != TargetEntity || got.HasTargetType || got.TargetMonsterID != 42 || got.SkillID != 7 {
		t.Fatalf("an old request decoded %+v, %v; want an entity target", got, err)
	}
	want := &UseSkillRequest{CharacterName: "Aria", SkillID: 114, TargetType: TargetGround, HasTargetType: true, X: 1.5, Y: -2, Z: 300}
	got, err = DecodeUseSkillRequest(want.Encode())
	if err != nil || *got != *want {
		t.Fatalf("ground round trip %+v, %v", got, err)
	}
	if _, err := DecodeUseSkillRequest(append(old, TargetGround, 1, 2)); err == nil {
		t.Fatal("a truncated ground point decoded")
	}
	if _, err := DecodeUseSkillRequest(append(old, 9)); err == nil {
		t.Fatal("an unknown target type decoded")
	}
}

func TestBuffPacketsRoundTrip(t *testing.T) {
	s := &BuffStart{OwnerID: 5, SkillID: 113, Token: 9, DurationMs: 355462, RemainingMs: 1000, RunSpeed: 60}
	if got, err := DecodeBuffStart(s.Encode()); err != nil || *got != *s {
		t.Fatalf("BuffStart %+v %v", got, err)
	}
	e := &BuffEnd{OwnerID: 5, Tokens: []uint32{9, 10}, RunSpeed: 50}
	if got, err := DecodeBuffEnd(e.Encode()); err != nil || got.OwnerID != 5 || len(got.Tokens) != 2 || got.Tokens[1] != 10 || got.RunSpeed != 50 {
		t.Fatalf("BuffEnd %+v %v", got, err)
	}
	c := &BuffCancelRequest{CharacterName: "Aria", SkillID: 113, Token: 9}
	if got, err := DecodeBuffCancelRequest(c.Encode()); err != nil || *got != *c {
		t.Fatalf("BuffCancel %+v %v", got, err)
	}
	m := &SkillMove{CharacterID: 5, SkillID: 114, X: 1, Y: 2, Z: 3}
	if got, err := DecodeSkillMove(m.Encode()); err != nil || *got != *m {
		t.Fatalf("SkillMove %+v %v", got, err)
	}
}

// The four opcodes are the contract's and collide with no other.
func TestBuffOpcodes(t *testing.T) {
	if OpBuffStart != 0x00F5 || OpBuffEnd != 0x00F6 || OpBuffCancel != 0x00F7 || OpSkillMove != 0x00F8 {
		t.Fatal("the round-616 opcodes moved")
	}
	for _, op := range []uint16{OpTeleportUse, OpTeleportResult, OpGMCommand, OpGMCommandResult,
		OpSpendStatPoints, OpCharacterStats, OpCharacterStatsResult, OpUseSkill} {
		if op >= 0x00F5 && op <= 0x00F8 {
			t.Errorf("0x%04X is already taken", op)
		}
	}
}

func TestGhostWalkDestination3D(t *testing.T) {
	from := world.Position{X: 10, Y: 0, Z: 10}
	got := ghostWalkDestination(from, world.Position{X: 10, Y: 0, Z: 160}, 100)
	if got != (world.Position{X: 10, Y: 0, Z: 110}) {
		t.Fatalf("got %+v", got)
	}
	got = ghostWalkDestination(from, world.Position{X: 10, Y: 0, Z: 90}, 100)
	if got != (world.Position{X: 10, Y: 0, Z: 90}) {
		t.Fatalf("got %+v", got)
	}
	// The height counts: 60 up and 80 across is 100.
	got = ghostWalkDestination(from, world.Position{X: 10, Y: 120, Z: 170}, 100)
	if math.Abs(got.Y-60) > 1e-9 || math.Abs(got.Z-90) > 1e-9 {
		t.Fatalf("got %+v", got)
	}
}

// OpSelfID 0x00F9 reaches the entering client after OpEnterWorldResult,
// carrying the id OpBuffStart names as ownerId; a second entry (a reconnect)
// gets it again.
func TestSelfIDIsSentOnEntry(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	c, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	inv := inventory.NewMemStore(stubCombatItems{})
	eq := equipment.NewMemStore(inv)
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub))
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	if OpSelfID != 0x00F9 {
		t.Fatalf("OpSelfID is 0x%04X, the contract says 0x00F9", OpSelfID)
	}
	for attempt := 0; attempt < 2; attempt++ {
		conn := dialTestServerRaw(t, addr)
		r := bufio.NewReader(conn)
		write := func(op uint16, data []byte) {
			if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
				t.Fatal(err)
			}
		}
		write(OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
		write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
		sawResult := false
		var got *SelfID
		for got == nil {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			p, err := proto.Read(r, nil, nil)
			if err != nil {
				t.Fatalf("attempt %d: no OpSelfID: %v", attempt, err)
			}
			switch p.Opcode {
			case OpEnterWorldResult:
				sawResult = true
			case OpSelfID:
				if !sawResult {
					t.Fatalf("attempt %d: OpSelfID before OpEnterWorldResult", attempt)
				}
				if got, err = DecodeSelfID(p.Data); err != nil {
					t.Fatal(err)
				}
			}
		}
		if got.CharacterID != c.ID {
			t.Fatalf("attempt %d: OpSelfID %d, want %d", attempt, got.CharacterID, c.ID)
		}
		conn.Close()
		time.Sleep(50 * time.Millisecond) // let the disconnect leave the hub
	}
}

// OpAttackResult echoes the request's targetType in a trailing byte: 0 for a
// self-cast, 2 for a ground cast, 1 for an old-format request (and a swing).
// A targetType 0 cast of a TR-0 row carrying 'att' resolves no blow and
// ignores the monster field; one of a hostile TR-1 row is refused.
func TestAttackResultEchoesTargetType(t *testing.T) {
	w := startBuffWorld(t)
	ar := w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	if ar.EchoedTargetType() != TargetNone {
		t.Fatalf("Grass Walk's result echoes %d, want 0", ar.EchoedTargetType())
	}
	e, _ := w.hub.EntityByCharacterID(w.aria)
	ar = w.cast(t, &UseSkillRequest{SkillID: skGhostWalkB1, TargetType: TargetGround, HasTargetType: true,
		X: float32(e.Pos.X), Y: float32(e.Pos.Y), Z: float32(e.Pos.Z + 10)})
	if ar.Error != "" || ar.EchoedTargetType() != TargetGround {
		t.Fatalf("Ghost Walk's result %+v echoes %d, want 2", ar, ar.EchoedTargetType())
	}
	ar = w.cast(t, &UseSkillRequest{SkillID: skExplosionA1, TargetMonsterID: w.monster, TargetType: TargetNone, HasTargetType: true})
	if ar.Error != "" || ar.MonsterDamage != 0 || ar.MonsterID != 0 || ar.EchoedTargetType() != TargetNone {
		t.Fatalf("a targetType 0 'att' cast answered %+v; want no blow, no monster, echo 0", ar)
	}
	ar = w.cast(t, &UseSkillRequest{SkillID: skSmashA1, TargetMonsterID: w.monster, TargetType: TargetNone, HasTargetType: true})
	if ar.Error != targetRefusal || ar.EchoedTargetType() != TargetNone {
		t.Fatalf("a targetType 0 Smash answered %+v", ar)
	}
	// An old-format request is an entity target: the far monster is out of
	// reach, and the refusal echoes 1.
	ar = w.cast(t, &UseSkillRequest{SkillID: skSmashA1, TargetMonsterID: w.monster})
	if ar.Error != "too far away" || ar.EchoedTargetType() != TargetEntity || ar.HasTargetType {
		t.Fatalf("an old-format Smash answered %+v", ar)
	}
	// On the wire: the byte after MonsterID; a 42-byte result decodes as 1.
	enc := (&AttackResult{MonsterID: 5, TargetType: TargetGround, HasTargetType: true}).Encode()
	if enc[len(enc)-1] != TargetGround {
		t.Fatalf("the trailing byte is %d", enc[len(enc)-1])
	}
	if old, err := DecodeAttackResult(enc[:len(enc)-1]); err != nil || old.EchoedTargetType() != TargetEntity || old.MonsterID != 5 {
		t.Fatalf("an older result decoded %+v, %v", old, err)
	}
	if plain := (&AttackResult{}).Encode(); plain[len(plain)-1] != TargetEntity {
		t.Fatalf("a swing's result ends %d, want 1", plain[len(plain)-1])
	}
}

// OpBuffStart and OpBuffEnd end with an ownerKind byte (0 character, 1
// monster); a payload without it decodes as a character.
func TestBuffPacketsOwnerKind(t *testing.T) {
	s := &BuffStart{OwnerID: 5, SkillID: 113, Token: 9, DurationMs: -1, RemainingMs: -1, OwnerKind: OwnerMonster}
	enc := s.Encode()
	if len(enc) != 41 || enc[40] != OwnerMonster {
		t.Fatalf("BuffStart is %d bytes ending %d", len(enc), enc[len(enc)-1])
	}
	if got, err := DecodeBuffStart(enc[:40]); err != nil || got.OwnerKind != OwnerCharacter || got.Token != 9 {
		t.Fatalf("a 40-byte BuffStart decoded %+v, %v", got, err)
	}
	e := &BuffEnd{OwnerID: 5, Tokens: []uint32{9}, RunSpeed: 50, OwnerKind: OwnerMonster}
	enc = e.Encode()
	if got, err := DecodeBuffEnd(enc); err != nil || got.OwnerKind != OwnerMonster {
		t.Fatalf("BuffEnd decoded %+v, %v", got, err)
	}
	if got, err := DecodeBuffEnd(enc[:len(enc)-1]); err != nil || got.OwnerKind != OwnerCharacter || got.RunSpeed != 50 {
		t.Fatalf("a BuffEnd without the byte decoded %+v, %v", got, err)
	}
	// What the server sends for a character's buff says so.
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	p := w.expect(t, OpBuffStart)
	if len(p.Data) != 41 || p.Data[40] != OwnerCharacter {
		t.Fatalf("the server's OpBuffStart is %d bytes, kind %d", len(p.Data), p.Data[len(p.Data)-1])
	}
}
