package session

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"log/slog"
	"math"
	"net"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/equipment"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/guild"
	"github.com/OpenSRO/srrevamp/server/internal/inventory"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
	"github.com/OpenSRO/srrevamp/server/internal/worldmap"
)

// worldTestMaxStacks is a fixed-answer inventory.MaxStackLookup for
// TestWorldFullFlow, so it doesn't need a real refdata item catalog just to
// seed one armor item into an inventory.
type worldTestMaxStacks map[int64]int

func (s worldTestMaxStacks) GetMaxStack(_ context.Context, itemID int64) (int, error) {
	return s[itemID], nil
}

// worn builds the Equipped list a snapshot carries, in slot order.
func worn(pairs ...int64) []EquippedSnapshot {
	var out []EquippedSnapshot
	for i := 0; i+1 < len(pairs); i += 2 {
		out = append(out, EquippedSnapshot{Slot: int(pairs[i]), ItemID: pairs[i+1]})
	}
	return out
}

func sameSnapshot(a, b EntitySnapshot) bool {
	if a.CharacterID != b.CharacterID || a.Name != b.Name || a.X != b.X || a.Y != b.Y || a.Z != b.Z || a.Gender != b.Gender {
		return false
	}
	if len(a.Equipped) != len(b.Equipped) {
		return false
	}
	for i := range a.Equipped {
		if a.Equipped[i] != b.Equipped[i] {
			return false
		}
	}
	return true
}

func TestEntitySnapshotRoundTrip(t *testing.T) {
	want := &EntitySnapshot{CharacterID: 42, Name: "Aria", X: 1.5, Y: -2.5, Z: 3,
		Equipped: worn(int64(equipment.SlotHelm), 4734, int64(equipment.SlotBoots), 4950, int64(equipment.SlotWeapon), 3632, int64(equipment.SlotShield), 3639),
		Gender:   character.GenderChinaWoman}
	got, rest, err := decodeEntitySnapshot(want.Encode())
	if err != nil {
		t.Fatalf("decodeEntitySnapshot: %v", err)
	}
	if len(rest) != 0 {
		t.Fatalf("expected no trailing bytes, got %d", len(rest))
	}
	if !sameSnapshot(*got, *want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if got.EquippedIn(equipment.SlotHelm) != 4734 || got.EquippedIn(equipment.SlotMail) != 0 {
		t.Fatalf("EquippedIn: helm %d, mail %d", got.EquippedIn(equipment.SlotHelm), got.EquippedIn(equipment.SlotMail))
	}

	// Nothing worn is one zero byte, and comes back as nothing worn.
	bare := &EntitySnapshot{CharacterID: 1, Name: "Bram", Gender: character.GenderChinaMan}
	got, _, err = decodeEntitySnapshot(bare.Encode())
	if err != nil || len(got.Equipped) != 0 {
		t.Fatalf("bare snapshot: %+v (err=%v)", got, err)
	}
}

func TestEnterWorldResultRoundTripSuccess(t *testing.T) {
	want := &EnterWorldResult{
		OK: true, Zone: "jangan", X: 1, Y: 2, Z: 3, Gender: character.GenderChinaMan,
		HP: 73, MaxHP: character.StartingMaxHP,
		Others:      []EntitySnapshot{{CharacterID: 1, Name: "Bram", X: 4, Y: 5, Z: 6, Equipped: worn(int64(equipment.SlotMail), 4842, int64(equipment.SlotShield), 3639), Gender: character.GenderChinaWoman}},
		FrameRegion: "97/168",
	}
	got, err := DecodeEnterWorldResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEnterWorldResult: %v", err)
	}
	if got.OK != want.OK || got.Zone != want.Zone || got.X != want.X || got.Gender != want.Gender || len(got.Others) != 1 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if !sameSnapshot(got.Others[0], want.Others[0]) {
		t.Fatalf("got other %+v, want %+v", got.Others[0], want.Others[0])
	}
	// Vitals ride between Gender and the entity list, so a mistake here
	// would also desync everything after it -- which is why the entity
	// check above is part of this test rather than a separate one.
	if got.HP != want.HP || got.MaxHP != want.MaxHP {
		t.Fatalf("got HP %d/%d, want %d/%d", got.HP, got.MaxHP, want.HP, want.MaxHP)
	}
	// The frame trails the entity list (round 570), so it round-trips only
	// if every field before it was read to the byte.
	if got.FrameRegion != want.FrameRegion {
		t.Fatalf("got FrameRegion %q, want %q", got.FrameRegion, want.FrameRegion)
	}
}

