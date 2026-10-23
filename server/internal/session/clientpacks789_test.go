package session

import (
	"bufio"
	"context"
	"net"
	"reflect"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/clientpacks"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

// Round 789, lane U (OURS): the packs a client needs, asked before login on
// a connection of the client's own, like the theme.

func testManifest() clientpacks.Manifest {
	m := clientpacks.Manifest{Required: true, HTTPPort: 15780}
	p := clientpacks.Pack{Name: "z_akatsuki.pk3", Size: 590825}
	p.SHA256[0] = 0xab
	m.Packs = append(m.Packs, p)
	return m
}

func TestClientPacksHandlerOnAFreshSession(t *testing.T) {
	h, err := ClientPacksHandler(testManifest())
	if err != nil {
		t.Fatal(err)
	}
	reached := make(chan uint16, 16)
	probe := func(_ context.Context, _ *gateway.Session, p *proto.Packet) error {
		reached <- p.Opcode
		return nil
	}
	addr := startThemeServer(t, gateway.Chain(h, LoginHandler(account.NewMemStore()), probe))
	conn := dialTheme(t, addr)
	r := bufio.NewReader(conn)
	if err := proto.Write(conn, &proto.Packet{Opcode: OpFrontEndThemeRequest + 0x7000}, nil, nil); err != nil {
		t.Fatal(err)
	}
	if err := proto.Write(conn, &proto.Packet{Opcode: OpClientPacksRequest}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(r, nil, nil)
	if err != nil {
		t.Fatalf("no reply: %v", err)
	}
	if p.Opcode != OpClientPacks {
		t.Fatalf("reply %#04x", p.Opcode)
	}
	got, err := clientpacks.Decode(p.Data)
	if err != nil || !reflect.DeepEqual(got, testManifest()) {
		t.Fatalf("served %+v (%v)", got, err)
	}
	select {
	case op := <-reached:
		if op == OpClientPacksRequest {
			t.Fatal("the request went down the chain")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("the other packet never reached the chain's end")
	}
	// One answer, then the unauthenticated connection ends.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if p, err := proto.Read(r, nil, nil); err == nil {
		t.Errorf("an extra frame %#04x", p.Opcode)
	} else if ne, ok := err.(net.Error); ok && ne.Timeout() {
		t.Error("the connection stayed open after the answer")
	}
}

// A server without -client-packs answers too: no packs named, so a new
// client keeps its own set at once instead of waiting out its timeout.
func TestClientPacksHandlerWithoutPacks(t *testing.T) {
	h, err := ClientPacksHandler(clientpacks.Manifest{})
	if err != nil {
		t.Fatal(err)
	}
	addr := startThemeServer(t, h)
	conn := dialTheme(t, addr)
	if err := proto.Write(conn, &proto.Packet{Opcode: OpClientPacksRequest}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(bufio.NewReader(conn), nil, nil)
	if err != nil || p.Opcode != OpClientPacks || len(p.Data) != 5 {
		t.Fatalf("%+v %v", p, err)
	}
	if m, err := clientpacks.Decode(p.Data); err != nil || m.Required {
		t.Fatalf("%+v %v", m, err)
	}
}

func TestClientPacksHandlerRefusesABadManifest(t *testing.T) {
	m := testManifest()
	m.Packs[0].Name = "../x.pk3"
	if _, err := ClientPacksHandler(m); err == nil {
		t.Fatal("a bad name was accepted")
	}
}

func TestClientPacksOpcodesAreUnique(t *testing.T) {
	if OpClientPacksRequest != 0x0009 || OpClientPacks != 0x000A {
		t.Fatalf("moved: %#04x/%#04x; the client sends 0x0009 and reads 0x000A", OpClientPacksRequest, OpClientPacks)
	}
	for _, op := range []uint16{OpLogin, OpLoginResult, OpRegister, OpRegisterResult, OpFrontEndThemeRequest, OpFrontEndTheme,
		OpServerStatusRequest, OpServerStatus, legacyOpCharacterList} {
		if op == OpClientPacksRequest || op == OpClientPacks {
			t.Errorf("opcode %#04x collides with the client packs'", op)
		}
	}
}
