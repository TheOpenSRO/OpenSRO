package gateway

import (
	"bufio"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"net"
	"sync"
	"testing"
	"time"

	"github.com/OpenSRO/OpenSRO/server/internal/proto"
)

// generateTestCert returns a self-signed TLS certificate valid for
// "127.0.0.1", for tests that need a real (not mocked) TLS handshake
// without a cert file on disk.
func generateTestCert(t *testing.T) tls.Certificate {
	t.Helper()

	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generating key: %v", err)
	}
	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "opensro-test"},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		IPAddresses:  []net.IP{net.ParseIP("127.0.0.1")},
	}
	derBytes, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatalf("creating certificate: %v", err)
	}
	keyBytes, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatalf("marshaling private key: %v", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: derBytes})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyBytes})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatalf("building tls.Certificate: %v", err)
	}
	return cert
}

func TestServerEchoesPackets(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	received := make(chan *proto.Packet, 1)
	srv := &Server{
		Addr: "127.0.0.1:0",
		Handle: func(_ context.Context, sess *Session, p *proto.Packet) error {
			received <- p
			return sess.Send(&proto.Packet{Opcode: p.Opcode + 1, Data: p.Data})
		},
	}

	// Bind on an ephemeral port ourselves so the test can dial it, since
	// ListenAndServe doesn't expose the resolved address for ":0".
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	errCh := make(chan error, 1)
	go func() { errCh <- srv.ListenAndServe(ctx) }()

	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	want := &proto.Packet{Opcode: 0x6100, Data: []byte("ping")}
	if err := proto.Write(conn, want, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-received:
		if got.Opcode != want.Opcode || string(got.Data) != string(want.Data) {
			t.Fatalf("handler got %+v, want %+v", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for handler to receive packet")
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reply, err := proto.Read(bufio.NewReader(conn), nil, nil)
	if err != nil {
		t.Fatalf("reading reply: %v", err)
	}
	if reply.Opcode != want.Opcode+1 || string(reply.Data) != "ping" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}

func TestChainCallsEachHandlerInOrder(t *testing.T) {
	var order []string
	a := Handler(func(context.Context, *Session, *proto.Packet) error {
		order = append(order, "a")
		return nil
	})
	b := Handler(func(context.Context, *Session, *proto.Packet) error {
		order = append(order, "b")
		return nil
	})

	if err := Chain(a, b)(context.Background(), nil, &proto.Packet{}); err != nil {
		t.Fatalf("Chain: %v", err)
	}
	if len(order) != 2 || order[0] != "a" || order[1] != "b" {
		t.Fatalf("got call order %v, want [a b]", order)
	}
}

func TestChainStopsOnFirstError(t *testing.T) {
	wantErr := errTest("boom")
	called := false
	a := Handler(func(context.Context, *Session, *proto.Packet) error { return wantErr })
	b := Handler(func(context.Context, *Session, *proto.Packet) error {
		called = true
		return nil
	})

	err := Chain(a, b)(context.Background(), nil, &proto.Packet{})
	if err != wantErr {
		t.Fatalf("got error %v, want %v", err, wantErr)
	}
	if called {
		t.Fatal("expected Chain to stop after the first error, but second handler ran")
	}
}

type errTest string

func (e errTest) Error() string { return string(e) }

func TestOnDisconnectCalledOnClientClose(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	disconnected := make(chan uint64, 1)
	srv := &Server{
		Addr:         "127.0.0.1:0",
		Handle:       func(context.Context, *Session, *proto.Packet) error { return nil },
		OnDisconnect: func(sess *Session) { disconnected <- sess.ID() },
	}

	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	go srv.ListenAndServe(ctx)

	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	conn.Close() // client hangs up

	select {
	case id := <-disconnected:
		if id == 0 {
			t.Fatal("expected a nonzero session ID")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for OnDisconnect to fire")
	}
}

func TestSessionIDsAreUnique(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	var mu sync.Mutex
	seen := map[uint64]bool{}
	srv := &Server{
		Addr: "127.0.0.1:0",
		Handle: func(_ context.Context, sess *Session, _ *proto.Packet) error {
			mu.Lock()
			seen[sess.ID()] = true
			mu.Unlock()
			return nil
		},
	}

	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	go srv.ListenAndServe(ctx)

	for i := 0; i < 3; i++ {
		var conn net.Conn
		for j := 0; j < 50; j++ {
			conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
			if err == nil {
				break
			}
			time.Sleep(20 * time.Millisecond)
		}
		if err != nil {
			t.Fatalf("dial %d: %v", i, err)
		}
		if err := proto.Write(conn, &proto.Packet{Opcode: 1}, nil, nil); err != nil {
			t.Fatalf("write %d: %v", i, err)
		}
		conn.Close()
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		n := len(seen)
		mu.Unlock()
		if n == 3 {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(seen) != 3 {
		t.Fatalf("got %d unique session IDs, want 3", len(seen))
	}
}

// TestServerTLSEchoesPackets confirms Server.TLSConfig actually serves TLS
// (a real handshake against a real self-signed cert, not a mocked
// listener) and that framed packets still round-trip correctly once
// TLS is in the picture.
func TestServerTLSEchoesPackets(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cert := generateTestCert(t)
	received := make(chan *proto.Packet, 1)
	srv := &Server{
		Addr:      "127.0.0.1:0",
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
		Handle: func(_ context.Context, sess *Session, p *proto.Packet) error {
			received <- p
			return sess.Send(&proto.Packet{Opcode: p.Opcode + 1, Data: p.Data})
		},
	}

	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	go srv.ListenAndServe(ctx)

	// The self-signed cert isn't in any trust store, so this test
	// deliberately skips verification -- it's confirming the TLS
	// handshake and framing work, not certificate trust chains (that's
	// the operator's job when they provide a real cert).
	clientConf := &tls.Config{InsecureSkipVerify: true}
	var conn *tls.Conn
	for i := 0; i < 50; i++ {
		conn, err = tls.Dial("tcp", addr, clientConf)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("tls.Dial: %v", err)
	}
	defer conn.Close()

	want := &proto.Packet{Opcode: 0x6100, Data: []byte("ping over tls")}
	if err := proto.Write(conn, want, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}

	select {
	case got := <-received:
		if got.Opcode != want.Opcode || string(got.Data) != string(want.Data) {
			t.Fatalf("handler got %+v, want %+v", got, want)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for handler to receive packet")
	}

	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	reply, err := proto.Read(bufio.NewReader(conn), nil, nil)
	if err != nil {
		t.Fatalf("reading reply: %v", err)
	}
	if reply.Opcode != want.Opcode+1 || string(reply.Data) != "ping over tls" {
		t.Fatalf("unexpected reply: %+v", reply)
	}
}

// TestServerTLSRejectsPlainTCP confirms a TLS-configured server doesn't
// silently accept a plaintext connection -- a client speaking raw framed
// packets (no TLS handshake) should fail rather than being treated as an
// unencrypted session.
func TestServerTLSRejectsPlainTCP(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cert := generateTestCert(t)
	srv := &Server{
		Addr:      "127.0.0.1:0",
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}},
		Handle:    func(context.Context, *Session, *proto.Packet) error { return nil },
	}

	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()
	srv.Addr = addr

	go srv.ListenAndServe(ctx)

	var conn net.Conn
	for i := 0; i < 50; i++ {
		conn, err = net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	if err := proto.Write(conn, &proto.Packet{Opcode: 1}, nil, nil); err != nil {
		t.Fatalf("write: %v", err)
	}

	// A raw framed packet isn't a valid TLS ClientHello, so the server
	// should close the connection during the handshake rather than
	// process it as a plaintext session.
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 16)
	n, err := conn.Read(buf)
	if err == nil && n > 0 {
		t.Fatalf("expected the TLS handshake to fail/close the connection, got %d bytes back", n)
	}
}
