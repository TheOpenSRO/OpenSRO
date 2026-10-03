package main

import (
	"bufio"
	"bytes"
	"encoding/binary"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// runServerEnv makes this test binary run the real server's main() instead
// of its tests: TestFrontEndThemeServedByTheRealServer starts a copy of
// itself with it set, so what answers is the server's own boot -- its flags,
// its environment, the handler chain main builds -- not a chain the test
// assembled.
const runServerEnv = "OPENSRO_TEST_RUN_SERVER_MAIN"

func TestMain(m *testing.M) {
	if os.Getenv(runServerEnv) == "1" {
		os.Args = append([]string{os.Args[0]}, strings.Fields(os.Getenv(runServerEnv+"_ARGS"))...)
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// lockedBuffer collects the child server's log while the test reads it.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// Round 678 (OURS): the server answers a front-end theme request on a fresh
// connection, before login, with the theme its OPENSRO_LOGIN_* settings
// give -- an unsafe name refused with a WARN and served empty -- within the
// 1.5 s the client waits. Before round 678 nothing answers opcode 0x0005 and
// the read times out. The opcodes are literals so the test also builds
// against a server that has never heard of them.
func TestFrontEndThemeServedByTheRealServer(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()

	cmd := exec.Command(os.Args[0])
	for _, kv := range os.Environ() { // nothing of the developer's own server settings
		if !strings.HasPrefix(kv, "OPENSRO_") {
			cmd.Env = append(cmd.Env, kv)
		}
	}
	cmd.Env = append(cmd.Env,
		runServerEnv+"=1",
		runServerEnv+"_ARGS=-in-memory -addr "+addr,
		"OPENSRO_LOGIN_INTRO=roc",
		"OPENSRO_LOGIN_BGM=../../evil.ogg",
		"OPENSRO_LOGIN_LOGO=mylogo.png",
		"OPENSRO_LOGIN_COPYRIGHT=(c) 2026 Our Server <test>",
		"OPENSRO_LOGIN_BAND_TOP=top_band.png",
		`OPENSRO_LOGIN_BAND_BOTTOM=C:\bottom.png`,
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

	var conn net.Conn
	for deadline := time.Now().Add(60 * time.Second); ; {
		if conn, err = net.DialTimeout("tcp", addr, 200*time.Millisecond); err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the server never listened on %s: %v", addr, err)
		}
		time.Sleep(50 * time.Millisecond)
	}
	defer conn.Close()

	// The first and only thing this connection sends.
	if err := proto.Write(conn, &proto.Packet{Opcode: 0x0005}, nil, nil); err != nil {
		t.Fatal(err)
	}
	conn.SetReadDeadline(time.Now().Add(1500 * time.Millisecond))
	p, err := proto.Read(bufio.NewReader(conn), nil, nil)
	if err != nil {
		t.Fatalf("no reply to the front-end theme request (opcode 0x0005) within the client's 1.5 s: %v", err)
	}
	if p.Opcode != 0x0006 {
		t.Fatalf("reply opcode %#04x, want the front-end theme 0x0006", p.Opcode)
	}
	if len(p.Data) < 2 || int(binary.LittleEndian.Uint16(p.Data)) != len(p.Data)-2 {
		t.Fatalf("payload %q: the length prefix does not match", p.Data)
	}
	want := `{"v":1,"intro":"roc","bgm":"","logo":"mylogo.png","copyright":"(c) 2026 Our Server <test>",` +
		`"band_top":"top_band.png","band_bottom":"","charselect":null,"create":null}`
	if got := string(p.Data[2:]); got != want {
		t.Errorf("served\n %s\nwant\n %s", got, want)
	}
	var obj map[string]any
	if err := json.Unmarshal(p.Data[2:], &obj); err != nil {
		t.Errorf("the theme is not JSON: %v", err)
	}

	// The startup log names what it refused and what it serves.
	log := out.String()
	for _, line := range []string{
		`level=WARN msg="front-end bgm \"../../evil.ogg\" is not a valid music file name`,
		`level=WARN msg="front-end band_bottom \"C:\\\\bottom.png\" is not a valid image file name`,
		`level=INFO msg="front-end theme" intro=roc bgm="" logo=mylogo.png copyright="(c) 2026 Our Server <test>" band_top=top_band.png band_bottom=""`,
	} {
		if !strings.Contains(log, line) {
			t.Errorf("the server log has no line containing\n %s", line)
		}
	}
}

func tail(s string, n int) string {
	lines := strings.Split(strings.TrimRight(s, "\n"), "\n")
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n")
}
