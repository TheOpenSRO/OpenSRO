// Package gateway is the first hop a client TCP connection hits: it accepts
// connections, frames incoming bytes into packets via internal/proto, and
// hands each decoded packet to a Handler. It has no opcode-specific game
// logic — that belongs in whatever's built on top of Handler.
package gateway

import (
	"bufio"
	"context"
	"errors"
	"io"
	"log/slog"
	"net"

	"github.com/OpenSRO/srrevamp/server/internal/proto"
)

// Handler processes one decoded packet from a session. Returning an error
// closes that session's connection.
type Handler func(ctx context.Context, sess *Session, p *proto.Packet) error

// Session is one accepted, live client connection.
type Session struct {
	conn net.Conn
}

// RemoteAddr returns the client's address, mainly for logging.
func (s *Session) RemoteAddr() net.Addr {
	return s.conn.RemoteAddr()
}

// Send writes a packet back to this session's client.
func (s *Session) Send(p *proto.Packet) error {
	return proto.Write(s.conn, p)
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

	logger.Info("gateway listening", "addr", s.Addr)

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
	sess := &Session{conn: conn}
	defer sess.Close()

	logger.Info("session connected", "addr", sess.RemoteAddr())
	defer logger.Info("session disconnected", "addr", sess.RemoteAddr())

	r := bufio.NewReader(conn)
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}

		p, err := proto.Read(r)
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