// The enter hook sees the character before its snapshot is built, so what
// it changes -- a character dressed on the way in -- is what the world
// then sees. A hook error is logged, never sent: the character still
// enters.
func TestWorldHandlerRunsTheEnterHookFirst(t *testing.T) {
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	ctx := context.Background()
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	acct, err := accounts.Authenticate(ctx, "alice", "pw")
	if err != nil {
		t.Fatalf("Authenticate: %v", err)
	}
	c, err := chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}

	var seen []string
	hook := func(ctx context.Context, got *character.Character) error {
		seen = append(seen, got.Name)
		if got.ID != c.ID {
			t.Errorf("hook saw character %d, want %d", got.ID, c.ID)
		}
		return errors.New("a courtesy that failed")
	}
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(chars, eq, hub, hook))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(srvCtx)

	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	sendRecv := func(opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	resp := sendRecv(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("login failed: err=%v result=%+v", err, lr)
	}
	resp = sendRecv(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	ewr, err := DecodeEnterWorldResult(resp.Data)
	if err != nil || !ewr.OK {
		t.Fatalf("enter world failed despite the hook's error: err=%v result=%+v", err, ewr)
	}
	if len(seen) != 1 || seen[0] != "Aria" {
		t.Fatalf("hook ran for %v, want once for Aria", seen)
	}
}

func TestEnterWorldResultRoundTripFailure(t *testing.T) {
	want := &EnterWorldResult{OK: false, Reason: "no such character"}
	got, err := DecodeEnterWorldResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeEnterWorldResult: %v", err)
	}
	if got.OK || got.Reason != want.Reason {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestMoveRequestRoundTrip(t *testing.T) {
	want := &MoveRequest{X: 1.5, Y: -2.5, Z: 100}
	got, err := DecodeMoveRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeMoveRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestChangeZoneRequestRoundTrip(t *testing.T) {
	want := &ChangeZoneRequest{Zone: "100/100"}
	got, err := DecodeChangeZoneRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChangeZoneRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestChangeZoneResultRoundTripSuccess(t *testing.T) {
	want := &ChangeZoneResult{
		OK: true, Zone: "100/100", X: 1, Y: 2, Z: 3,
		Others:      []EntitySnapshot{{CharacterID: 1, Name: "Bram", X: 4, Y: 5, Z: 6, Gender: character.GenderChinaMan}},
		FrameRegion: "100/100",
	}
	got, err := DecodeChangeZoneResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChangeZoneResult: %v", err)
	}
	if got.OK != want.OK || got.Zone != want.Zone || got.X != want.X || got.Y != want.Y || got.Z != want.Z || len(got.Others) != 1 {
		t.Fatalf("got %+v, want %+v", got, want)
	}
	if !sameSnapshot(got.Others[0], want.Others[0]) {
		t.Fatalf("got other %+v, want %+v", got.Others[0], want.Others[0])
	}
	if got.FrameRegion != want.FrameRegion {
		t.Fatalf("got FrameRegion %q, want %q", got.FrameRegion, want.FrameRegion)
	}
}

// legacyWorldTail is how every server before round 570 ended an
// EnterWorldResult or a ChangeZoneResult: the u16 entity count and the
// snapshots, nothing after them. Built by hand, not by Encode, so the
// compatibility test below does not lean on the code it checks.
func legacyWorldTail(others []EntitySnapshot) []byte {
	out := []byte{byte(len(others)), byte(len(others) >> 8)}
	for _, o := range others {
		out = append(out, o.Encode()...)
	}
	return out
}

// The frame rides where an older client stops reading (round 570): the new
// payload is the old one, byte for byte, with FrameRegion appended -- so a
// tagged client's decoder, which returns after the entity list, reads exactly
// what it read before -- and an older server's payload, which ends at the
// list, decodes with FrameRegion "". A frame cut short is a decode error.
// NEGATIVE: before round 570 the structs have no FrameRegion and this does
// not compile.
func TestWorldResultsCarryTheFrameAfterTheList(t *testing.T) {
	others := []EntitySnapshot{{CharacterID: 1, Name: "Bram", X: 4, Y: 5, Z: 6, Gender: character.GenderChinaMan}}

	cz := &ChangeZoneResult{OK: true, Zone: "hotan", X: 1, Y: 2, Z: 3, Others: others, FrameRegion: "92/135"}
	legacy := encodeOKReason(true, "")
	legacy = append(legacy, encodeStrings(cz.Zone)...)
	legacy = append(legacy, encodeFloat32(cz.X)...)
	legacy = append(legacy, encodeFloat32(cz.Y)...)
	legacy = append(legacy, encodeFloat32(cz.Z)...)
	legacy = append(legacy, legacyWorldTail(others)...)
	framed := cz.Encode()
	if !bytes.Equal(framed, append(append([]byte{}, legacy...), encodeStrings("92/135")...)) {
		t.Fatalf("ChangeZoneResult is not the old payload plus the frame:\n got  % x\n want % x + frame", framed, legacy)
	}
	old, err := DecodeChangeZoneResult(legacy)
	if err != nil || old.FrameRegion != "" || old.Zone != "hotan" || len(old.Others) != 1 {
		t.Fatalf("an older server's ChangeZoneResult: %+v (err=%v), want zone hotan, one other, FrameRegion \"\"", old, err)
	}
	if _, err := DecodeChangeZoneResult(framed[:len(framed)-2]); err == nil {
		t.Fatal("a ChangeZoneResult cut inside its frame decoded; want an error")
	}

	ew := &EnterWorldResult{OK: true, Zone: "jangan", X: 1, Y: 2, Z: 3, Gender: character.GenderChinaMan,
		HP: 73, MaxHP: 100, Others: others, FrameRegion: "97/168"}
	legacy = encodeOKReason(true, "")
	legacy = append(legacy, encodeStrings(ew.Zone)...)
	legacy = append(legacy, encodeFloat32(ew.X)...)
	legacy = append(legacy, encodeFloat32(ew.Y)...)
	legacy = append(legacy, encodeFloat32(ew.Z)...)
	legacy = append(legacy, encodeStrings(ew.Gender)...)
	legacy = append(legacy, 73, 0, 0, 0, 100, 0, 0, 0)
	legacy = append(legacy, legacyWorldTail(others)...)
	framed = ew.Encode()
	if !bytes.Equal(framed, append(append([]byte{}, legacy...), encodeStrings("97/168")...)) {
		t.Fatalf("EnterWorldResult is not the old payload plus the frame:\n got  % x\n want % x + frame", framed, legacy)
	}
	oldEnter, err := DecodeEnterWorldResult(legacy)
	if err != nil || oldEnter.FrameRegion != "" || oldEnter.HP != 73 || len(oldEnter.Others) != 1 {
		t.Fatalf("an older server's EnterWorldResult: %+v (err=%v), want HP 73, one other, FrameRegion \"\"", oldEnter, err)
	}
	if _, err := DecodeEnterWorldResult(append(append([]byte{}, legacy...), 0x06)); err == nil {
		t.Fatal("an EnterWorldResult with one stray byte after its list decoded; want an error")
	}
}

// The frame each result names is the zone's own centre -- worldmap.FrameFor,
// the region the client builds the zone around (round 569 made the two
// agree) -- so naming it changes no coordinate's meaning. An "x/y" label is
// its own frame; a label with no frame names none, and the client keeps its
// own reading of it.
func TestFrameForNamesEachZonesCentre(t *testing.T) {
	for zone, want := range map[string]string{
		"jangan":         "97/168",
		"dunhuang":       "102/153",
		"donwhang":       "102/153",
		"constantinople": "105/79",
		"hotan":          "92/135",
		"samarkand":      "106/107",
		"100/100":        "100/100",
		"Jangan":         "",
		"nowhere":        "",
	} {
		if got := frameFor(zone); got != want {
			t.Errorf("frameFor(%q) = %q, want %q", zone, got, want)
		}
	}
}

func TestChangeZoneResultRoundTripFailure(t *testing.T) {
	want := &ChangeZoneResult{OK: false, Reason: "already in that zone"}
	got, err := DecodeChangeZoneResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChangeZoneResult: %v", err)
	}
	if got.OK || got.Reason != want.Reason {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestChangeZoneFlow logs three characters in, moves one between real zone
// labels, and confirms: the mover gets a real OpChangeZoneResult, whoever's
// left behind in the old zone gets OpEntityLeft, whoever's already in the
// new zone gets a fresh OpEntityEntered, and the two guard-rail error paths
// (empty zone, changing to the zone you're already in) fail cleanly --
// all through the real server stack over TCP.
func TestChangeZoneFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	accounts.Add("cara", "hunter4")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	chars.Create(ctx, 3, "Cyra")

	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), worldTestMaxStacks{})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}

	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(srvCtx)

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)
	connC := dialTestServer(t, addr)
	defer connC.Close()
	rC := bufio.NewReader(connC)

	sendRecv := func(conn net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}
	login := func(conn net.Conn, r *bufio.Reader, user, pass, charName string) {
		resp := sendRecv(conn, r, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode())
		if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
			t.Fatalf("%s login failed: err=%v result=%+v", user, err, lr)
		}
		resp = sendRecv(conn, r, OpEnterWorld, (&EnterWorldRequest{CharacterName: charName}).Encode())
		if ewr, err := DecodeEnterWorldResult(resp.Data); err != nil || !ewr.OK {
			t.Fatalf("%s enter world failed: err=%v result=%+v", charName, err, ewr)
		} else if ewr.FrameRegion != "97/168" {
			t.Fatalf("%s entered jangan in frame %q, want 97/168 (its ZoneCentre)", charName, ewr.FrameRegion)
		}
	}

	// All three start in the default spawn zone ("jangan").
	login(connA, rA, "alice", "hunter2", "Aria")
	login(connB, rB, "bob", "hunter3", "Bram")
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil { // Aria's OpEntityEntered for Bram
		t.Fatalf("draining Aria's OpEntityEntered for Bram: %v", err)
	}
	login(connC, rC, "cara", "hunter4", "Cyra")
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA, nil, nil); err != nil { // Aria's OpEntityEntered for Cyra
		t.Fatalf("draining Aria's OpEntityEntered for Cyra: %v", err)
	}
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rB, nil, nil); err != nil { // Bram's OpEntityEntered for Cyra
		t.Fatalf("draining Bram's OpEntityEntered for Cyra: %v", err)
	}

	// Guard rails: empty zone and same-zone are both rejected, no state change.
	resp := sendRecv(connB, rB, OpChangeZone, (&ChangeZoneRequest{Zone: ""}).Encode())
	if czr, err := DecodeChangeZoneResult(resp.Data); err != nil || czr.OK || czr.Reason != "zone required" {
		t.Fatalf("empty zone: got %+v (err=%v), want reason 'zone required'", czr, err)
	}
	resp = sendRecv(connB, rB, OpChangeZone, (&ChangeZoneRequest{Zone: "jangan"}).Encode())
	if czr, err := DecodeChangeZoneResult(resp.Data); err != nil || czr.OK || czr.Reason != "already in that zone" {
		t.Fatalf("same zone: got %+v (err=%v), want reason 'already in that zone'", czr, err)
	}

	// Bram warps to a real region-shaped zone label. Should get a real ack,
	// and Aria/Cyra (left behind in jangan) should each see OpEntityLeft.
	resp = sendRecv(connB, rB, OpChangeZone, (&ChangeZoneRequest{Zone: "100/100"}).Encode())
	czr, err := DecodeChangeZoneResult(resp.Data)
	if err != nil || !czr.OK || czr.Zone != "100/100" {
		t.Fatalf("Bram's zone change: got %+v (err=%v), want ok zone=100/100", czr, err)
	}
	if czr.FrameRegion != "100/100" {
		t.Fatalf("Bram's zone change names frame %q, want 100/100 (an x/y label is its own frame)", czr.FrameRegion)
	}
	if len(czr.Others) != 0 {
		t.Fatalf("Bram should be alone in 100/100, got Others=%+v", czr.Others)
	}
	for name, r := range map[string]*bufio.Reader{"Aria": rA, "Cyra": rC} {
		var conn net.Conn = connA
		if name == "Cyra" {
			conn = connC
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		left, err := proto.Read(r, nil, nil)
		if err != nil || left.Opcode != OpEntityLeft {
			t.Fatalf("%s should see OpEntityLeft for Bram: opcode=%v err=%v", name, left, err)
		}
		leftMsg, err := DecodeEntityLeft(left.Data)
		if err != nil || leftMsg.CharacterID != 2 {
			t.Fatalf("%s's EntityLeft should name Bram (id 2): %+v (err=%v)", name, leftMsg, err)
		}
	}

	// Cyra follows Bram into 100/100: Bram should see her OpEntityEntered
	// there, and Aria (left behind in jangan) should see her OpEntityLeft.
	resp = sendRecv(connC, rC, OpChangeZone, (&ChangeZoneRequest{Zone: "100/100"}).Encode())
	czr, err = DecodeChangeZoneResult(resp.Data)
	if err != nil || !czr.OK || czr.Zone != "100/100" {
		t.Fatalf("Cyra's zone change: got %+v (err=%v), want ok zone=100/100", czr, err)
	}
	if len(czr.Others) != 1 || czr.Others[0].Name != "Bram" {
		t.Fatalf("Cyra should see Bram already in 100/100, got Others=%+v", czr.Others)
	}
	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	entered, err := proto.Read(rB, nil, nil)
	if err != nil || entered.Opcode != OpEntityEntered {
		t.Fatalf("Bram should see OpEntityEntered for Cyra: opcode=%v err=%v", entered, err)
	}
	enteredSnap, _, err := decodeEntitySnapshot(entered.Data)
	if err != nil || enteredSnap.Name != "Cyra" {
		t.Fatalf("expected EntityEntered for Cyra, got %+v (err=%v)", enteredSnap, err)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	left, err := proto.Read(rA, nil, nil)
	if err != nil || left.Opcode != OpEntityLeft {
		t.Fatalf("Aria should see OpEntityLeft for Cyra: opcode=%v err=%v", left, err)
	}
	leftMsg, err := DecodeEntityLeft(left.Data)
	if err != nil || leftMsg.CharacterID != 3 {
		t.Fatalf("Aria's EntityLeft should name Cyra (id 3): %+v (err=%v)", leftMsg, err)
	}
}

// startFrameWorld serves the world handlers over TCP with in-memory stores
// for the single-frame tests (round 571): two accounts, alice/Aria and
// bob/Bram, connected but not yet in the world, so each test decides who
// enters and moves when. The fixture's read/send/login/nothing helpers need
// no state of their own, so a zero deadWorldFixture carries them.
func startFrameWorld(t *testing.T) (f *deadWorldFixture, connA net.Conn, rA *bufio.Reader, connB net.Conn, rB *bufio.Reader) {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub)))
	t.Cleanup(cleanup)
	connA = dialTestServer(t, addr)
	t.Cleanup(func() { connA.Close() })
	connB = dialTestServer(t, addr)
	t.Cleanup(func() { connB.Close() })
	return &deadWorldFixture{}, connA, bufio.NewReader(connA), connB, bufio.NewReader(connB)
}

