package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/duel"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestDuelChallengeRequestRoundTrip(t *testing.T) {
	want := &DuelChallengeRequest{CharacterName: "Aria", TargetName: "Bram"}
	got, err := DecodeDuelChallengeRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeDuelChallengeRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDuelRespondRequestRoundTrip(t *testing.T) {
	want := &DuelRespondRequest{CharacterName: "Bram", ChallengerName: "Aria", Accept: true}
	got, err := DecodeDuelRespondRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeDuelRespondRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDuelAttackResultRoundTrip(t *testing.T) {
	want := &DuelAttackResult{Damage: 30, OpponentHP: 70, OpponentDied: false}
	got, err := DecodeDuelAttackResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeDuelAttackResult: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestDuelEndedRoundTrip(t *testing.T) {
	want := &DuelEnded{WinnerName: "Aria"}
	got, err := DecodeDuelEnded(want.Encode())
	if err != nil {
		t.Fatalf("DecodeDuelEnded: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestDuelDeclineFlow has Alice challenge Bob and Bob decline, confirming
// Alice gets an OpDuelDeclined and neither ends up in an active duel.
func TestDuelDeclineFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)

	hub := world.NewHub()
	duels := duel.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub), DuelHandler(chars, eq, items, hub, duels))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, ewr)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, ewr)
	}
	// Aria was already in the zone; drain her EntityEntered broadcast for Bram.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	resp = doSend(connA, rA, OpDuelChallenge, (&DuelChallengeRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if cr, err := DecodeDuelChallengeResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("challenge failed: err=%v result=%+v", err, cr)
	}

	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	invitePkt, err := proto.Read(rB, nil, nil)
	if err != nil {
		t.Fatalf("reading OpDuelInvite: %v", err)
	}
	if invitePkt.Opcode != OpDuelInvite {
		t.Fatalf("got opcode 0x%04x, want OpDuelInvite", invitePkt.Opcode)
	}
	invite, err := DecodeDuelInvite(invitePkt.Data)
	if err != nil || invite.ChallengerName != "Aria" {
		t.Fatalf("unexpected invite: %+v (err=%v)", invite, err)
	}

	resp = doSend(connB, rB, OpDuelRespond, (&DuelRespondRequest{CharacterName: "Bram", ChallengerName: "Aria", Accept: false}).Encode())
	if rr, err := DecodeDuelRespondResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("respond failed: err=%v result=%+v", err, rr)
	}

	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	declinedPkt, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading OpDuelDeclined: %v", err)
	}
	if declinedPkt.Opcode != OpDuelDeclined {
		t.Fatalf("got opcode 0x%04x, want OpDuelDeclined", declinedPkt.Opcode)
	}

	// Neither should be able to attack -- no active duel.
	resp = doSend(connA, rA, OpDuelAttack, (&DuelAttackRequest{CharacterName: "Aria"}).Encode())
	if ar, err := DecodeDuelAttackResult(resp.Data); err != nil || ar.Error != "not in a duel" {
		t.Fatalf("attack after decline: err=%v result=%+v", err, ar)
	}
}

