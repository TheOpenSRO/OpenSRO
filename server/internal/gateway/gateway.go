// Package gateway is the first hop a client TCP connection hits: it accepts
// connections, frames incoming bytes into packets via internal/proto, and
// hands each decoded packet to a Handler. It has no opcode-specific game
// logic — that belongs in whatever's built on top of Handler.
package gateway

import (
	"bufio"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log/slog"
	"net"
	"sync"
	"sync/atomic"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Handler processes one decoded packet from a session. Returning an error
// closes that session's connection.
type Handler func(ctx context.Context, sess *Session, p *proto.Packet) error

// Chain combines multiple Handlers into one, calling each in order for
// every packet. Each Handler is expected to check the opcode(s) it cares
// about and no-op (return nil) otherwise — Chain itself does no opcode
// routing. Stops and returns early on the first error.
func Chain(handlers ...Handler) Handler {
	return func(ctx context.Context, sess *Session, p *proto.Packet) error {
		for _, h := range handlers {
			if err := h(ctx, sess, p); err != nil {
				return err
			}
		}
		return nil
	}
}

// Session is one accepted, live client connection. It also carries a small
// generic key/value bag so higher-level handlers (login, character
// selection, ...) can remember state across packets on the same connection
// — e.g. "which account authenticated on this connection" — without gateway
// itself knowing anything about accounts or characters.
type Session struct {
	id   uint64
	conn net.Conn

	mu     sync.RWMutex
	values map[string]any

	secMu    sync.Mutex
	sendRoll *proto.RollingByte
	sendSum  *proto.PacketChecksum
	recvRoll *proto.RollingByte
	recvSum  *proto.PacketChecksum

	// sendMu makes each Send one frame on the wire. Packets reach a session
	// from other goroutines than its own read loop -- zone broadcasts from
	// other sessions' handlers, and the server's own repeated swings
	// (session/keepup.go) -- and proto.Write is two writes (header, body)
	// that must not interleave with another packet's.
	sendMu sync.Mutex
}

// SetSecurity installs this session's real per-direction RollingByte/
// PacketChecksum generators (see proto.Read/Write) once a handshake derives
// them. Before this is called, Send and the read loop pass nil for both,
// which skips those fields' validation/generation entirely -- the correct
// behavior pre-handshake, not a workaround.
func (s *Session) SetSecurity(sendRoll *proto.RollingByte, sendSum *proto.PacketChecksum, recvRoll *proto.RollingByte, recvSum *proto.PacketChecksum) {
	s.secMu.Lock()
	defer s.secMu.Unlock()
	s.sendRoll, s.sendSum = sendRoll, sendSum
	s.recvRoll, s.recvSum = recvRoll, recvSum
}

func (s *Session) security() (sendRoll *proto.RollingByte, sendSum *proto.PacketChecksum, recvRoll *proto.RollingByte, recvSum *proto.PacketChecksum) {
	s.secMu.Lock()
	defer s.secMu.Unlock()
	return s.sendRoll, s.sendSum, s.recvRoll, s.recvSum
}

// ID uniquely identifies this session for the life of the process (not
// stable across restarts). Useful as a map key for higher-level state (e.g.
// world.Hub tracking who's in which zone) without comparing *Session
// pointers directly.
func (s *Session) ID() uint64 {
	return s.id
}

// RemoteAddr returns the client's address, mainly for logging.
func (s *Session) RemoteAddr() net.Addr {
	return s.conn.RemoteAddr()
}

// NewTestSession returns a *Session with the given ID and no real
// connection, for other packages' tests that need something to key state
// by (e.g. world.Hub, keyed on session ID) without spinning up a real TCP
// connection. Calling Send or RemoteAddr on the result will panic (nil
// conn) — it's only useful for its ID() and the Set/Get value bag.
func NewTestSession(id uint64) *Session {
	return &Session{id: id}
}

// Set stores a value under key for the lifetime of this connection.
func (s *Session) Set(key string, value any) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.values == nil {
		s.values = make(map[string]any)
	}
	s.values[key] = value
}

// Get retrieves a value previously stored with Set.
func (s *Session) Get(key string) (any, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	v, ok := s.values[key]
	return v, ok
}

// Send writes a packet back to this session's client.
func (s *Session) Send(p *proto.Packet) error {
	sendRoll, sendSum, _, _ := s.security()
	s.sendMu.Lock()
	defer s.sendMu.Unlock()
	return proto.Write(s.conn, p, sendRoll, sendSum)
}

// Close closes the underlying connection.
func (s *Session) Close() error {
	return s.conn.Close()
}

// Server accepts TCP connections and dispatches decoded packets to Handle.
type Server struct {
	Addr   string
	Handle Handler
	Logger *slog.Logger

	// TLSConfig, if set, makes ListenAndServe serve TLS instead of plain
	// TCP -- see docs/protocol/PROTOCOL_DECISION.md: this project's own
	// protocol deliberately has no custom encryption/obfuscation layer
	// (unlike the original game's rolling-byte scheme), on the reasoning
	// that a from-scratch client/server pair should reach for standard
	// TLS instead of reinventing crypto. Plain TCP (nil TLSConfig) remains
	// the default for local development.
	TLSConfig *tls.Config

	// OnDisconnect, if set, is called once when a session's connection ends
	// (client disconnect, read error, or a Handler error). Lets
	// higher-level state (e.g. world.Hub) clean up without gateway knowing
	// anything about what that state is. Don't assume anything about
	// whether the connection is still open at this point — use it for
	// bookkeeping (removing the session from other state), not for sending
	// a farewell packet to the disconnecting client.
	OnDisconnect func(sess *Session)

	nextSessionID atomic.Uint64
}

// ListenAndServe binds Addr and serves connections until ctx is canceled or
// a fatal listener error occurs.
func (s *Server) ListenAndServe(ctx context.Context) error {
	logger := s.Logger
	if logger == nil {
		logger = slog.Default()
	}

	lc := net.ListenConfig{}
	ln, err := lc.Listen(ctx, "tcp", s.Addr)
	if err != nil {
		return err
	}
	defer ln.Close()

	if s.TLSConfig != nil {
		ln = tls.NewListener(ln, s.TLSConfig)
		logger.Info("gateway listening (TLS)", "addr", s.Addr)
	} else {
		logger.Info("gateway listening", "addr", s.Addr)
	}

	go func() {
		<-ctx.Done()
		ln.Close()
	}()

	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil // shutting down; not a real error
			}
			var ne net.Error
			if errors.As(err, &ne) {
				logger.Warn("accept error, continuing", "error", err)
				continue
			}
			return err
		}
		go s.serveConn(ctx, conn, logger)
	}
}

func (s *Server) serveConn(ctx context.Context, conn net.Conn, logger *slog.Logger) {
	sess := &Session{id: s.nextSessionID.Add(1), conn: conn}
	defer sess.Close()
	if s.OnDisconnect != nil {
		defer s.OnDisconnect(sess)
	}

	logger.Info("session connected", "addr", sess.RemoteAddr())
	defer logger.Info("session disconnected", "addr", sess.RemoteAddr())

	r := bufio.NewReader(conn)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		_, _, recvRoll, recvSum := sess.security()
		p, err := proto.Read(r, recvRoll, recvSum)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				logger.Warn("session read error", "addr", sess.RemoteAddr(), "error", err)
			}
			return
		}

		if s.Handle == nil {
			continue
		}
		if err := s.Handle(ctx, sess, p); err != nil {
			logger.Warn("handler error, closing session", "addr", sess.RemoteAddr(), "error", err)
			return
		}
	}
}