// changeZone sends one OpChangeZone and decodes the reply.
func changeZone(t *testing.T, f *deadWorldFixture, conn net.Conn, r *bufio.Reader, zone string) *ChangeZoneResult {
	t.Helper()
	f.send(t, conn, OpChangeZone, (&ChangeZoneRequest{Zone: zone}).Encode())
	p := f.read(t, conn, r)
	if p.Opcode != OpChangeZoneResult {
		t.Fatalf("change to %q answered %#04x, want OpChangeZoneResult", zone, p.Opcode)
	}
	czr, err := DecodeChangeZoneResult(p.Data)
	if err != nil {
		t.Fatalf("decoding the change to %q: %v", zone, err)
	}
	return czr
}

// near reports whether (x, z) is within 0.01 of (wantX, wantZ).
func near(x, z float32, wantX, wantZ float64) bool {
	return math.Abs(float64(x)-wantX) < 0.01 && math.Abs(float64(z)-wantZ) < 0.01
}

// Under -single-frame (round 571) every town is named in ONE frame, Jangan's
// 97/168, and every player is in ONE bucket. Expected positions are derived
// from worldmap.ToWorld, never written from prose (the batch's sign rule),
// with the axes AGENTS.md records: region y drives world X, region x drives
// world Z, Z mirrored. A zone change lands at the middle of the town's centre
// region -- local (960, 960), where spawnPos stands in the zone's own frame --
// named in the one frame: Donwhang's 102/153 is 15 regions down in y (X
// negative) and 5 up in x (Z negative, the mirror).
func TestSingleFramePutsEveryTownInOneFrameAndOneBucket(t *testing.T) {
	SetSingleFrame(true)
	t.Cleanup(func() { SetSingleFrame(false) })
	f, connA, rA, connB, rB := startFrameWorld(t)
	origin := worldmap.WorldOrigin
	originLabel := fmt.Sprintf("%d/%d", origin[0], origin[1])
	if originLabel != "97/168" {
		t.Fatalf("the one frame's origin is %s, want Jangan's 97/168", originLabel)
	}

	// Bram enters at Jangan: the one frame, at Jangan's landing -- (0, 0),
	// where spawnPos has always put him.
	ewrB := f.login(t, connB, rB, "bob", "hunter3", "Bram")
	janganX, janganZ := worldmap.ToWorld(97, 168, 960, 960, origin[0], origin[1])
	if ewrB.Zone != "jangan" || ewrB.FrameRegion != "97/168" || !near(ewrB.X, ewrB.Z, janganX, janganZ) || ewrB.Y != 0 {
		t.Fatalf("Bram entered %q in frame %q at (%g, %g, %g), want jangan in 97/168 at (%g, 0, %g)",
			ewrB.Zone, ewrB.FrameRegion, ewrB.X, ewrB.Y, ewrB.Z, janganX, janganZ)
	}

	// He warps to Donwhang: the label stays the client's ("donwhang", the grid
	// centre it builds around), the frame is the one world's, and the position
	// is Donwhang's landing named in it -- not (0, 0, 0), which in 97/168's
	// frame is Jangan's middle, off the grid a Donwhang client builds.
	donX, donZ := worldmap.ToWorld(102, 153, 960, 960, origin[0], origin[1])
	czr := changeZone(t, f, connB, rB, "donwhang")
	if !czr.OK || czr.Zone != "donwhang" || czr.FrameRegion != "97/168" || !near(czr.X, czr.Z, donX, donZ) || czr.Y != 0 {
		t.Fatalf("Bram's change to donwhang: %+v, want ok donwhang in 97/168 at (%g, 0, %g)", czr, donX, donZ)
	}
	if len(czr.Others) != 0 {
		t.Fatalf("nobody else is in the world yet, got Others=%+v", czr.Others)
	}

	// Aria enters at Jangan. One bucket: Bram is in her list, standing at
	// Donwhang's landing, and Bram -- the Donwhang player -- hears the Jangan
	// player arrive.
	ewrA := f.login(t, connA, rA, "alice", "hunter2", "Aria")
	if ewrA.FrameRegion != "97/168" || len(ewrA.Others) != 1 || ewrA.Others[0].Name != "Bram" ||
		!near(ewrA.Others[0].X, ewrA.Others[0].Z, donX, donZ) {
		t.Fatalf("Aria entered in frame %q with Others=%+v, want 97/168 and Bram at (%g, %g)", ewrA.FrameRegion, ewrA.Others, donX, donZ)
	}
	p := f.read(t, connB, rB)
	if p.Opcode != OpEntityEntered {
		t.Fatalf("Bram in Donwhang got %#04x after Aria entered Jangan, want OpEntityEntered", p.Opcode)
	}
	if snap, _, err := decodeEntitySnapshot(p.Data); err != nil || snap.Name != "Aria" || !near(snap.X, snap.Z, janganX, janganZ) {
		t.Fatalf("Bram's OpEntityEntered: %+v (err=%v), want Aria at (%g, %g)", snap, err, janganX, janganZ)
	}

	// Bram warps on to Hotan. The same bucket is left and re-entered, so Aria
	// hears him leave and then arrive at Hotan's landing: the Jangan player
	// gets the other's OpEntityEntered too (the flicker the round records).
	hotX, hotZ := worldmap.ToWorld(92, 135, 960, 960, origin[0], origin[1])
	czr = changeZone(t, f, connB, rB, "hotan")
	if !czr.OK || czr.FrameRegion != "97/168" || !near(czr.X, czr.Z, hotX, hotZ) || len(czr.Others) != 1 || czr.Others[0].Name != "Aria" {
		t.Fatalf("Bram's change to hotan: %+v, want ok in 97/168 at (%g, %g) with Aria in Others", czr, hotX, hotZ)
	}
	if p := f.read(t, connA, rA); p.Opcode != OpEntityLeft {
		t.Fatalf("Aria's first packet after Bram's warp is %#04x, want OpEntityLeft", p.Opcode)
	}
	p = f.read(t, connA, rA)
	if p.Opcode != OpEntityEntered {
		t.Fatalf("Aria's second packet after Bram's warp is %#04x, want OpEntityEntered", p.Opcode)
	}
	if snap, _, err := decodeEntitySnapshot(p.Data); err != nil || snap.Name != "Bram" || !near(snap.X, snap.Z, hotX, hotZ) {
		t.Fatalf("Aria's OpEntityEntered: %+v (err=%v), want Bram at (%g, %g)", snap, err, hotX, hotZ)
	}

	// In one bucket a label is a grid hint, not a place he is "already in":
	// asking for Hotan again is another warp to its landing.
	if czr = changeZone(t, f, connB, rB, "hotan"); !czr.OK || !near(czr.X, czr.Z, hotX, hotZ) {
		t.Fatalf("Bram's second change to hotan: %+v, want ok at (%g, %g)", czr, hotX, hotZ)
	}
	f.read(t, connA, rA) // Aria's OpEntityLeft
	f.read(t, connA, rA) // Aria's OpEntityEntered

	// A label with no frame keeps its own bucket and the old wire: FrameRegion
	// "", spawnPos, alone -- Aria hears him leave and nothing more.
	czr = changeZone(t, f, connB, rB, "nowhere")
	if !czr.OK || czr.FrameRegion != "" || czr.X != float32(spawnPos.X) || czr.Y != float32(spawnPos.Y) || czr.Z != float32(spawnPos.Z) || len(czr.Others) != 0 {
		t.Fatalf("Bram's change to an unframed label: %+v, want ok, no frame, spawnPos, alone", czr)
	}
	if p := f.read(t, connA, rA); p.Opcode != OpEntityLeft {
		t.Fatalf("Aria's packet after Bram left the world bucket is %#04x, want OpEntityLeft", p.Opcode)
	}
	if !f.nothing(t, connA, rA) {
		t.Fatal("Aria heard more than Bram's OpEntityLeft when he went to an unframed label")
	}
}

// With -single-frame off -- the default, and the NEGATIVE of the test above --
// the wire is what it was: each zone is named in its own centre's frame
// (worldmap.FrameFor: Donwhang's 102/153 since round 569), every arrival
// stands at spawnPos, each zone is its own bucket, and a change to the zone
// a character is in is refused.
func TestSingleFrameOffKeepsEachZoneInItsOwnFrame(t *testing.T) {
	SetSingleFrame(false)
	f, connA, rA, connB, rB := startFrameWorld(t)
	atSpawn := func(x, y, z float32) bool {
		return x == float32(spawnPos.X) && y == float32(spawnPos.Y) && z == float32(spawnPos.Z)
	}
	frameOf := func(zone string) string {
		rx, ry, ok := worldmap.FrameFor(zone)
		if !ok {
			t.Fatalf("%s has no frame", zone)
		}
		return fmt.Sprintf("%d/%d", rx, ry)
	}

	ewrB := f.login(t, connB, rB, "bob", "hunter3", "Bram")
	if ewrB.FrameRegion != frameOf("jangan") || !atSpawn(ewrB.X, ewrB.Y, ewrB.Z) {
		t.Fatalf("Bram entered in frame %q at (%g, %g, %g), want %s at spawnPos", ewrB.FrameRegion, ewrB.X, ewrB.Y, ewrB.Z, frameOf("jangan"))
	}
	czr := changeZone(t, f, connB, rB, "donwhang")
	if !czr.OK || czr.FrameRegion != frameOf("donwhang") || czr.FrameRegion != "102/153" || !atSpawn(czr.X, czr.Y, czr.Z) {
		t.Fatalf("Bram's change to donwhang: %+v, want ok in 102/153 at spawnPos", czr)
	}

	// Aria enters Jangan: a different bucket from Bram's, so neither hears of
	// the other.
	ewrA := f.login(t, connA, rA, "alice", "hunter2", "Aria")
	if len(ewrA.Others) != 0 {
		t.Fatalf("Aria in Jangan sees Others=%+v, want nobody (Bram is in Donwhang's bucket)", ewrA.Others)
	}
	if !f.nothing(t, connB, rB) {
		t.Fatal("Bram in Donwhang received a packet when Aria entered Jangan")
	}
	czr = changeZone(t, f, connB, rB, "hotan")
	if !czr.OK || czr.FrameRegion != frameOf("hotan") || !atSpawn(czr.X, czr.Y, czr.Z) {
		t.Fatalf("Bram's change to hotan: %+v, want ok in %s at spawnPos", czr, frameOf("hotan"))
	}
	if !f.nothing(t, connA, rA) {
		t.Fatal("Aria in Jangan received a packet when Bram went from Donwhang to Hotan")
	}
	if czr = changeZone(t, f, connB, rB, "hotan"); czr.OK || czr.Reason != "already in that zone" {
		t.Fatalf("Bram's second change to hotan: %+v, want refused 'already in that zone'", czr)
	}
}

