package relay

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/TheOpenSRO/OpenSRO/server/internal/gateway"
	"github.com/TheOpenSRO/OpenSRO/server/internal/proto"
)

const (
	opEcho     uint16 = 0x0001
	opWhoAmI   uint16 = 0x0002 // answered with the host's name
	opGoTo     uint16 = 0x0003 // payload: the host to re-route to
	opBindMe   uint16 = 0x0004
	opLogout   uint16 = 0x0005
	opAdopted  uint16 = 0x0006 // a host's answer to an adoption: the hand-off it got
	opRecovery uint16 = 0x0007
)

// fakeHost is a world host with a toy handler on a loopback relay listener.
type fakeHost struct {
	name string
	addr string
	srv  *gateway.Server
	stop context.CancelFunc
	mu   sync.Mutex
	got  []string // what it saw, in order
	all  map[*gateway.Session]bool
}

func startHost(t *testing.T, name, secret string, hosts map[string]*fakeHost) *fakeHost {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close()
	h := &fakeHost{name: name, addr: addr, all: map[*gateway.Session]bool{}}
	h.srv = &gateway.Server{Addr: addr, Codec: NewHostCodec(secret),
		Handle: func(ctx context.Context, sess *gateway.Session, p *proto.Packet) error {
			h.mu.Lock()
			h.all[sess] = true
			h.got = append(h.got, string(p.Data))
			h.mu.Unlock()
			switch p.Opcode {
			case OpAdopt:
				var hello Hello
				json.Unmarshal(p.Data, &hello)
				if hello.Recover != nil {
					return sess.Send(&proto.Packet{Opcode: opRecovery, Data: []byte(name)})
				}
				return sess.Send(&proto.Packet{Opcode: opAdopted, Data: hello.Handoff})
			case opEcho:
				return sess.Send(&proto.Packet{Opcode: opEcho, Data: p.Data})
			case opWhoAmI:
				hello, _ := HelloOf(sess)
				return sess.Send(&proto.Packet{Opcode: opWhoAmI, Data: []byte(name + "|" + hello.Client + "|" + sess.RemoteAddr().String())})
			case opBindMe:
				return SendBind(sess, Bind{Account: 1, Username: "u", Char: 42})
			case opGoTo:
				to := hosts[string(p.Data)]
				if err := SendReroute(sess, Reroute{Host: to.name, Addr: to.addr, Handoff: json.RawMessage(`{"from":"` + name + `"}`)}); err != nil {
					return err
				}
				return gateway.ErrEndSession
			case opLogout:
				SendUnbind(sess)
				return gateway.ErrEndSession
			}
			return nil
		}}
	ctx, cancel := context.WithCancel(context.Background())
	h.stop = cancel
	go h.srv.ListenAndServe(ctx)
	for i := 0; i < 100; i++ {
		if c, err := net.Dial("tcp", addr); err == nil {
			c.Close()
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	return h
}

// kill stops the host and drops every stream it has (kill -9).
func (h *fakeHost) kill() {
	h.stop()
	h.mu.Lock()
	defer h.mu.Unlock()
	for s := range h.all {
		s.Close()
	}
}

type client struct {
	t    *testing.T
	conn net.Conn
	r    *bufio.Reader
}

func (c *client) send(op uint16, data string) {
	c.t.Helper()
	if err := writeFrame(c.conn, &proto.Packet{Opcode: op, Data: []byte(data)}); err != nil {
		c.t.Fatal(err)
	}
}

func (c *client) read() (*proto.Packet, error) {
	c.conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	return proto.Read(c.r, nil, nil)
}

func (c *client) expect(op uint16, data string) {
	c.t.Helper()
	p, err := c.read()
	if err != nil {
		c.t.Fatalf("waiting for %#x %q: %v", op, data, err)
	}
	if p.Opcode != op || (data != "*" && string(p.Data) != data) {
		c.t.Fatalf("got %#x %q, want %#x %q", p.Opcode, p.Data, op, data)
	}
}

func TestFrontRelaysReroutesAndRecovers(t *testing.T) {
	const secret = "s3cret"
	hosts := map[string]*fakeHost{}
	home := startHost(t, "home", secret, hosts)
	w1 := startHost(t, "w1", secret, hosts)
	hosts["home"], hosts["w1"] = home, w1
	defer home.stop()
	defer w1.stop()
	f := &Front{Addr: "127.0.0.1:0", Secret: secret, ID: "f1",
		Home: func(context.Context) (string, string, error) { return "home", home.addr, nil }}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go f.Serve(ctx, ln)
	conn, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	c := &client{t: t, conn: conn, r: bufio.NewReader(conn)}

	// Relayed to the open world's host, which sees the player's address.
	c.send(opEcho, "hello")
	c.expect(opEcho, "hello")
	c.send(opWhoAmI, "")
	p, _ := c.read()
	if got := string(p.Data); got[:5] != "home|" || got[5:5+len(conn.LocalAddr().String())] != conn.LocalAddr().String() {
		t.Fatalf("whoami %q (client %s)", got, conn.LocalAddr())
	}
	// A client cannot speak for the front.
	c.send(OpReroute, `{"addr":"`+w1.addr+`"}`)
	c.send(opEcho, "still home")
	c.expect(opEcho, "still home")

	// Bound, then re-routed: the hand-off reaches w1, and what the client
	// sends meanwhile follows it there.
	c.send(opBindMe, "")
	c.send(opGoTo, "w1")
	c.send(opEcho, "after the move")
	c.expect(opAdopted, `{"from":"home"}`)
	c.expect(opEcho, "after the move")
	c.send(opWhoAmI, "")
	c.expect(opWhoAmI, "*")
	if f.Reroutes.Load() != 1 {
		t.Fatalf("reroutes %d", f.Reroutes.Load())
	}

	// w1 dies: the bound character is recovered on the open world's host.
	w1.kill()
	c.expect(opRecovery, "home")
	c.send(opEcho, "back home")
	c.expect(opEcho, "back home")
	if f.Recoveries.Load() != 1 {
		t.Fatalf("recoveries %d", f.Recoveries.Load())
	}

	// A logout unbinds: the stream's end closes the client.
	c.send(opLogout, "")
	if _, err := c.read(); err == nil {
		t.Fatal("the client stayed open after the logout")
	}
}

// A hello with the wrong secret or another version is refused.
func TestHostRefusesABadHello(t *testing.T) {
	hosts := map[string]*fakeHost{}
	h := startHost(t, "home", "right", hosts)
	defer h.stop()
	for _, hello := range []Hello{{Secret: "wrong", Version: Version}, {Secret: "right", Version: "old"}} {
		conn, err := net.Dial("tcp", h.addr)
		if err != nil {
			t.Fatal(err)
		}
		writeFrame(conn, control(OpHello, hello))
		writeFrame(conn, &proto.Packet{Opcode: opEcho, Data: []byte("x")})
		conn.SetReadDeadline(time.Now().Add(2 * time.Second))
		if _, err := proto.Read(bufio.NewReader(conn), nil, nil); err == nil {
			t.Fatalf("hello %+v answered", hello)
		}
		conn.Close()
	}
}
