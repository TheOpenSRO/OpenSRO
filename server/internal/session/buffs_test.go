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

// buffSkillRef serves the shapes this round routes. The rows carry the
// retail values MEASURED on the RE box's skilldata (typed here as test data;
// no archive is in the repo), except where a comment says SYNTHETIC. Only
// the columns a test reads are filled; every other column is left zero.
type buffSkillRef struct{}

const (
	skGrassWalkA1 = 113   // SKILL_CH_LIGHTNING_GYEONGGONG_A_01: group 260, kind 3, dura 355462, hste 20
	skGrassWalkA2 = 1276  // SKILL_CH_LIGHTNING_GYEONGGONG_A_02: group 260, lv 2, dura 370588, hste 23
	skGhostWalkB1 = 114   // SKILL_CH_LIGHTNING_GYEONGGONG_B_01: group 261, TR 1, Land 1, tele 500,100
	skImbueA1     = 90    // SKILL_CH_COLD_GIGONGTA_A_01: group 237, kind 3, dura 15000, att 8,100,16,26
	skNbufSelf    = 8001  // SYNTHETIC: a self-cast 'nbuf' buff
	skExplosionA1 = 11265 // SKILL_EU_BARD_BATTLAA_EXPLOSION_A_01: group 726, TR 0, kind 0, att 8,368,106,130
	skSmashA1     = 3     // SKILL_CH_SWORD_SMASH_A_01: group 174, TR 1, att 5,143,15,18 (groups: hostile only)
	skDaggerSpdA1 = 9834  // SKILL_EU_ROG_DAGGERA_SPEED_A_01: group 628, kind 3, dura 15000, hst2 48
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
		return &refdata.Skill{ID: id, GroupID: 237, BasicLevel: 1, ActionKind: 3, DuraMs: 15000,
			AttackPercent: 100, DamageMin: 16, DamageMax: 26, AttackType: 8, Range: 0}, nil
	case skExplosionA1:
		return &refdata.Skill{ID: id, GroupID: 726, BasicLevel: 1, ActionKind: 0, AttackPercent: 368,
			DamageMin: 106, DamageMax: 130, AttackType: 8}, nil
	case skSmashA1:
		return &refdata.Skill{ID: id, GroupID: 174, BasicLevel: 1, ActionKind: 0, TargetRequired: true,
			AttackPercent: 143, DamageMin: 15, DamageMax: 18, AttackType: 5}, nil
	case skDaggerSpdA1:
		return &refdata.Skill{ID: id, GroupID: 628, BasicLevel: 1, ActionKind: 3, DuraMs: 15000,
			BuffParams: "hst2:48", NoCombatParam: true, ZeroDamage: true}, nil
	case skNbufSelf:
		return &refdata.Skill{ID: id, GroupID: 8001, BasicLevel: 1, ActionKind: 3, DuraMs: 60000,
			Nbuf: true, NoCombatParam: true, ZeroDamage: true}, nil
	}
	return nil, errors.New("no such skill")
}