// ZoneBucket and arrival are one rule: the bucket arrival keeps a character
// in is ZoneBucket's for the same label, with the flag on and off.
func TestArrivalKeepsEveryLabelInZoneBucket(t *testing.T) {
	t.Cleanup(func() { SetSingleFrame(false) })
	for _, on := range []bool{false, true} {
		SetSingleFrame(on)
		for _, zone := range []string{"jangan", "donwhang", "dunhuang", "constantinople", "hotan", "samarkand", "100/100", "Jangan", "nowhere", worldmap.WorldBucket} {
			bucket, _, _, oneWorld := arrival(zone)
			if bucket != ZoneBucket(zone) {
				t.Errorf("single frame %v: arrival(%q) keeps it in %q, ZoneBucket says %q", on, zone, bucket, ZoneBucket(zone))
			}
			_, _, framed := worldmap.FrameFor(zone)
			if want := on && framed; oneWorld != want {
				t.Errorf("single frame %v: arrival(%q) oneWorld = %v, want %v", on, zone, oneWorld, want)
			}
		}
	}
}

// TestWorldFullFlow logs two accounts in on separate connections, enters
// each into the world, and confirms: the second entrant sees the first as
// an "other" in their EnterWorldResult, the first gets an OpEntityEntered
// for the second, a move from one broadcasts OpEntityMoved to the other,
// and disconnecting one sends OpEntityLeft to the other -- all through the
// real server stack over TCP.
func TestWorldFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	// Aria picks the real china_woman body at creation; Bram keeps the
	// real default -- exercises both real Gender outcomes through the
	// actual EnterWorld/EntityEntered flow, not just the standalone
	// Encode/Decode round trip above.
	if err := chars.SetGender(ctx, aria.ID, character.GenderChinaWoman); err != nil {
		t.Fatalf("setting Aria's gender: %v", err)
	}

	// Bram has a real armor piece (SlotMail) and a real shield equipped but
	// no weapon; Aria has a real weapon equipped but no armor/shield --
	// exercises armour, weapon and shield independently, through the
	// actual EnterWorld/EntityEntered flow, not just the standalone
	// Encode/Decode round trip above.
	inv, err := inventory.OpenSQLStore(inventoryTestDSN(), worldTestMaxStacks{200: 1, 201: 1, 202: 1})
	if err != nil {
		t.Fatalf("inventory.OpenSQLStore: %v (is postgres running?)", err)
	}
	defer inv.Close()
	if err := inv.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating inventory: %v", err)
	}
	eq, err := equipment.OpenSQLStore(inventoryTestDSN(), inv)
	if err != nil {
		t.Fatalf("equipment.OpenSQLStore: %v", err)
	}
	defer eq.Close()
	if err := eq.TruncateForTest(ctx); err != nil {
		t.Fatalf("truncating equipment: %v", err)
	}
	if err := inv.AddItem(ctx, bram.ID, 200, 1); err != nil {
		t.Fatalf("seeding Bram's inventory: %v", err)
	}
	if err := eq.Equip(ctx, bram.ID, equipment.SlotMail, 0); err != nil {
		t.Fatalf("equipping Bram's armor: %v", err)
	}
	if err := inv.AddItem(ctx, bram.ID, 202, 1); err != nil {
		t.Fatalf("seeding Bram's inventory (shield): %v", err)
	}
	// Bram's inventory slot 0 freed up once the mail moved to equipment,
	// so the shield lands there, not slot 1.
	if err := eq.Equip(ctx, bram.ID, equipment.SlotShield, 0); err != nil {
		t.Fatalf("equipping Bram's shield: %v", err)
	}
	if err := inv.AddItem(ctx, aria.ID, 201, 1); err != nil {
		t.Fatalf("seeding Aria's inventory: %v", err)
	}
	if err := eq.Equip(ctx, aria.ID, equipment.SlotWeapon, 0); err != nil {
		t.Fatalf("equipping Aria's weapon: %v", err)
	}

	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, eq, hub))

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go srv.ListenAndServe(srvCtx)

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)

	connB := dialTestServer(t, addr)
	rB := bufio.NewReader(connB)

	sendRecv := func(conn net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return resp
	}

	// Alice logs in and enters the world first, alone.
	resp := sendRecv(connA, rA, OpLogin, (&LoginRequest{Username: "alice", Password: "hunter2"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("alice login failed: err=%v result=%+v", err, lr)
	}
	resp = sendRecv(connA, rA, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	ewr, err := DecodeEnterWorldResult(resp.Data)
	if err != nil || !ewr.OK {
		t.Fatalf("alice enter world failed: err=%v result=%+v", err, ewr)
	}
	if len(ewr.Others) != 0 {
		t.Fatalf("alice should see nobody else yet, got %+v", ewr.Others)
	}
	if ewr.Gender != character.GenderChinaWoman {
		t.Fatalf("alice's own EnterWorldResult should carry her real gender %q, got %q", character.GenderChinaWoman, ewr.Gender)
	}

	// Bob logs in and enters the world; should see Aria as an "other".
	resp = sendRecv(connB, rB, OpLogin, (&LoginRequest{Username: "bob", Password: "hunter3"}).Encode())
	if lr, err := DecodeLoginResult(resp.Data); err != nil || !lr.OK {
		t.Fatalf("bob login failed: err=%v result=%+v", err, lr)
	}
	resp = sendRecv(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	ewr, err = DecodeEnterWorldResult(resp.Data)
	if err != nil || !ewr.OK {
		t.Fatalf("bob enter world failed: err=%v result=%+v", err, ewr)
	}
	if len(ewr.Others) != 1 || ewr.Others[0].Name != "Aria" {
		t.Fatalf("bob should see Aria, got %+v", ewr.Others)
	}
	for _, slot := range equipment.ArmorSlots {
		if id := ewr.Others[0].EquippedIn(slot); id != 0 {
			t.Fatalf("Aria has no armor equipped, but bob's snapshot claims item %d in slot %v: %+v", id, slot, ewr.Others[0])
		}
	}
	if ewr.Others[0].EquippedIn(equipment.SlotWeapon) != 201 {
		t.Fatalf("Aria has item 201 equipped as her weapon, but bob's snapshot says %+v", ewr.Others[0])
	}
	if ewr.Others[0].EquippedIn(equipment.SlotShield) != 0 {
		t.Fatalf("Aria has no shield equipped, but bob's snapshot claims one: %+v", ewr.Others[0])
	}
	if ewr.Others[0].Gender != character.GenderChinaWoman {
		t.Fatalf("bob's snapshot of Aria should carry her real gender %q, got %q", character.GenderChinaWoman, ewr.Others[0].Gender)
	}
	if ewr.Gender != character.GenderChinaMan {
		t.Fatalf("bob's own EnterWorldResult should carry his real (default) gender %q, got %q", character.GenderChinaMan, ewr.Gender)
	}

	// Alice should now receive an OpEntityEntered for Bram carrying the
	// item in his mail slot -- his real equipped state, queried live from
	// the equipment store, not a hardcoded/default value.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	entered, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading OpEntityEntered: %v", err)
	}
	if entered.Opcode != OpEntityEntered {
		t.Fatalf("got opcode 0x%04x, want OpEntityEntered", entered.Opcode)
	}
	enteredSnap, _, err := decodeEntitySnapshot(entered.Data)
	if err != nil || enteredSnap.Name != "Bram" {
		t.Fatalf("expected EntityEntered for Bram, got %+v (err=%v)", enteredSnap, err)
	}
	if enteredSnap.EquippedIn(equipment.SlotMail) != 200 {
		t.Fatalf("Bram has item 200 equipped as mail, but EntityEntered says %+v", enteredSnap)
	}
	if enteredSnap.EquippedIn(equipment.SlotWeapon) != 0 {
		t.Fatalf("Bram has no weapon equipped, but EntityEntered claims one: %+v", enteredSnap)
	}
	if enteredSnap.EquippedIn(equipment.SlotShield) != 202 {
		t.Fatalf("Bram has item 202 equipped as his shield, but EntityEntered says %+v", enteredSnap)
	}
	if enteredSnap.Gender != character.GenderChinaMan {
		t.Fatalf("Bram's real gender is the default %q, got %q", character.GenderChinaMan, enteredSnap.Gender)
	}

	// Bob moves; Alice should see OpEntityMoved.
	if err := proto.Write(connB, &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: 10, Y: 20, Z: 30}).Encode()}, nil, nil); err != nil {
		t.Fatalf("bob move write: %v", err)
	}
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	moved, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading OpEntityMoved: %v", err)
	}
	if moved.Opcode != OpEntityMoved {
		t.Fatalf("got opcode 0x%04x, want OpEntityMoved", moved.Opcode)
	}
	movedMsg, err := DecodeEntityMoved(moved.Data)
	if err != nil || movedMsg.X != 10 || movedMsg.Y != 20 || movedMsg.Z != 30 {
		t.Fatalf("unexpected EntityMoved: %+v (err=%v)", movedMsg, err)
	}

	// Bob disconnects; Alice should see OpEntityLeft.
	connB.Close()
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	left, err := proto.Read(rA, nil, nil)
	if err != nil {
		t.Fatalf("reading OpEntityLeft: %v", err)
	}
	if left.Opcode != OpEntityLeft {
		t.Fatalf("got opcode 0x%04x, want OpEntityLeft", left.Opcode)
	}
	leftMsg, err := DecodeEntityLeft(left.Data)
	if err != nil || leftMsg.CharacterID != movedMsg.CharacterID {
		t.Fatalf("unexpected EntityLeft: %+v (err=%v)", leftMsg, err)
	}
}

