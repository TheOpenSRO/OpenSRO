package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// Round 679 (OURS): the real server answers the server list's status
// request on a fresh connection, before login: version 1, the characters in
// the world (none), its -max-players and the state byte -- 0, retail's
// "Check", under -inspection (both given as OPENSRO_MAX_PLAYERS and
// OPENSRO_INSPECTION) -- and under inspection a login is refused with
// retail's inspection message. Before round 679 nothing answers opcode 0x0007
// and the read times out. The opcodes are literals so the test also builds
// against a server that has never heard of them.
func TestServerStatusServedByTheRealServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()

	cmd := exec.Command(os.Args[0])
	for _, kv := range os.Environ() {
		if !strings.HasPrefix(kv, "OPENSRO_") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	cmd.Env = append(cmd.Env,
		runServerEnv+"=1",
		runServerEnv+"_ARGS=-in-memory -addr "+addr,
		// Through the environment, so a server without the flags still boots
		// and the missing answer is what fails (round 679's negative).
		"OPENSRO_MAX_PLAYERS=50",
		"OPENSRO_INSPECTION=1",
	)
	var out lockedBuffer
	cmd.Stdout, cmd.Stderr = &out, &out
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		cmd.Process.Kill()
		cmd.Wait()
		if t.Failed() {
			t.Logf("server log (tail):\n%s", tail(out.String(), 40))
		}
	})
	dial := func() net.Conn {
		t.Helper()
		for deadline := time.Now().Add(60 * time.Second); ; {
			conn, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
			if err == nil {
				t.Cleanup(func() { conn.Close() })
				return conn
			}
			if time.Now().After(deadline) {
				t.Fatalf("the server never listened on %s: %v", addr, err)
			}
			time.Sleep(50 * time.Millisecond)
		}
	}

	conn := dial()
	if err := proto.Write(conn, &proto.Packet{Opcode: 0x0007}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err := proto.Read(bufio.NewReader(conn), nil, nil)
	if err != nil {
		t.Fatalf("no reply to the server status request (opcode 0x0007) within the client's 2 s: %v", err)
	}
	if p.Opcode != 0x0008 {
		t.Fatalf("reply opcode %#04x, want the server status 0x0008", p.Opcode)
	}
	if want := []byte{1, 0, 0, 50, 0, 0}; !bytes.Equal(p.Data, want) {
		t.Errorf("status % x, want % x (version 1, 0 in the world, max 50, state 0 = Check)", p.Data, want)
	}

	// A login under inspection: refused with retail's words. Round 788: the
	// password is checked first, as retail's certify job runs before
	// GlobalManager's inspection refusal, so the account is registered
	// (OpRegister 0x0003, the same two strings) and the right password sent.
	conn = dial()
	user := []byte("someone")
	pass := []byte("secret")
	payload := binary.LittleEndian.AppendUint16(nil, uint16(len(user)))
	payload = append(payload, user...)
	payload = binary.LittleEndian.AppendUint16(payload, uint16(len(pass)))
	payload = append(payload, pass...)
	rd := bufio.NewReader(conn)
	if err := proto.Write(conn, &proto.Packet{Opcode: 0x0003, Data: payload}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if p, err = proto.Read(rd, nil, nil); err != nil || p.Opcode != 0x0004 || len(p.Data) < 1 || p.Data[0] != 1 {
		t.Fatalf("registering: %v %+v", err, p)
	}
	if err := proto.Write(conn, &proto.Packet{Opcode: 0x0001, Data: payload}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	p, err = proto.Read(rd, nil, nil)
	if err != nil {
		t.Fatalf("no login reply: %v", err)
	}
	if p.Opcode != 0x0002 || len(p.Data) < 1 || p.Data[0] != 0 ||
		!strings.Contains(string(p.Data), "Cannot connect to the server because the server is now in inspection.") {
		t.Errorf("login under inspection: opcode %#04x payload %q, want a refusal with retail's inspection message", p.Opcode, p.Data)
	}
	if log := out.String(); !strings.Contains(log, "under inspection (-inspection)") || !strings.Contains(log, "max_players=50") {
		t.Errorf("the startup log does not say the capacity and the inspection")
	}
}
