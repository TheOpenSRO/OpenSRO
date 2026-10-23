package session

import (
	"bufio"
	"bytes"
	"context"
	"net"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/account"
	"github.com/TheOpenSRO/OpenSRO/server/internal/character"
	"github.com/TheOpenSRO/OpenSRO/server/internal/equipment"
	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/inventory"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
	"github.com/TheOpenSRO/OpenSRO/server/internal/world"
)

// Round 786: the Auto potion window's settings. 0x7158 type 2 is stored as
// it came (FUN_00407ee0 checks nothing), and the load answers the seven bytes
// -- zeros before any save -- on OpAutoPotionConfig. A quick-slot type (0, 1)
// and a short message are dropped.
func TestRound786AutoPotionSettingsSaveAndLoad(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	chars := character.NewMemStore()
	eq := equipment.NewMemStore(inventory.NewMemStore(nil))
	if _, err := accounts.Register(ctx, "alice", "pw"); err != nil {
		t.Fatalf("Register: %v", err)
	}
	acct, _ := accounts.Authenticate(ctx, "alice", "pw")
	c, err := chars.Create(ctx, acct.ID, "Aria")
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandlerWithHook(chars, eq, hub, nil, nil), AutoPotionHandler(chars, hub, nil))
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv := &gateway.Server{Addr: addr, Handle: handle, OnDisconnect: WorldDisconnectHandler(hub, nil)}
	srvCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go srv.ListenAndServe(srvCtx)
	conn := dialTestServer(t, addr)
	defer conn.Close()
	r := bufio.NewReader(conn)
	write := func(op uint16, data []byte) {
		t.Helper()
		if err := proto.Write(conn, &proto.Packet{Opcode: op, Data: data}, nil, nil); err != nil {
			t.Fatalf("Write: %v", err)
		}
	}
	read := func() *proto.Packet {
		t.Helper()
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		p, err := proto.Read(r, nil, nil)
		if err != nil {
			t.Fatalf("Read: %v", err)
		}
		return p
	}
	write(OpLogin, (&LoginRequest{Username: "alice", Password: "pw"}).Encode())
	read()
	write(OpEnterWorld, (&EnterWorldRequest{CharacterName: "Aria"}).Encode())
	if p := read(); p.Opcode != OpEnterWorldResult {
		t.Fatalf("got %#x, want the enter result", p.Opcode)
	}
	load := func() []byte {
		t.Helper()
		write(OpAutoPotionLoad, nil)
		for i := 0; i < 8; i++ {
			if p := read(); p.Opcode == OpAutoPotionConfig {
				return p.Data
			}
		}
		t.Fatal("no OpAutoPotionConfig")
		return nil
	}
	if got := load(); !bytes.Equal(got, make([]byte, 7)) {
		t.Fatalf("before any save: %x, want seven zeros", got)
	}
	want := []byte{0x11, 0xb2, 0x2a, 0xa8, 0x13, 0x00, 0x8a}
	write(OpAutoPotionSave, append([]byte{1}, want...))     // a quick-slot type: dropped
	write(OpAutoPotionSave, append([]byte{2}, want[:5]...)) // short: dropped
	if got := load(); !bytes.Equal(got, make([]byte, 7)) {
		t.Fatalf("after a type-1 and a short save: %x, want seven zeros", got)
	}
	write(OpAutoPotionSave, append([]byte{2}, want...))
	if got := load(); !bytes.Equal(got, want) {
		t.Fatalf("after the save: %x, want %x", got, want)
	}
	if stored, _ := chars.AutoPotion(ctx, c.ID); !bytes.Equal(stored, want) {
		t.Fatalf("stored %x, want %x", stored, want)
	}
}