type buffWorld struct {
	addr    string
	skills  *skill.MemStore
	aria    int64
	hub     *world.Hub
	monster int64
	conn    net.Conn
	r       *bufio.Reader
	held    []*proto.Packet
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
	// A second character on the same account, never entered: a cast that
	// names her from Aria's session is refused.
	bria, err := chars.Create(ctx, 1, "Bria")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{100: {ID: 100, PhysAttackMin: 30, PhysAttackMax: 30}}
	inv := inventory.NewMemStore(items)
	inv.AddItem(ctx, c.ID, 100, 1)
	eq := equipment.NewMemStore(inv)
	eq.Equip(ctx, c.ID, equipment.SlotWeapon, 0)
	skills := skill.NewMemStore()
	for _, id := range []int64{skGrassWalkA1, skGrassWalkA2, skGhostWalkB1, skImbueA1, skNbufSelf, skExplosionA1, skSmashA1, skDaggerSpdA1} {
		if err := skills.Learn(ctx, c.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	// Bria knows Grass Walk, so only the identity check stands between a
	// cast naming her and her costs.
	if err := skills.Learn(ctx, bria.ID, skGrassWalkA1); err != nil {
		t.Fatal(err)
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
	// The world's disconnect handler is wired, as cmd/server wires it.
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
	w := &buffWorld{addr: addr, skills: skills, aria: c.ID, hub: hub, monster: m.ID, conn: conn, r: bufio.NewReader(conn)}
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

// expect returns the next packet with op, from those an earlier expect set
// aside first and then from the wire, setting aside the others.
func (w *buffWorld) expect(t *testing.T, op uint16) *proto.Packet {
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

// expectNone reports a packet with op arriving within d.
func (w *buffWorld) expectNone(t *testing.T, op uint16, d time.Duration) {
	t.Helper()
	for _, p := range w.held {
		if p.Opcode == op {
			t.Fatalf("an unexpected 0x%04X: % x", op, p.Data)
		}
	}
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
	if first.RunSpeed != uint32(math.Round(50*1.23)) {
		t.Fatalf("first start %+v", first)
	}
	// The refresh leaves the speed where it was, so neither packet of it
	// carries one: both report the one operation's result, unchanged (0).
	second, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if second.Token == first.Token || second.RunSpeed != 0 || end.RunSpeed != 0 {
		t.Fatalf("second start %+v, end %+v; want run speed 0 (unchanged) on both", second, end)
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
	other, _, _, _ := buffBooks.Start(w.aria, buff.Spec{SkillID: 8002, GroupID: 8002, Level: 1, CasterID: w.aria + 1000,
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
	// Round 639's two experience s64s follow it (16 bytes).
	enc := (&AttackResult{MonsterID: 5, TargetType: TargetGround, HasTargetType: true}).Encode()
	if enc[len(enc)-17] != TargetGround {
		t.Fatalf("the targetType byte is %d", enc[len(enc)-17])
	}
	if old, err := DecodeAttackResult(enc[:len(enc)-17]); err != nil || old.EchoedTargetType() != TargetEntity || old.MonsterID != 5 {
		t.Fatalf("an older result decoded %+v, %v", old, err)
	}
	if plain := (&AttackResult{}).Encode(); plain[len(plain)-17] != TargetEntity {
		t.Fatalf("a swing's result's targetType byte is %d, want 1", plain[len(plain)-17])
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

// Round 616's review: a ground point with a NaN or an infinity is refused
// before anything is spent (no use recorded, no move), and a move with one
// is dropped.
func TestNonFinitePointsAreRefused(t *testing.T) {
	w := startBuffWorld(t)
	before, _ := w.hub.EntityByCharacterID(w.aria)
	nan := float32(math.NaN())
	inf := float32(math.Inf(1))
	for _, p := range [][3]float32{{nan, 0, 0}, {0, inf, 0}, {0, 0, -inf}} {
		ar := w.cast(t, &UseSkillRequest{SkillID: skGhostWalkB1, TargetType: TargetGround, HasTargetType: true, X: p[0], Y: p[1], Z: p[2]})
		if ar.Error != groundRefusal {
			t.Fatalf("Ghost Walk to %v answered %q", p, ar.Error)
		}
	}
	if _, used, _ := w.skills.LastUsed(context.Background(), w.aria, skGhostWalkB1); used {
		t.Fatal("a refused non-finite Ghost Walk recorded a use")
	}
	w.write(t, OpMove, (&MoveRequest{X: nan, Y: 0, Z: 0}).Encode())
	w.write(t, OpMove, (&MoveRequest{X: 0, Y: inf, Z: 0}).Encode())
	w.expectNone(t, OpSkillMove, 200*time.Millisecond)
	after, _ := w.hub.EntityByCharacterID(w.aria)
	if after.Pos != before.Pos {
		t.Fatalf("a non-finite point moved Aria from %+v to %+v", before.Pos, after.Pos)
	}
}

// Round 616's review: a cast naming a character other than the one this
// session has in the world is refused, and so is a cancel.
func TestCastMustNameTheSessionsCharacter(t *testing.T) {
	w := startBuffWorld(t)
	w.write(t, OpUseSkill, (&UseSkillRequest{CharacterName: "Bria", SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true}).Encode())
	ar, err := DecodeAttackResult(w.expect(t, OpAttackResult).Data)
	if err != nil || ar.Error != notInWorldRefusal {
		t.Fatalf("a cast naming Bria answered %+v, %v", ar, err)
	}
	w.expectNone(t, OpBuffStart, 200*time.Millisecond)
}

// Round 616's review: a stale session's disconnect leaves the live session's
// book alone.
func TestStaleSessionDisconnectKeepsTheLiveBook(t *testing.T) {
	w := startBuffWorld(t)
	// A second connection enters as Aria too; the first is now the stale one.
	conn2 := dialTestServer(t, w.addr)
	t.Cleanup(func() { conn2.Close() })
	w2 := &buffWorld{addr: w.addr, hub: w.hub, aria: w.aria, conn: conn2, r: bufio.NewReader(conn2)}
	w2.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	w2.expect(t, OpLoginResult)
	w2.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	w2.expect(t, OpEnterWorldResult)
	w2.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	w2.expect(t, OpBuffStart)
	w.conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		n := 0
		for _, e := range w.hub.AllEntities() {
			if e.CharacterID == w.aria {
				n++
			}
		}
		if n == 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if n := len(buffBooks.Active(w.aria)); n != 1 {
		t.Fatalf("the stale session's disconnect left %d records, want the live one's 1", n)
	}
	// The live session's own disconnect does clear it.
	conn2.Close()
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && len(buffBooks.Active(w.aria)) != 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if n := len(buffBooks.Active(w.aria)); n != 0 {
		t.Fatalf("the live session's disconnect left %d records", n)
	}
}

// Round 616's review: after a zone change the owner's own speed-writing
// record comes back with its real run speed, not 0.
func TestZoneChangeResendsTheOwnSpeed(t *testing.T) {
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	first, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	w.write(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if r, err := DecodeChangeZoneResult(w.expect(t, OpChangeZoneResult).Data); err != nil || !r.OK {
		t.Fatalf("zone change: %+v, %v", r, err)
	}
	again, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if again.Token != first.Token || again.RunSpeed != 60 {
		t.Fatalf("after the zone change: %+v, want token %d at run speed 60", again, first.Token)
	}
}

// Round 616's review: 'hst2' through the handler -- the EU dagger speed over
// Grass Walk runs at 74, and at its end Grass Walk's 60 comes back.
func TestDaggerSpeedOverGrassWalk(t *testing.T) {
	w := startBuffWorld(t)
	w.cast(t, &UseSkillRequest{SkillID: skGrassWalkA1, TargetType: TargetNone, HasTargetType: true})
	w.expect(t, OpBuffStart)
	w.cast(t, &UseSkillRequest{SkillID: skDaggerSpdA1, TargetType: TargetNone, HasTargetType: true})
	d, _ := DecodeBuffStart(w.expect(t, OpBuffStart).Data)
	if d.RunSpeed != 74 {
		t.Fatalf("the dagger speed's start carries %d, want 74", d.RunSpeed)
	}
	var rec buff.Record
	for _, r := range buffBooks.Active(w.aria) {
		if r.Token == d.Token {
			rec = r
		}
	}
	expireBuffs(w.hub, rec.EndsAt().Add(time.Millisecond))
	end, _ := DecodeBuffEnd(w.expect(t, OpBuffEnd).Data)
	if len(end.Tokens) != 1 || end.Tokens[0] != d.Token || end.RunSpeed != 60 {
		t.Fatalf("the dagger speed's end %+v, want run speed 60", end)
	}
}

// Round 616's review: what a cast took is handed back when its buff or move
// cannot be done after the costs.
func TestRefundSkillCosts(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	mp := mana.NewTracker()
	maxMP := c.MaxMP()
	mp.Spend(c.ID, maxMP, 50)
	chars.ApplyDamage(ctx, c.ID, 30)
	refundSkillCosts(ctx, chars, mp, c.ID, 30, 50)
	if got := mp.Current(c.ID, maxMP); got != maxMP {
		t.Fatalf("MP %d after the refund, want %d", got, maxMP)
	}
	if got, _ := chars.GetByID(ctx, c.ID); got.HP != got.MaxHP() {
		t.Fatalf("HP %d after the refund, want %d", got.HP, got.MaxHP())
	}
}

// Round 616-618 integration: the stale session's disconnect also leaves the
// live session's auto-attack run and motion state alone -- both are keyed by
// character id, as the book is -- and the live session's own disconnect
// still clears them.
func TestStaleSessionDisconnectKeepsTheLiveKeepUpAndMotion(t *testing.T) {
	w := startBuffWorld(t)
	conn2 := dialTestServer(t, w.addr)
	t.Cleanup(func() { conn2.Close() })
	w2 := &buffWorld{addr: w.addr, hub: w.hub, aria: w.aria, conn: conn2, r: bufio.NewReader(conn2)}
	w2.write(t, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	w2.expect(t, OpLoginResult)
	w2.write(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	w2.expect(t, OpEnterWorldResult)

	// The live session is auto-attacking monster 777 and sitting down.
	keepUp.Arm(w.aria, 777, time.Hour, func() (time.Duration, bool) { return time.Hour, true })
	t.Cleanup(func() { keepUp.Cancel(w.aria) })
	if _, ok := motions.request(w.aria, MotionSit, time.Now()); !ok {
		t.Fatalf("the sit request was refused")
	}

	w.conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		n := 0
		for _, e := range w.hub.AllEntities() {
			if e.CharacterID == w.aria {
				n++
			}
		}
		if n == 1 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(50 * time.Millisecond)
	if target, ok := keepUp.Target(w.aria); !ok || target != 777 {
		t.Fatalf("the stale session's disconnect cancelled the live auto-attack: target %d, %v", target, ok)
	}
	if st := motions.state(w.aria, time.Now()); st == MotionStand {
		t.Fatalf("the stale session's disconnect cleared the live motion: state %d, want sitting or getting down", st)
	}

	conn2.Close()
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := keepUp.Target(w.aria); !ok {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := keepUp.Target(w.aria); ok {
		t.Fatalf("the live session's disconnect left the auto-attack running")
	}
	if st := motions.state(w.aria, time.Now()); st != MotionStand {
		t.Fatalf("the live session's disconnect left motion state %d", st)
	}
}
