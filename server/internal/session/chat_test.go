package session

import (
	"bufio"
	"context"
	"net"
	"testing"
	"time"

	"github.com/OpenSRO/srrevamp/server/internal/account"
	"github.com/OpenSRO/srrevamp/server/internal/character"
	"github.com/OpenSRO/srrevamp/server/internal/gateway"
	"github.com/OpenSRO/srrevamp/server/internal/proto"
	"github.com/OpenSRO/srrevamp/server/internal/world"
)

func TestChatMessageRoundTrip(t *testing.T) {
	want := &ChatMessage{SenderName: "Aria", Message: "hello, jangan"}
	got, err := DecodeChatMessage(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChatMessage: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestChatWhisperRequestRoundTrip(t *testing.T) {
	want := &ChatWhisperRequest{TargetName: "Bram", Message: "hey"}
	got, err := DecodeChatWhisperRequest(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChatWhisperRequest: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestChatWhisperResultRoundTrip(t *testing.T) {
	want := &ChatWhisperResult{OK: false, Reason: "player not found"}
	got, err := DecodeChatWhisperResult(want.Encode())
	if err != nil {
		t.Fatalf("DecodeChatWhisperResult: %v", err)
	}
	if *got != *want {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

// TestChatFullFlow logs two accounts in on separate connections, has both
// enter the same zone, confirms a Say broadcasts to both (including the
// sender), then confirms a Whisper delivers only to its target and the
// sender gets an OK ack, and finally that whispering a nonexistent player
// returns a "player not found" ack rather than silently dropping.
func TestChatFullFlow(t *testing.T) {
	ctx := context.Background()
	accounts := account.NewMemStore()
	accounts.Add("alice", "hunter2")
	accounts.Add("bob", "hunter3")
	chars := character.NewMemStore()
	chars.Create(ctx, 1, "Aria")
	chars.Create(ctx, 2, "Bram")

	hub := world.NewHub()
	handle := gateway.Chain(LoginHandler(accounts), WorldHandler(chars, hub), ChatHandler(hub))

	addr, cleanup := startTestServer(t, handle)
	defer cleanup()

	connA := dialTestServer(t, addr)
	defer connA.Close()
	rA := bufio.NewReader(connA)
	connB := dialTestServer(t, addr)
	defer connB.Close()
	rB := bufio.NewReader(connB)

	doSend := func(c net.Conn, r *bufio.Reader, opcode uint16, data []byte) *proto.Packet {
		if err := proto.Write(c, &proto.Packet{Opcode: opcode, Data: data}); err != nil {
			t.Fatalf("Write: %v", err)
		}
		c.SetReadDeadline(time.Now().Add(2 * time.Second))
		resp, err := proto.Read(r)
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
	if er, err := DecodeEnterWorldResult(resp.Data); err != nil || !er.OK {
		t.Fatalf("aria enter world failed: err=%v result=%+v", err, er)
	}
	resp = doSend(connB, rB, OpEnterWorld, (&EnterWorldRequest{CharacterName: "Bram"}).Encode())
	if er, err := DecodeEnterWorldResult(resp.Data); err != nil || !er.OK {
		t.Fatalf("bram enter world failed: err=%v result=%+v", err, er)
	}
	// Aria was already in the zone when Bram entered, so she gets an
	// EntityEntered broadcast for him -- drain it before it interferes with
	// the chat assertions below.
	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := proto.Read(rA); err != nil {
		t.Fatalf("draining EntityEntered: %v", err)
	}

	if err := proto.Write(connA, &proto.Packet{Opcode: OpChatSay, Data: (&ChatSayRequest{Message: "hello, jangan"}).Encode()}); err != nil {
		t.Fatalf("Write OpChatSay: %v", err)
	}

	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	echoed, err := proto.Read(rA)
	if err != nil {
		t.Fatalf("reading own ChatMessage echo: %v", err)
	}
	if echoed.Opcode != OpChatMessage {
		t.Fatalf("got opcode 0x%04x, want OpChatMessage", echoed.Opcode)
	}
	if cm, err := DecodeChatMessage(echoed.Data); err != nil || cm.SenderName != "Aria" || cm.Message != "hello, jangan" {
		t.Fatalf("unexpected echoed message: %+v (err=%v)", cm, err)
	}

	connB.SetReadDeadline(time.Now().Add(2 * time.Second))
	heard, err := proto.Read(rB)
	if err != nil {
		t.Fatalf("reading ChatMessage on B: %v", err)
	}
	if heard.Opcode != OpChatMessage {
		t.Fatalf("got opcode 0x%04x, want OpChatMessage", heard.Opcode)
	}
	if cm, err := DecodeChatMessage(heard.Data); err != nil || cm.SenderName != "Aria" || cm.Message != "hello, jangan" {
		t.Fatalf("unexpected message on B: %+v (err=%v)", cm, err)
	}

	// Whisper from Bram to Aria: Bram gets an OK ack, Aria gets the
	// whisper message; Aria should NOT get a second broadcast.
	resp = doSend(connB, rB, OpChatWhisper, (&ChatWhisperRequest{TargetName: "Aria", Message: "psst"}).Encode())
	if wr, err := DecodeChatWhisperResult(resp.Data); err != nil || !wr.OK {
		t.Fatalf("whisper ack failed: err=%v result=%+v", err, wr)
	}

	connA.SetReadDeadline(time.Now().Add(2 * time.Second))
	whispered, err := proto.Read(rA)
	if err != nil {
		t.Fatalf("reading ChatWhisperMessage on A: %v", err)
	}
	if whispered.Opcode != OpChatWhisperMessage {
		t.Fatalf("got opcode 0x%04x, want OpChatWhisperMessage", whispered.Opcode)
	}
	if cm, err := DecodeChatMessage(whispered.Data); err != nil || cm.SenderName != "Bram" || cm.Message != "psst" {
		t.Fatalf("unexpected whisper on A: %+v (err=%v)", cm, err)
	}

	// Whispering a nonexistent player should ack with a clear failure, not
	// silently drop.
	resp = doSend(connB, rB, OpChatWhisper, (&ChatWhisperRequest{TargetName: "Ghost", Message: "hello?"}).Encode())
	wr, err := DecodeChatWhisperResult(resp.Data)
	if err != nil || wr.OK || wr.Reason != "player not found" {
		t.Fatalf("whisper to nonexistent player: err=%v result=%+v", err, wr)
	}
}