// TestDuelFullFightFlow has Alice challenge Bob, Bob accept, then Alice
// attacks Bob down to 0 HP over several hits, confirming Bob receives
// OpDuelOpponentDamaged for non-lethal hits and both sides receive
// OpDuelEnded with the correct winner on the killing blow.
func TestDuelFullFightFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating Aria: %v", err)
	}
	if _, err := chars.Create(ctx, 2, "Bram"); err != nil {
		t.Fatalf("creating Bram: %v", err)
	}

	items := stubCombatItems{100: {ID: 100, PhysAttackMax: 30}}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)
	inv.AddItem(ctx, aria.ID, 100, 1)

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)
	eq.Equip(ctx, aria.ID, equipment.SlotWeapon, 0)

	hub := world.NewHub()
	duels := duel.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub), DuelHandler(chars, eq, items, hub, duels))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, ewr)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, ewr)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	resp = doSend(connA, rA, OpDuelChallenge, (&DuelChallengeRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if cr, err := DecodeDuelChallengeResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("challenge failed: err=%v result=%+v", err, cr)
	}
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rB, nil, nil); err != nil {
		t.Fatalf("reading OpDuelInvite: %v", err)
	}

	resp = doSend(connB, rB, OpDuelRespond, (&DuelRespondRequest{CharacterName: "Bram", ChallengerName: "Aria", Accept: true}).Encode())
	if rr, err := DecodeDuelRespondResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("respond failed: err=%v result=%+v", err, rr)
	}
	// Both sides get OpDuelStarted.
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(rB, nil, nil); err != nil || startedPkt.Opcode != OpDuelStarted {
		t.Fatalf("reading Bram's OpDuelStarted: opcode=%v err=%v", startedPkt, err)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if startedPkt, err := proto.Read(rA, nil, nil); err != nil || startedPkt.Opcode != OpDuelStarted {
		t.Fatalf("reading Aria's OpDuelStarted: opcode=%v err=%v", startedPkt, err)
	}

	// 30 damage a hit against the character's real starting health. Derived
	// rather than written out, so it follows the recovered Str-based maximum
	// instead of pinning a number that moves the moment the formula does.
	const perHit = 30
	var wantHPs []int32
	for hp := int32(character.StartingMaxHP); hp > 0; {
		hp -= perHit
		if hp < 0 {
			hp = 0
		}
		wantHPs = append(wantHPs, hp)
	}
	for i, wantHP := range wantHPs {
		resp = doSend(connA, rA, OpDuelAttack, (&DuelAttackRequest{CharacterName: "Aria"}).Encode())
		ar, err := DecodeDuelAttackResult(resp.Data)
		if err != nil || ar.Error != "" || ar.Damage != 30 || ar.OpponentHP != wantHP {
			t.Fatalf("hit %d: err=%v result=%+v, want damage=30 hp=%d", i+1, err, ar, wantHP)
		}

		if i < len(wantHPs)-1 {
			if ar.OpponentDied {
				t.Fatalf("hit %d: unexpected death", i+1)
			}
			connB.SetReadDeadline(time.Now().Add(2 * time.Second))
			damagedPkt, err := proto.Read(rB, nil, nil)
			if err != nil {
				t.Fatalf("hit %d: reading OpDuelOpponentDamaged: %v", i+1, err)
			}
			if damagedPkt.Opcode != OpDuelOpponentDamaged {
				t.Fatalf("hit %d: got opcode 0x%04x, want OpDuelOpponentDamaged", i+1, damagedPkt.Opcode)
			}
			continue
		}

		if !ar.OpponentDied {
			t.Fatalf("hit %d: expected death at 0 HP", i+1)
		}
		connA.SetReadDeadline(time.Now().Add(2 * time.Second))
		endedA, err := proto.Read(rA, nil, nil)
		if err != nil || endedA.Opcode != OpDuelEnded {
			t.Fatalf("reading Aria's OpDuelEnded: opcode=%v err=%v", endedA, err)
		}
		de, err := DecodeDuelEnded(endedA.Data)
		if err != nil || de.WinnerName != "Aria" {
			t.Fatalf("unexpected DuelEnded on Aria's side: %+v (err=%v)", de, err)
		}

		connB.SetReadDeadline(time.Now().Add(2 * time.Second))
		endedB, err := proto.Read(rB, nil, nil)
		if err != nil || endedB.Opcode != OpDuelEnded {
			t.Fatalf("reading Bram's OpDuelEnded: opcode=%v err=%v", endedB, err)
		}
	}

	// Neither should still be dueling.
	if _, ok := duels.OpponentOf(1); ok {
		t.Fatal("expected Aria's duel to have ended")
	}
	if _, ok := duels.OpponentOf(2); ok {
		t.Fatal("expected Bram's duel to have ended")
	}
}

// TestDuelArmorMitigation confirms PvP damage is reduced by the defender's
// real equipped armor, the same as PvE (see TestCombatArmorMitigation).
func TestDuelArmorMitigation(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("creating Aria: %v", err)
	}
	bram, err := chars.Create(ctx, 2, "Bram")
	if err != nil {
		t.Fatalf("creating Bram: %v", err)
	}

	items := stubCombatItems{
		100: {ID: 100, PhysAttackMax: 30},
		200: {ID: 200, PhysDefenseMax: 12},
	}
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), items)
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	inv.TruncateForTest(ctx)
	inv.AddItem(ctx, aria.ID, 100, 1)
	inv.AddItem(ctx, bram.ID, 200, 1) // Bram's mail, not Aria's

	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	eq.TruncateForTest(ctx)
	eq.Equip(ctx, aria.ID, equipment.SlotWeapon, 0)
	eq.Equip(ctx, bram.ID, equipment.SlotMail, 0)

	hub := world.NewHub()
	duels := duel.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub), DuelHandler(chars, eq, items, hub, duels))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	resp := doSend(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = doSend(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, ewr)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, ewr)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	resp = doSend(connA, rA, OpDuelChallenge, (&DuelChallengeRequest{CharacterName: "Aria", TargetName: "Bram"}).Encode())
	if cr, err := DecodeDuelChallengeResult(resp.Data); err != nil || !cr.OK {
		t.Fatalf("challenge failed: err=%v result=%+v", err, cr)
	}
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rB, nil, nil); err != nil {
		t.Fatalf("reading OpDuelInvite: %v", err)
	}

	resp = doSend(connB, rB, OpDuelRespond, (&DuelRespondRequest{CharacterName: "Bram", ChallengerName: "Aria", Accept: true}).Encode())
	if rr, err := DecodeDuelRespondResult(resp.Data); err != nil || !rr.OK {
		t.Fatalf("respond failed: err=%v result=%+v", err, rr)
	}
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rB, nil, nil); err != nil {
		t.Fatalf("reading Bram's OpDuelStarted: %v", err)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil {
		t.Fatalf("reading Aria's OpDuelStarted: %v", err)
	}

	// 30 attack - 12 armor (Bram's real equipped mail) = 18 net, not 30.
	resp = doSend(connA, rA, OpDuelAttack, (&DuelAttackRequest{CharacterName: "Aria"}).Encode())
	ar, err := DecodeDuelAttackResult(resp.Data)
	if err != nil || ar.Error != "" || ar.Damage != 18 || ar.OpponentHP != int32(character.StartingMaxHP)-18 {
		t.Fatalf("armored hit: err=%v result=%+v, want damage=18 hp=%d", err, ar, character.StartingMaxHP-18)
	}
}
