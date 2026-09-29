package session

// Round 646: every player's active buffs -- a timed buff (Grass Walk) and a
// toggle's wall (Fire Wall - Tower, untimed) -- reach every other player in
// the zone on each event that shows them a body: an entry where the owner
// already stands, the owner's zone change into the watcher's zone, a warp
// inside the one world bucket (-single-frame), and not again after the
// owner's relog (the book ends with the logout, round 616). And a walled
// caster's warp landing is taken, so the zone sees the caster -- and its wall
// -- where its own client stands it (OURS, walls.go warpLandingAdmits).
//
// The retail analogue (READ, docs/protocol/skill_buffs.md "Entering view"):
// the spawn record of a character (0x3015 / the group spawn) carries its
// active buffs -- u8 count, then {u32 skill id, u32 token} -- which the client
// attaches through the same deco factory as 0xB0BD, the start effect skipped.
// srrevamp's OpEntityEntered carries no buffs, so the OpBuffStarts must
// follow it, never precede it: a start for an owner with no body yet has
// nothing to draw on.

import (
	"bufio"
	"context"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
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

// replayRef serves walls640CSV's rows (MP zeroed, SYNTHETIC, as there) and
// buffSkillRef's for the rest.
type replayRef map[int64]*refdata.Skill

func (r replayRef) GetSkill(ctx context.Context, id int64) (*refdata.Skill, error) {
	if s, ok := r[id]; ok {
		cp := *s
		return &cp, nil
	}
	return buffSkillRef{}.GetSkill(ctx, id)
}

type replayWorld struct {
	addr  string
	hub   *world.Hub
	chars *character.MemStore
	aria  *friendClient
	bram  *friendClient
}

// startReplayWorld serves two accounts: Aria (Grass Walk, Fire Wall) and Bram
// (Grass Walk). Neither is entered yet.
func startReplayWorld(t *testing.T) *replayWorld {
	t.Helper()
	ctx := context.Background()
	rows, err := refdata.LoadSkillsCSV(strings.NewReader(walls640CSV))
	if err != nil {
		t.Fatal(err)
	}
	ref := replayRef{}
	for i := range rows {
		rows[i].ConsumeMP, rows[i].ConsumeHP = 0, 0
		ref[rows[i].ID] = &rows[i]
	}
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatal(err)
	}
	bram, err := chars.Create(ctx, 2, "Bram")
	if err != nil {
		t.Fatal(err)
	}
	items := stubCombatItems{}
	inv := inventory.NewMemStore(items)
	eq := equipment.NewMemStore(inv)
	skills := skill.NewMemStore()
	for _, id := range []int64{skGrassWalkA1, 136} {
		if err := skills.Learn(ctx, aria.ID, id); err != nil {
			t.Fatal(err)
		}
	}
	if err := skills.Learn(ctx, bram.ID, skGrassWalkA1); err != nil {
		t.Fatal(err)
	}
	hub := world.NewHub()
	handle := gateway.Chain(
		LoginHandler(accounts),
		WorldHandler(chars, eq, hub),
		UseSkillHandler(chars, eq, items, skills, hub, combat.NewHub(), quest.NewMemStore(), inv, ref, nil, mana.NewTracker(), nil),
		BuffHandler(chars, hub),
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
	t.Cleanup(func() {
		for _, id := range []int64{aria.ID, bram.ID} {
			buffBooks.EndAll(id)
			motions.clear(id)
			clearWarpLanding(id)
		}
	})
	w := &replayWorld{addr: addr, hub: hub, chars: chars,
		aria: &friendClient{id: aria.ID}, bram: &friendClient{id: bram.ID}}
	return w
}

// enter logs c in and enters the world as name; the result is returned and
// the packets that followed it stay unread.
func (w *replayWorld) enter(t *testing.T, c *friendClient, user, pass, name string) *EnterWorldResult {
	t.Helper()
	conn := dialTestServer(t, w.addr)
	t.Cleanup(func() { conn.Close() })
	c.conn, c.r, c.held = conn, bufio.NewReader(conn), nil
	c.send(t, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode())
	if lr, err := DecodeLoginResult(c.expect(t, OpLoginResult).Data); err != nil || !lr.OK {
		t.Fatalf("login %s: %v %+v", user, err, lr)
	}
	c.send(t, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
	ewr, err := DecodeEnterWorldResult(c.expect(t, OpEnterWorldResult).Data)
	if err != nil || !ewr.OK {
		t.Fatalf("enter world %s: %v %+v", name, err, ewr)
	}
	return ewr
}

// castSelf casts id with nothing named from c (as name) and returns its
// OpBuffStart as c heard it.
func castSelf(t *testing.T, c *friendClient, name string, id int64) *BuffStart {
	t.Helper()
	c.send(t, OpUseSkill, (&UseSkillRequest{CharacterName: name, SkillID: id, TargetType: TargetNone, HasTargetType: true}).Encode())
	bs, err := DecodeBuffStart(c.expect(t, OpBuffStart).Data)
	if err != nil {
		t.Fatal(err)
	}
	if ar, err := DecodeAttackResult(c.expect(t, OpAttackResult).Data); err != nil || ar.Error != "" {
		t.Fatalf("cast %d: %v %+v", id, err, ar)
	}
	return bs
}

// drain reads everything c is sent within d, after what expect set aside, in
// arrival order.
func drain(t *testing.T, c *friendClient, d time.Duration) []*proto.Packet {
	t.Helper()
	out := append([]*proto.Packet(nil), c.held...)
	c.held = nil
	deadline := time.Now().Add(d)
	for {
		c.conn.SetReadDeadline(deadline)
		p, err := proto.Read(c.r, nil, nil)
		if err != nil {
			return out
		}
		out = append(out, p)
	}
}

// startsFor are the OpBuffStart tokens in ps that name owner, in order.
func startsFor(t *testing.T, ps []*proto.Packet, owner int64) []uint32 {
	t.Helper()
	var out []uint32
	for _, p := range ps {
		if p.Opcode != OpBuffStart {
			continue
		}
		bs, err := DecodeBuffStart(p.Data)
		if err != nil {
			t.Fatal(err)
		}
		if bs.OwnerID == owner {
			out = append(out, bs.Token)
		}
	}
	return out
}

// indexOf is the position of the first packet with op in ps, -1 if none.
func indexOf(ps []*proto.Packet, op uint16) int {
	for i, p := range ps {
		if p.Opcode == op {
			return i
		}
	}
	return -1
}

func sameTokens(got []uint32, want ...uint32) bool {
	if len(got) != len(want) {
		return false
	}
	seen := map[uint32]int{}
	for _, t := range got {
		seen[t]++
	}
	for _, t := range want {
		if seen[t] == 0 {
			return false
		}
		seen[t]--
	}
	return true
}

// B enters where a buffed A stands: B is sent A's two buffs -- after its
// OpEnterWorldResult (whose Others carry A's body) -- the timed one with what
// is left of it and the wall untimed; A is sent nothing for B, who has none.
func TestRound646AnArrivalIsSentTheBuffsOfThoseAlreadyThere(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	gw := castSelf(t, w.aria, "Aria", skGrassWalkA1)
	wall := castSelf(t, w.aria, "Aria", 136)
	time.Sleep(50 * time.Millisecond)

	ewr := w.enter(t, w.bram, "bob", "hunter3", "Bram")
	if len(ewr.Others) != 1 || ewr.Others[0].CharacterID != w.aria.id {
		t.Fatalf("Bram's entry lists %+v, want Aria's body", ewr.Others)
	}
	got := drain(t, w.bram, 300*time.Millisecond)
	if tok := startsFor(t, got, w.aria.id); !sameTokens(tok, gw.Token, wall.Token) {
		t.Fatalf("Bram was sent Aria's tokens %v, want %d (Grass Walk) and %d (the wall)", tok, gw.Token, wall.Token)
	}
	for _, p := range got {
		if p.Opcode != OpBuffStart {
			continue
		}
		bs, _ := DecodeBuffStart(p.Data)
		switch bs.Token {
		case gw.Token:
			if bs.DurationMs != 355462 || bs.RemainingMs <= 0 || bs.RemainingMs > bs.DurationMs || bs.SkillID != skGrassWalkA1 {
				t.Errorf("Grass Walk replayed as %+v, want skill %d, duration 355462 and what is left of it", bs, skGrassWalkA1)
			}
		case wall.Token:
			if bs.DurationMs != -1 || bs.RemainingMs != -1 || bs.SkillID != 136 {
				t.Errorf("the wall replayed as %+v, want skill 136, untimed", bs)
			}
		}
	}
	// A hears B arrive and no buff of B's.
	aGot := drain(t, w.aria, 300*time.Millisecond)
	if indexOf(aGot, OpEntityEntered) < 0 {
		t.Fatal("Aria was not told Bram entered")
	}
	if tok := startsFor(t, aGot, w.bram.id); len(tok) != 0 {
		t.Fatalf("Aria was sent buffs %v for Bram, who has none", tok)
	}
}

// A, buffed, changes zone into B's (separate buckets, -single-frame off):
// B hears A's OpEntityEntered and then A's buffs, in that order; A hears its
// OpChangeZoneResult, then its own buffs and B's. The zone A left hears it
// leave and no buff.
func TestRound646AZoneChangeCarriesTheMoversBuffsToItsNewZone(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.bram, "bob", "hunter3", "Bram")
	w.bram.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if r, err := DecodeChangeZoneResult(w.bram.expect(t, OpChangeZoneResult).Data); err != nil || !r.OK {
		t.Fatalf("Bram to donwhang: %+v %v", r, err)
	}
	bgw := castSelf(t, w.bram, "Bram", skGrassWalkA1)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	gw := castSelf(t, w.aria, "Aria", skGrassWalkA1)
	wall := castSelf(t, w.aria, "Aria", 136)
	drain(t, w.bram, 200*time.Millisecond)
	drain(t, w.aria, 100*time.Millisecond)

	w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	aGot := drain(t, w.aria, 400*time.Millisecond)
	bGot := drain(t, w.bram, 400*time.Millisecond)

	entered := indexOf(bGot, OpEntityEntered)
	if entered < 0 {
		t.Fatal("Bram was not told Aria entered his zone")
	}
	if tok := startsFor(t, bGot, w.aria.id); !sameTokens(tok, gw.Token, wall.Token) {
		t.Fatalf("Bram was sent Aria's tokens %v, want %d and %d", tok, gw.Token, wall.Token)
	}
	if first := indexOf(bGot, OpBuffStart); first < entered {
		t.Fatalf("Bram heard Aria's buff (packet %d) before her body entered (packet %d): a start with no body draws nothing", first, entered)
	}
	res := indexOf(aGot, OpChangeZoneResult)
	if res < 0 {
		t.Fatal("Aria had no OpChangeZoneResult")
	}
	if first := indexOf(aGot, OpBuffStart); first < res {
		t.Fatalf("Aria heard a buff (packet %d) before her zone change's result (packet %d)", first, res)
	}
	if tok := startsFor(t, aGot, w.aria.id); !sameTokens(tok, gw.Token, wall.Token) {
		t.Errorf("Aria was re-sent her own tokens %v, want %d and %d", tok, gw.Token, wall.Token)
	}
	if tok := startsFor(t, aGot, w.bram.id); !sameTokens(tok, bgw.Token) {
		t.Errorf("Aria was sent Bram's tokens %v, want %d", tok, bgw.Token)
	}
}

// Under -single-frame every town is one bucket, so a /goto or a gate between
// two towns re-enters the same bucket: B hears A leave, enter, and then A's
// buffs, in that order (round 571's flicker, which drops the aura with the
// body; the starts put it back on the new one).
func TestRound646AWarpInsideTheOneBucketResendsTheBuffsAfterTheReentry(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	w := startReplayWorld(t)
	w.enter(t, w.bram, "bob", "hunter3", "Bram")
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	gw := castSelf(t, w.aria, "Aria", skGrassWalkA1)
	drain(t, w.bram, 200*time.Millisecond)

	w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	bGot := drain(t, w.bram, 400*time.Millisecond)
	left, entered, started := indexOf(bGot, OpEntityLeft), indexOf(bGot, OpEntityEntered), indexOf(bGot, OpBuffStart)
	if left < 0 || entered < 0 || started < 0 || !(left < entered && entered < started) {
		t.Fatalf("Bram heard left %d, entered %d, buff %d (packet indices), want all three in that order", left, entered, started)
	}
	if tok := startsFor(t, bGot, w.aria.id); !sameTokens(tok, gw.Token) {
		t.Fatalf("Bram was sent Aria's tokens %v, want %d", tok, gw.Token)
	}
}

// A relogs: its book ends with the logout (round 616; retail's login restore
// of some records is OPEN), so B hears it leave and, on its return, its body
// and no buff.
func TestRound646ARelogEndsTheBuffsForEveryone(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.bram, "bob", "hunter3", "Bram")
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	castSelf(t, w.aria, "Aria", skGrassWalkA1)
	drain(t, w.bram, 200*time.Millisecond)
	w.aria.conn.Close()
	bGot := drain(t, w.bram, 400*time.Millisecond)
	if indexOf(bGot, OpEntityLeft) < 0 {
		t.Fatal("Bram did not hear Aria leave")
	}
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	bGot = drain(t, w.bram, 400*time.Millisecond)
	if indexOf(bGot, OpEntityEntered) < 0 {
		t.Fatal("Bram did not hear Aria return")
	}
	if tok := startsFor(t, bGot, w.aria.id); len(tok) != 0 {
		t.Fatalf("Bram was sent tokens %v for a relogged Aria, whose book ended", tok)
	}
}