// ---- The player's dead state, the server half (round 549) ----

// The revive pair's numbers and bytes are the client's
// (client/scripts/net/world.gd, pinned by world_test.gd; the fixtures in
// docs/protocol/monster_ai.md): OpRevive 0x0028 empty, OpReviveResult 0x0029 a
// u16-prefixed error then s32 HP and s32 MP -- 80/40 encodes as
// `00 00 50 00 00 00 28 00 00 00`, and "not dead" as `08 00 6e 6f 74 20 64 65
// 61 64` with no tail.
func TestReviveResultMatchesTheClientFixture(t *testing.T) {
	if OpRevive != 0x0028 || OpReviveResult != 0x0029 {
		t.Fatalf("OpRevive/OpReviveResult = %#04x/%#04x; the client pins 0x0028/0x0029", OpRevive, OpReviveResult)
	}
	for _, op := range []uint16{OpEnterWorld, OpEnterWorldResult, OpMove, OpEntityEntered, OpEntityMoved, OpEntityLeft, OpChangeZone, OpChangeZoneResult} {
		if op == OpRevive || op == OpReviveResult {
			t.Errorf("the revive pair collides with world opcode %#04x", op)
		}
	}
	ok := (&ReviveResult{HP: 80, MP: 40}).Encode()
	if want := []byte{0x00, 0x00, 0x50, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00}; !bytes.Equal(ok, want) {
		t.Errorf("a revive at 80/40 encodes as % x, want % x", ok, want)
	}
	refused := (&ReviveResult{Error: "not dead"}).Encode()
	if want := []byte{0x08, 0x00, 'n', 'o', 't', ' ', 'd', 'e', 'a', 'd'}; !bytes.Equal(refused, want) {
		t.Errorf("the refusal encodes as % x, want % x", refused, want)
	}
	for _, want := range []ReviveResult{{HP: 80, MP: 40}, {Error: "not dead"}, {HP: -1, MP: 0}} {
		got, err := DecodeReviveResult(want.Encode())
		if err != nil || *got != want {
			t.Errorf("round trip of %+v: %+v (err %v)", want, got, err)
		}
	}
	if _, err := DecodeReviveResult([]byte{0x00, 0x00, 0x50, 0x00}); err == nil {
		t.Error("a success with truncated vitals decoded")
	}
}

// deadWorldFixture is Aria and Bram in jangan over in-memory stores, with the
// world and revive handlers and a way to kill Aria the way a monster's blow
// does (HP 0 and life state 2 with a time of death).
type deadWorldFixture struct {
	chars      *character.MemStore
	hub        *world.Hub
	aria, bram int64
	connA      net.Conn
	rA         *bufio.Reader
	connB      net.Conn
	rB         *bufio.Reader
}

func startDeadWorldFixture(t *testing.T) *deadWorldFixture {
	t.Helper()
	return startDeadWorldFixtureWith(t, nil)
}

// startDeadWorldFixtureWith is startDeadWorldFixture with one more handler in
// the chain, built over the fixture's stores (round 550: the guild gate's
// test).
func startDeadWorldFixtureWith(t *testing.T, extra func(chars character.Store, hub *world.Hub) gateway.Handler) *deadWorldFixture {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	handlers := []gateway.Handler{LoginHandler(accounts), WorldHandler(chars, nil, hub), ReviveHandler(chars, hub, RegenDeps{})}
	if extra != nil {
		handlers = append(handlers, extra(chars, hub))
	}
	handle := gateway.Chain(handlers...)
	addr, cleanup := startTestServer(t, handle)
	t.Cleanup(cleanup)
	f := &deadWorldFixture{chars: chars, hub: hub, aria: aria.ID, bram: bram.ID}
	f.connA = dialTestServer(t, addr)
	t.Cleanup(func() { f.connA.Close() })
	f.rA = bufio.NewReader(f.connA)
	f.connB = dialTestServer(t, addr)
	t.Cleanup(func() { f.connB.Close() })
	f.rB = bufio.NewReader(f.connB)
	f.login(t, f.connA, f.rA, "alice", "hunter2", "Aria")
	f.login(t, f.connB, f.rB, "bob", "hunter3", "Bram")
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpEntityEntered { // Aria's notice of Bram
		t.Fatalf("Aria's first packet after Bram entered is %#04x, want OpEntityEntered", p.Opcode)
	}
	return f
}

func (f *deadWorldFixture) read(t *testing.T, conn net.Conn, r *bufio.Reader) *proto.Packet {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("Read: %v", err)
	}
	return p
}

// nothing reports that conn receives no packet within 300 ms.
func (f *deadWorldFixture) nothing(t *testing.T, conn net.Conn, r *bufio.Reader) bool {
	t.Helper()
	conn.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
	p, err := proto.Read(r, nil, nil)
	if err == nil {
		t.Logf("unexpected packet %#04x", p.Opcode)
	}
	return err != nil
}

func (f *deadWorldFixture) send(t *testing.T, conn net.Conn, opcode uint16, data []byte) {
	t.Helper()
	if err := proto.Write(conn, &proto.Packet{Opcode: opcode, Data: data}, nil, nil); err != nil {
		t.Fatalf("Write: %v", err)
	}
}

func (f *deadWorldFixture) login(t *testing.T, conn net.Conn, r *bufio.Reader, user, pass, name string) *EnterWorldResult {
	t.Helper()
	f.send(t, conn, OpLogin, (&LoginRequest{Username: user, Password: pass}).Encode())
	if lr, err := DecodeLoginResult(f.read(t, conn, r).Data); err != nil || !lr.OK {
		t.Fatalf("%s login failed: err=%v result=%+v", user, err, lr)
	}
	f.send(t, conn, OpEnterWorld, (&EnterWorldRequest{CharacterName: name}).Encode())
	ewr, err := DecodeEnterWorldResult(f.read(t, conn, r).Data)
	if err != nil || !ewr.OK {
		t.Fatalf("%s enter world failed: err=%v result=%+v", name, err, ewr)
	}
	return ewr
}

// kill is what markDead leaves behind a monster's killing blow: HP 0 and life
// state 2 at `at`.
func (f *deadWorldFixture) kill(t *testing.T, characterID int64, at time.Time) {
	t.Helper()
	if _, _, err := f.chars.ApplyDamage(context.Background(), characterID, 1<<30); err != nil {
		t.Fatal(err)
	}
	if !f.hub.SetLifeState(characterID, world.LifeAlive, world.LifeDead, at) {
		t.Fatalf("character %d could not be marked dead", characterID)
	}
}