// A walled caster warps (the root is OURS, round 640): its client's landing,
// a relocated OpMove at the point the server sent it to (Donwhang's arrival,
// (0, 0, 0) in its own frame; the review of round 646 moved this test's
// landing there from an arbitrary (120, -40), which the one-shot landing now
// refuses), is taken -- the hub holds it and the zone hears it --
// while a walk after it is still dropped and answered with the held spot.
// Before round 646 the landing was dropped too, and the zone saw the caster
// and its wall at the server's arrival point while its own client stood it
// elsewhere (MEASURED live, round 646).
func TestRound646AWalledCastersWarpLandingIsTaken(t *testing.T) {
	w := startReplayWorld(t)
	w.enter(t, w.bram, "bob", "hunter3", "Bram")
	w.bram.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	w.bram.expect(t, OpChangeZoneResult)
	w.enter(t, w.aria, "alice", "hunter2", "Aria")
	castSelf(t, w.aria, "Aria", 136)
	w.aria.send(t, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	w.aria.expect(t, OpChangeZoneResult)
	drain(t, w.aria, 200*time.Millisecond)
	drain(t, w.bram, 200*time.Millisecond)

	w.aria.send(t, OpMove, (&MoveRequest{X: 0.5, Y: 3, Z: -0.5, Relocated: true}).Encode())
	time.Sleep(150 * time.Millisecond)
	e, ok := w.hub.EntityByCharacterID(w.aria.id)
	if !ok {
		t.Fatal("Aria is not in the world")
	}
	if e.Pos.X != 0.5 || e.Pos.Z != -0.5 {
		t.Errorf("the walled Aria's warp landing left her at %+v, want (0.5, 3, -0.5), the arrival point where her client stands her: the zone sees her wall where she is not", e.Pos)
	}
	bGot := drain(t, w.bram, 200*time.Millisecond)
	moved := indexOf(bGot, OpEntityMoved)
	if moved < 0 {
		t.Errorf("Bram did not hear Aria's landing")
	} else if em, err := DecodeEntityMoved(bGot[moved].Data); err != nil || em.X != 0.5 || !em.Relocated {
		t.Errorf("Bram heard %+v, %v, want Aria relocated to x 0.5", em, err)
	}

	// A walk is still dropped by the root.
	w.aria.send(t, OpMove, (&MoveRequest{X: 30, Y: 3, Z: -0.5}).Encode())
	sm, err := DecodeSkillMove(w.aria.expect(t, OpSkillMove).Data)
	if err != nil || sm.SkillID != 136 || sm.X != 0.5 {
		t.Errorf("the walk's answer %+v, %v, want the wall's hold at x 0.5", sm, err)
	}
	if e, _ := w.hub.EntityByCharacterID(w.aria.id); e.Pos.X != 0.5 {
		t.Errorf("after a walk with the wall up Aria stands at %+v, want the landing x 0.5", e.Pos)
	}
}