// A dead character does not change zone -- the request is refused with
// deadRefusal and nobody in either zone hears of a move -- and a living one's
// OpRevive is answered "not dead" (the retail handler's `cmp al,0x2` does
// nothing for it). After the revive the same zone change goes through.
func TestDeadCharacterCannotChangeZoneUntilRevived(t *testing.T) {
	f := startDeadWorldFixture(t)
	f.kill(t, f.aria, time.Now())

	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	czr, err := DecodeChangeZoneResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || czr.OK || czr.Reason != deadRefusal {
		t.Fatalf("a dead zone change answered %+v (err %v), want the refusal %q", czr, err, deadRefusal)
	}
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("Bram heard of a dead character's zone change")
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Zone != "jangan" {
		t.Errorf("a dead character changed zone to %q", e.Zone)
	}

	f.send(t, f.connA, OpRevive, nil)
	rr, err := DecodeReviveResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || rr.Error != "" {
		t.Fatalf("OpRevive answered %+v (err %v), want a success", rr, err)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpCharacterStatsResult {
		t.Errorf("after the revive result Aria received %#04x, want the stats push", p.Opcode)
	}
	f.send(t, f.connA, OpChangeZone, (&ChangeZoneRequest{Zone: "donwhang"}).Encode())
	if czr, err := DecodeChangeZoneResult(f.read(t, f.connA, f.rA).Data); err != nil || !czr.OK {
		t.Fatalf("the revived character's zone change answered %+v (err %v), want OK", czr, err)
	}
	if p := f.read(t, f.connB, f.rB); p.Opcode != OpEntityLeft {
		t.Errorf("Bram received %#04x after Aria left, want OpEntityLeft", p.Opcode)
	}
	f.send(t, f.connB, OpRevive, nil)
	if rr, err := DecodeReviveResult(f.read(t, f.connB, f.rB).Data); err != nil || rr.Error != "not dead" {
		t.Errorf("a living character's OpRevive answered %+v (err %v), want \"not dead\"", rr, err)
	}
}

// The auto-revive fallback (round 549, own design): a session that never sends
// OpRevive -- a client older than round 548, with no Revive button -- is
// revived unasked once AutoReviveAfter has passed since the kill, and sent the
// same OpReviveResult and stats push the handler sends. A tick a second early
// does nothing; a tick after the revive finds nobody.
func TestAutoReviveFallbackFreesAnOlderClient(t *testing.T) {
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	t0 := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	f.kill(t, f.aria, t0)

	autoReviveTick(ctx, f.hub, f.chars, RegenDeps{}, t0.Add(AutoReviveAfter-time.Second), nil)
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("the fallback revived a character a second early")
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead {
		t.Fatalf("life state %d a second before the fallback is due, want 2", e.Life)
	}

	autoReviveTick(ctx, f.hub, f.chars, RegenDeps{}, t0.Add(AutoReviveAfter), nil)
	p := f.read(t, f.connA, f.rA)
	if p.Opcode != OpReviveResult {
		t.Fatalf("the fallback sent %#04x, want OpReviveResult", p.Opcode)
	}
	rr, err := DecodeReviveResult(p.Data)
	if err != nil || rr.Error != "" {
		t.Fatalf("the fallback's result %+v (err %v), want a success", rr, err)
	}
	c, _ := f.chars.GetByID(ctx, f.aria)
	if want := reviveHPDelta(c.MaxHP()); c.HP != want || int(rr.HP) != want {
		t.Errorf("the fallback revived at HP %d (result %d), want %d (1 + trunc(0.4 x max), round 550)", c.HP, rr.HP, want)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpCharacterStatsResult {
		t.Errorf("after the fallback's result Aria received %#04x, want the stats push", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive || !e.DiedAt.IsZero() {
		t.Errorf("after the fallback: life %d, died at %v; want 1 and no time of death", e.Life, e.DiedAt)
	}
	autoReviveTick(ctx, f.hub, f.chars, RegenDeps{}, t0.Add(2*AutoReviveAfter), nil)
	if !f.nothing(t, f.connA, f.rA) {
		t.Error("a second pass revived a living character")
	}
	if !f.nothing(t, f.connB, f.rB) {
		t.Error("Bram, alive throughout, was sent something by the fallback")
	}
}

// A character logged out dead enters alive at character.RespawnFraction --
// the load path's own rule for a stored zero pool (GObjPC::FUN_004e1120, the
// 0.4 at 0x4e1141) -- with -player-dead-state on and off alike: the rule is
// the load path's, not the flag's, so a character dead when the flag is
// turned off is not left alive at 0 HP. (The flag-off server never stores a
// zero otherwise, so nothing it sends changes.)
func TestEnterWorldRevivesACharacterLoggedOutDead(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	for _, id := range []int64{aria.ID, bram.ID} {
		if _, _, err := chars.ApplyDamage(ctx, id, 1<<30); err != nil {
			t.Fatal(err)
		}
	}
	hub := world.NewHub()
	addr, cleanup := startTestServer(t, gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub)))
	t.Cleanup(cleanup)
	f := &deadWorldFixture{chars: chars, hub: hub}

	deadStateForTest(t, true)
	connA := dialTestServer(t, addr)
	defer connA.Close()
	ewr := f.login(t, connA, bufio.NewReader(connA), "alice", "hunter2", "Aria")
	if want := int(float64(aria.MaxHP()) * character.RespawnFraction); int(ewr.HP) != want {
		t.Errorf("a character logged out dead entered at HP %d, want %d (RespawnFraction of %d)", ewr.HP, want, aria.MaxHP())
	}
	if c, _ := chars.GetByID(ctx, aria.ID); c.HP == 0 {
		t.Error("the entry revive did not reach the store")
	}
	if e, _ := hub.EntityByCharacterID(aria.ID); e.Life != world.LifeAlive {
		t.Errorf("entered with life state %d, want 1", e.Life)
	}

	SetPlayerDeadState(false) // the load path's rule does not depend on the flag
	connB := dialTestServer(t, addr)
	defer connB.Close()
	if ewr := f.login(t, connB, bufio.NewReader(connB), "bob", "hunter3", "Bram"); ewr.HP <= 0 {
		t.Errorf("with the flag off a character logged out dead entered at HP %d, want RespawnFraction of the maximum", ewr.HP)
	}
}

// ---- Batch-17 review follow-ups (round 550) ----

// failingPoolStore fails every pool write -- the revive's Heal, and the
// RespawnHP an older revive used -- while fails is above 0, counting each
// refusal down.
type failingPoolStore struct {
	character.Store
	fails atomic.Int32
}

func (s *failingPoolStore) Heal(ctx context.Context, id int64, amount, maxHP int) (int, error) {
	if s.fails.Add(-1) >= 0 {
		return 0, errors.New("test: the pool write failed")
	}
	return s.Store.Heal(ctx, id, amount, maxHP)
}

func (s *failingPoolStore) RespawnHP(ctx context.Context, id int64) error {
	if s.fails.Add(-1) >= 0 {
		return errors.New("test: the pool write failed")
	}
	return s.Store.RespawnHP(ctx, id)
}

// resetAutoReviveWarned starts the test from an empty autoReviveWarned and
// leaves one behind. The map is package state: an entry another test's
// failing store left -- or, before round 550's review fix, the one a pass
// kept for the character it had just revived -- reaches the next fixture's
// Aria, id 1 in every fresh MemStore, and suppresses the WARN this test
// counts (the test failed on -count=3 that way).
func resetAutoReviveWarned(t *testing.T) {
	t.Helper()
	empty := func() {
		autoReviveWarned.Range(func(k, _ any) bool {
			autoReviveWarned.Delete(k)
			return true
		})
	}
	empty()
	t.Cleanup(empty)
}

// A store that keeps failing the auto-revive is logged ONCE for the character
// (round 550), not every pass; each failed attempt leaves her dead with her
// time of death (revivePlayer puts the state back, so the next pass tries
// again), and the pass on which the store recovers revives her, logs it and
// forgets the warning -- so a later death of the same character that fails
// again is logged again. Before this round every failing pass logged its own
// WARN; the first cut of the fix kept the entry a pass past the revive.
func TestAutoReviveWarnsOncePerCharacter(t *testing.T) {
	resetAutoReviveWarned(t)
	f := startDeadWorldFixture(t)
	ctx := context.Background()
	t0 := time.Date(2026, 9, 24, 12, 0, 0, 0, time.UTC)
	f.kill(t, f.aria, t0)
	store := &failingPoolStore{Store: f.chars}
	store.fails.Store(2)
	var log lockedBuffer
	logger := slog.New(slog.NewTextHandler(&log, nil))

	for i := 1; i <= 2; i++ {
		autoReviveTick(ctx, f.hub, store, RegenDeps{}, t0.Add(AutoReviveAfter+time.Duration(i)*time.Second), logger)
		if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeDead || !e.DiedAt.Equal(t0) {
			t.Fatalf("after failed attempt %d: life %d, died at %v; want still dead since %v (the state put back)", i, e.Life, e.DiedAt, t0)
		}
		if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != 0 {
			t.Fatalf("after failed attempt %d: HP %d, want 0", i, c.HP)
		}
	}
	if !f.nothing(t, f.connA, f.rA) {
		t.Fatal("a failed attempt sent Aria something")
	}
	if n := strings.Count(log.String(), "auto-revive failed"); n != 1 {
		t.Errorf("%d 'auto-revive failed' line(s) over two failing passes, want 1 (once per character); log:\n%s", n, log.String())
	}

	autoReviveTick(ctx, f.hub, store, RegenDeps{}, t0.Add(AutoReviveAfter+3*time.Second), logger)
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpReviveResult {
		t.Fatalf("the pass on which the store recovered sent %#04x, want OpReviveResult", p.Opcode)
	}
	if e, _ := f.hub.EntityByCharacterID(f.aria); e.Life != world.LifeAlive {
		t.Errorf("after the recovered pass: life %d, want 1", e.Life)
	}
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP != reviveHPDelta(c.MaxHP()) {
		t.Errorf("after the recovered pass: HP %d, want %d", c.HP, reviveHPDelta(c.MaxHP()))
	}
	if n := strings.Count(log.String(), "auto-revive failed"); n != 1 {
		t.Errorf("%d 'auto-revive failed' line(s) in all, want 1", n)
	}
	if !strings.Contains(log.String(), "msg=auto-revive ") {
		t.Errorf("no 'auto-revive' line for the pass that revived her; log:\n%s", log.String())
	}
	if _, lingering := autoReviveWarned.Load(f.aria); lingering {
		t.Error("Aria's 'warned' entry outlived the pass that revived her: a later failure of the same character inside that pass would go unlogged, and the next test's Aria inherits it")
	}
}

// Guild work is refused while dead (round 550), on the life state the world
// hub keeps rather than HP alone: FUN_00514b20 (the founder's pre-check) and
// CGuild::HandleLevelUp (0x5c63d0) each ask IGObj::GetLifeState for 1 and
// answer 0x4c07 GUILDERR_IM_DEAD otherwise. Aria is killed and then healed
// without being revived -- a GM's /heal fills the pools and leaves the life
// state -- so HP alone, the test until this round, would let her found a
// guild while dead. Revived, the same request goes through.
func TestGuildWorkIsRefusedWhileDead(t *testing.T) {
	guilds := guild.NewMemStore()
	f := startDeadWorldFixtureWith(t, func(chars character.Store, hub *world.Hub) gateway.Handler {
		return GuildHandler(chars, guilds, hub)
	})
	ctx := context.Background()
	aria, _ := f.chars.GetByID(ctx, f.aria)
	qualifyFounder(t, f.chars, aria)
	f.kill(t, f.aria, time.Now())
	if _, err := f.chars.Heal(ctx, f.aria, aria.MaxHP(), aria.MaxHP()); err != nil {
		t.Fatal(err)
	}
	if c, _ := f.chars.GetByID(ctx, f.aria); c.HP <= 0 {
		t.Fatalf("setup: Aria's HP %d after the heal, want above 0 (dead with a full pool)", c.HP)
	}

	f.send(t, f.connA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	gr, err := DecodeGuildResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || gr.Error != guildErrorMessage(guild.ErrCreatorDead) {
		t.Fatalf("a dead founder's create answered %+v (err %v), want the refusal %q (0x4c07)", gr, err, guildErrorMessage(guild.ErrCreatorDead))
	}
	if _, err := guilds.GetByCharacter(ctx, f.aria); !errors.Is(err, guild.ErrNotInGuild) {
		t.Fatalf("a guild was founded by a dead character (err %v)", err)
	}
	f.send(t, f.connA, OpGuildLevel, (&GuildLevelRequest{CharacterName: "Aria", LevelUp: true}).Encode())
	lr, err := DecodeGuildLevelResult(f.read(t, f.connA, f.rA).Data)
	if err != nil || lr.Error == "" || lr.Code != 0x4c07 {
		t.Fatalf("a dead character's level-up answered %+v (err %v), want the refusal with code 0x4c07 ahead of the no-guild 0x4c0d", lr, err)
	}

	f.send(t, f.connA, OpRevive, nil)
	if rr, err := DecodeReviveResult(f.read(t, f.connA, f.rA).Data); err != nil || rr.Error != "" {
		t.Fatalf("OpRevive answered %+v (err %v), want a success", rr, err)
	}
	if p := f.read(t, f.connA, f.rA); p.Opcode != OpCharacterStatsResult {
		t.Fatalf("after the revive result Aria received %#04x, want the stats push", p.Opcode)
	}
	f.send(t, f.connA, OpGuildCreate, (&GuildCreateRequest{CharacterName: "Aria", GuildName: "Silk Legion"}).Encode())
	if gr, err := DecodeGuildResult(f.read(t, f.connA, f.rA).Data); err != nil || gr.Error != "" || gr.GuildID == 0 {
		t.Fatalf("the revived founder's create answered %+v (err %v), want a guild", gr, err)
	}
}

// Round 573: Restored trails FrameRegion as one byte, sent only when true. A
// result that did not restore is byte for byte the round-570 payload (the old
// payload plus the frame), so the flag-off wire and every entry without a
// saved position are unchanged; a restored one is that payload plus 0x01. A
// payload without the byte -- every older server's -- decodes as not
// restored. NEGATIVE: before round 573 EnterWorldResult has no Restored and
// this does not compile.
func TestEnterWorldResultCarriesRestoredAfterTheFrame(t *testing.T) {
	others := []EntitySnapshot{{CharacterID: 1, Name: "Bram", X: 4, Y: 5, Z: 6, Gender: character.GenderChinaMan}}
	ew := &EnterWorldResult{OK: true, Zone: "jangan", X: 100, Y: 0, Z: -200, Gender: character.GenderChinaMan,
		HP: 73, MaxHP: 100, Others: others, FrameRegion: "97/168"}
	legacy := encodeOKReason(true, "")
	legacy = append(legacy, encodeStrings(ew.Zone)...)
	legacy = append(legacy, encodeFloat32(ew.X)...)
	legacy = append(legacy, encodeFloat32(ew.Y)...)
	legacy = append(legacy, encodeFloat32(ew.Z)...)
	legacy = append(legacy, encodeStrings(ew.Gender)...)
	legacy = append(legacy, 73, 0, 0, 0, 100, 0, 0, 0)
	legacy = append(legacy, legacyWorldTail(others)...)
	framed := append(append([]byte{}, legacy...), encodeStrings("97/168")...)

	if got := ew.Encode(); !bytes.Equal(got, framed) {
		t.Fatalf("a result that did not restore is not the round-570 payload:\n got  % x\n want % x", got, framed)
	}
	ew.Restored = true
	restored := ew.Encode()
	if !bytes.Equal(restored, append(append([]byte{}, framed...), 1)) {
		t.Fatalf("a restored result is not the round-570 payload plus 0x01:\n got  % x\n want % x 01", restored, framed)
	}

	got, err := DecodeEnterWorldResult(restored)
	if err != nil || !got.Restored || got.FrameRegion != "97/168" || got.X != 100 || got.Z != -200 || len(got.Others) != 1 {
		t.Fatalf("decoding a restored result: %+v (err=%v), want Restored at (100, -200) in 97/168 with one other", got, err)
	}
	for name, payload := range map[string][]byte{"the round-570 payload": framed, "an older server's payload": legacy} {
		got, err := DecodeEnterWorldResult(payload)
		if err != nil || got.Restored {
			t.Fatalf("%s decodes Restored=%v (err=%v), want false", name, got.Restored, err)
		}
	}
}

// positionWorld is alice/Aria over in-memory stores, served with the world
// handlers and the disconnect handler that saves where a character left
// (round 573). Every enter dials a fresh connection, as a client that
// reconnects does. left receives once each time the disconnect handler has
// returned, so a test reads the store only after any save it made.
type positionWorld struct {
	chars *character.MemStore
	hub   *world.Hub
	addr  string
	aria  int64
	f     *deadWorldFixture // its read/send/login helpers need no state
	left  chan struct{}
}

func startPositionWorld(t *testing.T) *positionWorld {
	t.Helper()
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	chars := character.NewMemStore()
	aria, err := chars.Create(ctx, 1, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	hub := world.NewHub()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	left := make(chan struct{}, 8)
	disconnect := WorldDisconnectHandler(hub, chars)
	srv := &gateway.Server{Addr: addr, Handle: gateway.Chain(LoginHandler(accounts), WorldHandler(chars, nil, hub)),
		OnDisconnect: func(sess *gateway.Session) {
			disconnect(sess)
			left <- struct{}{}
		}}
	srvCtx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go srv.ListenAndServe(srvCtx)
	return &positionWorld{chars: chars, hub: hub, addr: addr, aria: aria.ID, f: &deadWorldFixture{}, left: left}
}

// enter signs alice in on a new connection and enters Aria.
func (w *positionWorld) enter(t *testing.T) (net.Conn, *bufio.Reader, *EnterWorldResult) {
	t.Helper()
	conn := dialTestServer(t, w.addr)
	t.Cleanup(func() { conn.Close() })
	r := bufio.NewReader(conn)
	return conn, r, w.f.login(t, conn, r, "alice", "hunter2", "Aria")
}

// moveTo sends one OpMove and waits until the hub holds it, so a disconnect
// that follows cannot overtake it.
func (w *positionWorld) moveTo(t *testing.T, conn net.Conn, x, y, z float32) {
	t.Helper()
	w.f.send(t, conn, OpMove, (&MoveRequest{X: x, Y: y, Z: z}).Encode())
	want := world.Position{X: float64(x), Y: float64(y), Z: float64(z)}
	w.until(t, "the hub holds the move", func() bool {
		e, ok := w.hub.EntityByCharacterID(w.aria)
		return ok && e.Pos == want
	})
}

// leave closes conn and waits until the disconnect handler has returned, any
// save it made included.
func (w *positionWorld) leave(t *testing.T, conn net.Conn) {
	t.Helper()
	conn.Close()
	select {
	case <-w.left:
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the disconnect handler")
	}
	if _, ok := w.hub.EntityByCharacterID(w.aria); ok {
		t.Fatal("Aria is still in the hub after the disconnect handler returned")
	}
}

func (w *positionWorld) until(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting: %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func (w *positionWorld) saved(t *testing.T) *character.Character {
	t.Helper()
	c, err := w.chars.GetByID(context.Background(), w.aria)
	if err != nil {
		t.Fatalf("GetByID: %v", err)
	}
	return c
}

// With -persist-position on, a character re-enters where it left off (round
// 573): enter, walk to (100, 0, -200), disconnect, enter again -- the second
// OpEnterWorldResult answers (100, 0, -200) in the saved zone and frame with
// Restored set, where the first answered spawnPos. A zone change is saved at
// once and a re-entry after it answers the new zone's label and frame.
func TestPersistPositionReentersWhereTheCharacterLeft(t *testing.T) {
	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	w := startPositionWorld(t)

	conn, r, first := w.enter(t)
	if first.Restored || first.Zone != spawnZone || first.X != float32(spawnPos.X) || first.Z != float32(spawnPos.Z) {
		t.Fatalf("the first entry, with nothing saved: %+v, want %s at spawnPos, not restored", first, spawnZone)
	}
	w.moveTo(t, conn, 100, 0, -200)
	w.leave(t, conn)
	if c := w.saved(t); c.Zone != "jangan" || c.Frame != frameFor("jangan") || c.PosX != 100 || c.PosY != 0 || c.PosZ != -200 {
		t.Fatalf("saved on disconnect: zone %q frame %q at (%g, %g, %g), want jangan %s at (100, 0, -200)",
			c.Zone, c.Frame, c.PosX, c.PosY, c.PosZ, frameFor("jangan"))
	}

	conn, r, again := w.enter(t)
	if !again.Restored || again.Zone != "jangan" || again.FrameRegion != frameFor("jangan") ||
		again.X != 100 || again.Y != 0 || again.Z != -200 {
		t.Fatalf("the second entry: zone %q frame %q at (%g, %g, %g) restored %v, want jangan %s at (100, 0, -200) restored",
			again.Zone, again.FrameRegion, again.X, again.Y, again.Z, again.Restored, frameFor("jangan"))
	}
	if e, ok := w.hub.EntityByCharacterID(w.aria); !ok || e.Zone != "jangan" || e.Pos != (world.Position{X: 100, Y: 0, Z: -200}) {
		t.Fatalf("the hub keeps the re-entered Aria as %+v (in world %v), want bucket jangan at (100, 0, -200)", e, ok)
	}

	// A zone change is saved at once, at the arrival: Donwhang's own frame
	// and spawnPos with -single-frame off.
	if czr := changeZone(t, w.f, conn, r, "donwhang"); !czr.OK {
		t.Fatalf("change to donwhang: %+v", czr)
	}
	if c := w.saved(t); c.Zone != "donwhang" || c.Frame != frameFor("donwhang") || c.PosX != spawnPos.X || c.PosZ != spawnPos.Z {
		t.Fatalf("saved on the zone change: zone %q frame %q at (%g, %g), want donwhang %s at spawnPos",
			c.Zone, c.Frame, c.PosX, c.PosZ, frameFor("donwhang"))
	}
	w.moveTo(t, conn, 250, 3, 400)
	w.leave(t, conn)
	_, _, third := w.enter(t)
	if !third.Restored || third.Zone != "donwhang" || third.FrameRegion != frameFor("donwhang") || third.X != 250 || third.Y != 3 || third.Z != 400 {
		t.Fatalf("the entry after Donwhang: %+v, want donwhang in %s at (250, 3, 400) restored", third, frameFor("donwhang"))
	}
}

// NEGATIVE, and today's behaviour with the flag off (the default): nothing is
// saved, and the second entry answers spawnPos in spawnZone, not restored --
// the same before and after round 573.
func TestPersistPositionOffEntersAtTheSpawn(t *testing.T) {
	SetPersistPosition(false)
	w := startPositionWorld(t)
	conn, _, _ := w.enter(t)
	w.moveTo(t, conn, 100, 0, -200)
	w.leave(t, conn)
	if c := w.saved(t); c.Zone != "" || c.Frame != "" || c.PosX != 0 || c.PosZ != 0 {
		t.Fatalf("with the flag off a position was saved: zone %q frame %q at (%g, %g)", c.Zone, c.Frame, c.PosX, c.PosZ)
	}
	_, _, again := w.enter(t)
	if again.Restored || again.Zone != spawnZone || again.X != float32(spawnPos.X) || again.Y != float32(spawnPos.Y) || again.Z != float32(spawnPos.Z) {
		t.Fatalf("with the flag off the second entry: %+v, want %s at spawnPos, not restored", again, spawnZone)
	}
}

// A position saved in one frame is named in the frame the zone has at entry
// (round 573, inFrame): worldmap.Rebase, the region-delta form of
// worldmap.ToWorld. Region y drives world X, region x drives world Z, Z
// mirrored (AGENTS.md): 98/157 is 11 regions DOWN in y from 97/168 (X
// negative) and one UP in x (Z negative, the mirror), so a point saved under
// 98/157 and read under 97/168 moves by ToWorld(98, 157, 960, 960, 97, 168) --
// derived here, never typed from prose -- and stands at spawnPos's height.
// Under -single-frame a Donwhang save in its own frame 102/153 is named in
// 97/168's the same way, in the one world's bucket. A frame that cannot be
// converted (saved "" for a label that has one today) enters at the spawn.
func TestPersistPositionNamesASavedPointInTodaysFrame(t *testing.T) {
	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false); SetSingleFrame(false) })
	ctx := context.Background()
	w := startPositionWorld(t)

	dx, dz := worldmap.ToWorld(98, 157, 960, 960, 97, 168)
	if dx >= 0 || dz >= 0 {
		t.Fatalf("the sign rule: 98/157's middle in 97/168's frame is (%g, %g), want X < 0 (lower region y) and Z < 0 (higher region x, mirrored)", dx, dz)
	}
	if err := w.chars.SavePosition(ctx, w.aria, "jangan", "98/157", 100, 7, -200); err != nil {
		t.Fatal(err)
	}
	conn, _, got := w.enter(t)
	if !got.Restored || got.Zone != "jangan" || got.FrameRegion != "97/168" || !near(got.X, got.Z, 100+dx, -200+dz) || got.Y != float32(spawnPos.Y) {
		t.Fatalf("saved under 98/157, read under 97/168: %+v, want jangan in 97/168 at (%g, %g, %g) restored",
			got, 100+dx, spawnPos.Y, -200+dz)
	}
	w.leave(t, conn)

	SetSingleFrame(true)
	ddx, ddz := worldmap.ToWorld(102, 153, 960, 960, 97, 168)
	if err := w.chars.SavePosition(ctx, w.aria, "donwhang", "102/153", 30, 5, -40); err != nil {
		t.Fatal(err)
	}
	conn, _, got = w.enter(t)
	if !got.Restored || got.Zone != "donwhang" || got.FrameRegion != "97/168" || !near(got.X, got.Z, 30+ddx, -40+ddz) || got.Y != float32(spawnPos.Y) {
		t.Fatalf("a Donwhang save read under -single-frame: %+v, want donwhang in 97/168 at (%g, %g, %g) restored",
			got, 30+ddx, spawnPos.Y, -40+ddz)
	}
	if e, ok := w.hub.EntityByCharacterID(w.aria); !ok || e.Zone != worldmap.WorldBucket {
		t.Fatalf("under -single-frame the restored Aria is kept in %q (in world %v), want %q", e.Zone, ok, worldmap.WorldBucket)
	}
	w.leave(t, conn)
	SetSingleFrame(false)

	if err := w.chars.SavePosition(ctx, w.aria, "jangan", "", 100, 7, -200); err != nil {
		t.Fatal(err)
	}
	_, _, got = w.enter(t)
	if got.Restored || got.Zone != spawnZone || got.X != float32(spawnPos.X) || got.Z != float32(spawnPos.Z) {
		t.Fatalf("a save with no frame for a label that has one: %+v, want %s at spawnPos, not restored", got, spawnZone)
	}
}

// The move handler saves a walk at most once every positionSaveInterval
// (round 573): a move inside the interval is not written, one past it is and
// restarts the clock, and with the flag off nothing is written at all.
func TestPersistPositionSavesAWalkEveryInterval(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	c, _ := chars.Create(ctx, 1, "Aria")
	hub := world.NewHub()
	sess := gateway.NewTestSession(1)
	hub.Enter(sess, c.ID, c.Name, c.Level, "jangan", spawnPos)
	move := func(x, z float32) {
		t.Helper()
		if err := handleMove(sess, &proto.Packet{Opcode: OpMove, Data: (&MoveRequest{X: x, Z: z}).Encode()}, hub, chars); err != nil {
			t.Fatalf("handleMove: %v", err)
		}
	}
	savedX := func() float64 {
		got, _ := chars.GetByID(ctx, c.ID)
		return got.PosX
	}

	SetPersistPosition(false)
	rememberPlace(sess, "jangan", "97/168", time.Now().Add(-2*positionSaveInterval))
	move(10, 10)
	if got, _ := chars.GetByID(ctx, c.ID); got.Zone != "" {
		t.Fatalf("with the flag off a move was saved: %+v", got)
	}

	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	rememberPlace(sess, "jangan", "97/168", time.Now())
	move(20, 20)
	if got, _ := chars.GetByID(ctx, c.ID); got.Zone != "" {
		t.Fatalf("a move inside the interval was saved: %+v", got)
	}
	rememberPlace(sess, "jangan", "97/168", time.Now().Add(-positionSaveInterval-time.Second))
	move(30, 30)
	if got, _ := chars.GetByID(ctx, c.ID); got.Zone != "jangan" || got.Frame != "97/168" || got.PosX != 30 || got.PosZ != 30 {
		t.Fatalf("a move past the interval: saved %+v, want jangan 97/168 at (30, 30)", got)
	}
	move(40, 40)
	if savedX() != 30 {
		t.Fatalf("the save did not restart the clock: the next move saved x %g, want 30 kept", savedX())
	}
}

// The gateway runs no OnDisconnect for sessions open when it stops, so
// SaveAllPositions saves everyone still in the world (round 573) -- every
// deploy is such a stop. With the flag off it writes nothing.
func TestSaveAllPositionsSavesEveryoneStillInTheWorld(t *testing.T) {
	ctx := context.Background()
	chars := character.NewMemStore()
	aria, _ := chars.Create(ctx, 1, "Aria")
	bram, _ := chars.Create(ctx, 2, "Bram")
	hub := world.NewHub()
	sa, sb := gateway.NewTestSession(1), gateway.NewTestSession(2)
	hub.Enter(sa, aria.ID, aria.Name, 1, "jangan", world.Position{X: 1, Y: 2, Z: 3})
	hub.Enter(sb, bram.ID, bram.Name, 1, "donwhang", world.Position{X: 4, Y: 5, Z: 6})
	rememberPlace(sa, "jangan", "97/168", time.Now())
	rememberPlace(sb, "donwhang", "102/153", time.Now())

	SetPersistPosition(false)
	SaveAllPositions(hub, chars)
	if got, _ := chars.GetByID(ctx, aria.ID); got.Zone != "" {
		t.Fatalf("with the flag off SaveAllPositions saved %+v", got)
	}

	SetPersistPosition(true)
	t.Cleanup(func() { SetPersistPosition(false) })
	SaveAllPositions(hub, chars)
	for _, want := range []struct {
		id          int64
		zone, frame string
		pos         world.Position
	}{
		{aria.ID, "jangan", "97/168", world.Position{X: 1, Y: 2, Z: 3}},
		{bram.ID, "donwhang", "102/153", world.Position{X: 4, Y: 5, Z: 6}},
	} {
		got, _ := chars.GetByID(ctx, want.id)
		if got.Zone != want.zone || got.Frame != want.frame || (world.Position{X: got.PosX, Y: got.PosY, Z: got.PosZ}) != want.pos {
			t.Errorf("character %d saved as %q %q at (%g, %g, %g), want %q %q at %+v",
				want.id, got.Zone, got.Frame, got.PosX, got.PosY, got.PosZ, want.zone, want.frame, want.pos)
		}
	}
}
